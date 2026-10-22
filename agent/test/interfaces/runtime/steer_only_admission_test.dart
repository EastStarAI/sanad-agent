/// `steer_only` admission: a steer that may never become a turn.
///
/// The daemon is the only authority on whether a message was steered, queued,
/// or admitted as a turn, so these tests drive the real `SessionRunOrchestrator`
/// admission path with a real durable execution state and a recording adapter.
///
/// Covered:
///
/// * `steer_only` with no live owner is rejected with a typed `no_active_turn`
///   error correlated to the request id, and neither queues nor admits the text;
/// * a steer that omits the flag keeps the legacy admit-or-queue behaviour, so
///   the Flutter client and the REPL `/steer` are unchanged.
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
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

class _RecordingAdapter implements LLMAdapter {
  int calls = 0;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    calls++;
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

void main() {
  const providerId = 'inst-steer-only';
  const modelId = 'steer-only-model';
  const sessionId = 's-steer-only';

  late Directory tempDir;
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository runtime;
  late SessionManager sessions;
  late _RecordingAdapter adapter;
  late SessionRunOrchestrator orchestrator;
  late List<GatewayResponse> responses;
  late StreamSubscription<GatewayResponse> responseSub;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('steer_only_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    await getIt.reset();
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;

    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    runtime = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(runtime);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    repo.createInstance(
      ProviderInstance(
        id: providerId,
        templateId: kCustomProviderTemplateId,
        displayName: 'Steer provider',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: modelId,
        status: InstanceStatus.ready,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    sessions = SessionManager();
    getIt.registerSingleton<SessionManager>(sessions);
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(repo, ProviderRateLimiter())
        ..attachPersistedState(runtime),
    );

    final workspace = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
    );
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
    getIt.registerSingleton<LocalRuntimeCatalog>(
      LocalRuntimeCatalog(
        workspaceRuntimeService: workspace,
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      ),
    );
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(workspace, getIt<LocalRuntimeCatalog>()),
    );

    adapter = _RecordingAdapter();
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (runnerSessionId, _) => AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: runnerSessionId,
      ),
    );
    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
    responses = [];
    responseSub = orchestrator.responses.listen(responses.add);

    final now = DateTime.utc(2026, 10, 22);
    sessions.db.saveSession(
      SessionState(
        sessionId: sessionId,
        model: modelId,
        providerId: providerId,
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
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

  AgentTurnRequest turnRequest(
    String requestId, {
    String message = 'Add an audit trail',
  }) => AgentTurnRequest(
    sessionId: sessionId,
    message: message,
    providerInstanceId: providerId,
    model: modelId,
    requestId: requestId,
  );

  GatewayEvent steer(
    String requestId, {
    required bool steerOnly,
    String message = 'Add an audit trail',
  }) => GatewayEvent(
    sessionId: sessionId,
    platformId: 'cli_client',
    type: 'steer',
    message: Message(role: MessageRole.user, content: message),
    runId: requestId,
    turnRequest: turnRequest(requestId, message: message),
    metadata: {
      'command': 'steer',
      'payload': {
        'session_id': sessionId,
        'request_id': requestId,
        'message': message,
        if (steerOnly) 'steer_only': true,
      },
    },
  );

  List<Map<String, dynamic>> canonical(String type, String requestId) =>
      responses
          .where(
            (response) =>
                response.message.metadata?['canonical_event_type'] == type &&
                (response.message.metadata?['canonical_payload']
                        as Map?)?['request_id'] ==
                    requestId,
          )
          .map(
            (response) => Map<String, dynamic>.from(
              response.message.metadata!['canonical_payload'] as Map,
            ),
          )
          .toList();

  List<String> classifications(String requestId) => canonical(
    'session.message_classified',
    requestId,
  ).map((payload) => payload['classification'] as String).toList();

  bool queuedEchoFor(String requestId) => responses.any(
    (response) =>
        response.message.metadata?['queued'] == true &&
        response.message.metadata?['request_id'] == requestId,
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('steer_only with no live owner is rejected, never queued', () async {
    orchestrator.debugMarkSessionBusy(sessionId);

    await orchestrator.handleEvent(steer('req-steer-only-busy', steerOnly: true));
    await settle();

    final rejections = canonical('error', 'req-steer-only-busy');
    expect(rejections, hasLength(1));
    expect(rejections.single['code'], 'no_active_turn');
    expect(rejections.single['is_fatal'], isFalse);
    expect(
      classifications('req-steer-only-busy'),
      isEmpty,
      reason: 'a rejected steer is never classified as queue or think',
    );
    expect(
      queuedEchoFor('req-steer-only-busy'),
      isFalse,
      reason: 'the text must not become a queued turn',
    );

    // Releasing the session proves nothing was queued behind the busy flag.
    orchestrator.debugClearSessionBusy(sessionId);
    await settle();
    expect(adapter.calls, 0);
    expect(runtime.workItems.findByRequestId(sessionId, 'req-steer-only-busy'),
        isNull);
    expect(orchestrator.isSessionBusy(sessionId), isFalse);
  });

  test('steer_only on an idle session starts no turn and creates no work',
      () async {
    await orchestrator.handleEvent(steer('req-steer-only-idle', steerOnly: true));
    await settle();

    final rejections = canonical('error', 'req-steer-only-idle');
    expect(rejections, hasLength(1));
    expect(rejections.single['code'], 'no_active_turn');
    expect(
      adapter.calls,
      0,
      reason: 'an idle session must not start a turn from a steer',
    );
    expect(
      runtime.findActiveWorkItem(sessionId),
      isNull,
      reason: 'no durable work item may be created for a rejected steer',
    );
    expect(classifications('req-steer-only-idle'), isEmpty);
  });

  test('a steer without the flag keeps the legacy queue behaviour', () async {
    orchestrator.debugMarkSessionBusy(sessionId);

    await orchestrator.handleEvent(steer('req-legacy-busy', steerOnly: false));
    await settle();

    expect(
      canonical('error', 'req-legacy-busy'),
      isEmpty,
      reason: 'a client that omits the flag is never rejected',
    );
    expect(
      classifications('req-legacy-busy'),
      ['queue'],
      reason: 'legacy busy-session behaviour queues the text',
    );
    expect(queuedEchoFor('req-legacy-busy'), isTrue);
    expect(adapter.calls, 0);
  });

  test('a steer without the flag keeps the legacy admit-as-turn behaviour',
      () async {
    await orchestrator.handleEvent(steer('req-legacy-idle', steerOnly: false));

    expect(
      canonical('error', 'req-legacy-idle'),
      isEmpty,
      reason: 'the legacy path is unchanged: nothing is rejected',
    );
    for (var i = 0; i < 200 && adapter.calls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      adapter.calls,
      1,
      reason: 'without the flag an idle session still admits a new turn',
    );
    expect(classifications('req-legacy-idle'), ['think']);
  });

  test('steer_only during a restart drain is rejected, never queued', () async {
    orchestrator.beginControlledRestartDrain();
    addTearDown(orchestrator.cancelControlledRestartDrain);

    await orchestrator.handleEvent(
      steer('req-steer-only-drain', steerOnly: true),
    );
    await settle();

    final rejections = canonical('error', 'req-steer-only-drain');
    expect(rejections, hasLength(1));
    expect(rejections.single['code'], 'no_active_turn');
    expect(
      adapter.calls,
      0,
      reason: 'a draining daemon must not start a turn from a steer',
    );
    expect(
      runtime.findActiveWorkItem(sessionId),
      isNull,
      reason: 'a rejected steer creates no durable work',
    );
    expect(classifications('req-steer-only-drain'), isEmpty);
    expect(queuedEchoFor('req-steer-only-drain'), isFalse);
  });

  test('steer_only is rejected while a waiting recovery notice owns the session',
      () async {
    final recovery = getIt<RuntimeRecoveryService>();
    recovery.reportFailure(
      sessionId: sessionId,
      reason: RuntimeFailureReason.rateLimit,
      providerInstanceId: providerId,
      retryAfter: const Duration(minutes: 30),
    );
    expect(
      recovery.activeNotice(sessionId)?.status,
      RuntimeNoticeStatus.waiting,
    );

    await orchestrator.handleEvent(
      steer('req-steer-only-waiting', steerOnly: true),
    );
    await settle();

    final rejections = canonical('error', 'req-steer-only-waiting');
    expect(rejections, hasLength(1));
    expect(rejections.single['code'], 'no_active_turn');
    expect(
      adapter.calls,
      0,
      reason: 'a waiting session has no execution boundary to steer',
    );
    expect(classifications('req-steer-only-waiting'), isEmpty);
  });

  test('a steer_only rejection without a request id is still published',
      () async {
    // No turn request, no payload request id, and no run id: nothing can be
    // correlated, and the rejection must still be observable.
    await orchestrator.handleEvent(
      GatewayEvent(
        sessionId: sessionId,
        platformId: 'cli_client',
        type: 'steer',
        message: Message(role: MessageRole.user, content: 'Add an audit trail'),
        metadata: const {
          'command': 'steer',
          'payload': {'session_id': sessionId, 'steer_only': true},
        },
      ),
    );
    await settle();

    final rejections = responses
        .where(
          (response) =>
              response.message.metadata?['canonical_event_type'] == 'error',
        )
        .map(
          (response) => Map<String, dynamic>.from(
            response.message.metadata!['canonical_payload'] as Map,
          ),
        )
        .toList();
    expect(rejections, hasLength(1));
    expect(rejections.single['code'], 'no_active_turn');
    expect(
      rejections.single.containsKey('request_id'),
      isFalse,
      reason: 'an uncorrelated rejection must not invent a correlation id',
    );
    expect(adapter.calls, 0);
    expect(runtime.findActiveWorkItem(sessionId), isNull);
  });
}
