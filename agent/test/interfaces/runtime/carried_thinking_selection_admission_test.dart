/// Live-acceptance defect L2 (Task 115): a thinking selection the Client
/// carries into `create_session` and the first `think` for a route that never
/// offered it must fall back to provider default instead of rejecting the turn.
///
/// Drives the real `SessionRunOrchestrator` new-session plus first-turn entry
/// path with a real `AgentRunner`, the real thinking resolver/store/sync stack
/// and an in-memory state database, asserting what reaches the adapter.
library;

import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

class _RecordingAdapter implements LLMAdapter {
  final List<LLMRequestOptions> options = [];

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    this.options.add(options);
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'ok'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(history, options: options);
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];
}

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  _NoopMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}

void _instance(
  ProviderInstanceRepository repo, {
  required String id,
  required String templateId,
  required String model,
  required Map<String, dynamic> cachedModel,
}) {
  repo.createInstance(
    ProviderInstance(
      id: id,
      templateId: templateId,
      displayName: id,
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      defaultModel: model,
      status: InstanceStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );
  repo.upsertModelCache(
    instanceId: id,
    cacheKey: 'models',
    models: [cachedModel],
    fetchedAt: DateTime.now(),
    source: 'live',
    configRevision: 1,
    credentialRevision: 1,
  );
}

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionManager sessions;
  late ThinkingRoutePreferenceStore store;
  late _RecordingAdapter adapter;
  late SessionRunOrchestrator orchestrator;
  late List<GatewayResponse> responses;
  late StreamSubscription<GatewayResponse> responseSub;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('carried_thinking_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    await getIt.reset();
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;

    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    sessions = SessionManager();
    getIt.registerSingleton<SessionManager>(sessions);
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<ProviderInstanceRepository>(repo);

    final registry = buildProviderThinkingRegistry();
    final resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: ThinkingCapabilityAssembler(registry),
      registry: registry,
    );
    store = ThinkingRoutePreferenceStore(sessions);
    final revalidator = ThinkingRouteRevalidator(
      resolver: resolver,
      store: store,
    );
    getIt.registerSingleton<ThinkingSelectionResolver>(resolver);
    getIt.registerSingleton<ThinkingRoutePreferenceStore>(store);
    getIt.registerSingleton<ThinkingRouteRevalidator>(revalidator);
    getIt.registerSingleton<ThinkingRouteSessionSync>(
      ThinkingRouteSessionSync(
        revalidator: revalidator,
        store: store,
        sessions: sessions,
      ),
    );

    // Supported route where the user last picked `high`.
    _instance(
      repo,
      id: 'inst-openai',
      templateId: 'openai',
      model: 'o3',
      cachedModel: {
        'value': 'o3',
        // Provider-reported Codex-style native levels (capability authority).
        'supported_reasoning_levels': [
          {'effort': 'low'},
          {'effort': 'medium'},
          {'effort': 'high'},
        ],
        'default_reasoning_level': 'medium',
        'supports_reasoning_output': true,
        'thinking_control': {
          'status': 'supported',
          'kind': 'effort',
          'options': [
            {'id': 'low', 'label': 'Low'},
            {'id': 'medium', 'label': 'Medium'},
            {'id': 'high', 'label': 'High'},
          ],
          'capability_revision': 'rev-o3',
          'source': 'profile',
        },
      },
    );
    // Client renders "No control".
    _instance(
      repo,
      id: 'inst-opencode',
      templateId: 'opencode-go',
      model: 'gpt-6-luna',
      // The provider reports no request-time control for this exact route.
      cachedModel: {
        'value': 'gpt-6-luna',
        'model_metadata': {
          'thinking_control': {'status': 'unsupported'},
        },
      },
    );
    // Client renders "Not reported".
    _instance(
      repo,
      id: 'inst-moonshot',
      templateId: 'moonshot',
      model: 'kimi-for-coding',
      cachedModel: {'value': 'kimi-for-coding', 'model_metadata': {}},
    );

    final workspace = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
    );
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
    final catalog = LocalRuntimeCatalog(
      workspaceRuntimeService: workspace,
      mcpRuntimeManager: _NoopMcpRuntimeManager(),
    );
    getIt.registerSingleton<LocalRuntimeCatalog>(catalog);
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(workspace, catalog),
    );

    adapter = _RecordingAdapter();
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (sessionId, _) => AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: sessionId,
      ),
    );
    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
    responses = [];
    responseSub = orchestrator.responses.listen(responses.add);
  });

  tearDown(() async {
    await responseSub.cancel();
    await getIt.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  AgentTurnRequest request(
    String sessionId,
    String requestId, {
    required String provider,
    required String model,
    String? thinkingMode,
    String message = 'hi',
  }) => AgentTurnRequest(
    sessionId: sessionId,
    message: message,
    providerInstanceId: provider,
    model: model,
    thinkingMode: thinkingMode,
    requestId: requestId,
  );

  Future<void> createSession(
    String sessionId, {
    required String provider,
    required String model,
    String? thinkingMode,
  }) => orchestrator.handleEvent(
    GatewayEvent(
      sessionId: sessionId,
      platformId: 'client',
      type: 'create_session',
      message: Message(role: MessageRole.user, content: ''),
      metadata: {
        'payload': {'request_id': 'create-$sessionId'},
      },
      runId: 'create-$sessionId',
      turnRequest: request(
        sessionId,
        'create-$sessionId',
        provider: provider,
        model: model,
        thinkingMode: thinkingMode,
        message: '',
      ),
    ),
  );

  /// Sends one `think` and waits for its terminal response.
  Future<GatewayResponse> think(
    String sessionId,
    String requestId, {
    required String provider,
    required String model,
    String? thinkingMode,
  }) async {
    final before = responses.length;
    await orchestrator.handleEvent(
      GatewayEvent(
        sessionId: sessionId,
        platformId: 'client',
        message: Message(role: MessageRole.user, content: 'hi'),
        runId: requestId,
        turnRequest: request(
          sessionId,
          requestId,
          provider: provider,
          model: model,
          thinkingMode: thinkingMode,
        ),
      ),
    );
    for (var i = 0; i < 400; i++) {
      final terminal = responses
          .skip(before)
          .where((r) => r.isComplete && !r.isSessionCreated)
          .toList();
      if (terminal.isNotEmpty) return terminal.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no terminal response for $requestId');
  }

  bool isError(GatewayResponse r) =>
      (r.message.metadata?['error'] != null) ||
      (r.message.content ?? '').contains('thinking_capability') ||
      (r.message.content ?? '').contains('Thinking controls');

  for (final route in [
    (
      label: 'unknown capability (Moonshot kimi-for-coding, "Not reported")',
      provider: 'inst-moonshot',
      model: 'kimi-for-coding',
      corrects: false,
    ),
    (
      label: 'unsupported capability (OpenCode Go gpt-6-luna, "No control")',
      provider: 'inst-opencode',
      model: 'gpt-6-luna',
      corrects: true,
    ),
  ]) {
    test('carried last-used `high` into a new session on ${route.label} '
        'completes the first turn with provider default', () async {
      // Last-used `high` on the supported route.
      await createSession('s-supported', provider: 'inst-openai', model: 'o3');
      final first = await think(
        's-supported',
        'req-supported',
        provider: 'inst-openai',
        model: 'o3',
        thinkingMode: 'high',
      );
      expect(isError(first), isFalse);
      expect(adapter.options.last.thinkingDirective, isA<OpenAiEffortDirective>());

      // The Client carries the hidden value into create_session and think.
      final sessionId = 's-${route.provider}';
      await createSession(
        sessionId,
        provider: route.provider,
        model: route.model,
        thinkingMode: 'high',
      );
      expect(sessions.getSession(sessionId)?.thinkingMode, 'high');
      final calls = adapter.options.length;
      final terminal = await think(
        sessionId,
        'req-$sessionId',
        provider: route.provider,
        model: route.model,
        thinkingMode: 'high',
      );

      expect(isError(terminal), isFalse, reason: terminal.message.content);
      expect(terminal.message.content, contains('ok'));
      expect(adapter.options.length, calls + 1);
      final sent = adapter.options.last;
      expect(
        sent.thinkingDirective == null ||
            sent.thinkingDirective is UseProviderDefault,
        isTrue,
      );
      final correction = store.readCorrection(sessionId);
      if (route.corrects) {
        // Truthful route-scoped correction for the dropped carried value.
        expect(sent.thinkingMode, isNull);
        expect(correction?.previousSelectionId, 'high');
      } else {
        // No layer reports a set: the value passes through unchanged and is
        // never put on the wire, so there is nothing to correct.
        expect(correction, isNull);
      }
    });
  }

  test('an explicit valid selection on a supported route is still honored',
      () async {
    await createSession(
      's-valid',
      provider: 'inst-openai',
      model: 'o3',
      thinkingMode: 'high',
    );
    await think(
      's-valid',
      'req-valid',
      provider: 'inst-openai',
      model: 'o3',
      thinkingMode: 'high',
    );
    final directive = adapter.options.last.thinkingDirective;
    expect(directive, isA<OpenAiEffortDirective>());
    expect((directive as OpenAiEffortDirective).effort, 'high');
  });

  test('a fresh explicit selection the route does not offer is still '
      'rejected before any provider call', () async {
    // Session persisted without a thinking preference; the turn asks for one.
    await createSession(
      's-explicit',
      provider: 'inst-opencode',
      model: 'gpt-6-luna',
    );
    final calls = adapter.options.length;
    final terminal = await think(
      's-explicit',
      'req-explicit',
      provider: 'inst-opencode',
      model: 'gpt-6-luna',
      thinkingMode: 'high',
    );
    expect(adapter.options.length, calls);
    expect(
      '${terminal.message.content} ${terminal.message.metadata}',
      contains(ThinkingSelectionErrorCode.capabilityUnsupported),
    );
  });
}
