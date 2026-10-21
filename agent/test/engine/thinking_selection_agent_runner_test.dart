import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/runtime/thinking_field_rejection.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_context_assembler.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/turn_route_state.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

class _CountingAdapter implements LLMAdapter {
  int callCount = 0;
  final List<LLMRequestOptions> recordedOptions = [];
  final List<List<dynamic>> recordedHistories = [];
  AgentResponse Function(int callCount, LLMRequestOptions options)? onGenerate;

  LLMRequestOptions? get lastOptions =>
      recordedOptions.isNotEmpty ? recordedOptions.last : null;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    recordedOptions.add(options);
    recordedHistories.add(List<dynamic>.of(history));
    if (onGenerate != null) {
      return onGenerate!(callCount, options);
    }
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
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];
}

class _SimpleTestTool extends BaseTool {
  @override
  ToolSchema get schema => ToolSchema(
    name: 'sample_tool',
    description: 'Sample test tool',
    parameters: {},
  );

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => ToolExecutionResult.text('tool result');

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => 'tool result';
}

class _ImageSupportProbeTool extends BaseTool {
  final List<RouteImageSupport> observed = [];

  @override
  ToolSchema get schema => ToolSchema(
    name: 'image_support_probe',
    description: 'Records ToolContext.imageSupport',
    parameters: {},
  );

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    observed.add(context?.imageSupport ?? RouteImageSupport.unknown);
    return ToolExecutionResult.text('probed');
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;
}

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late SessionManager sessionManager;
  late ToolsRegistry registry;
  late ThinkingRoutePreferenceStore preferenceStore;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('thinking_runner_test_');
    Directory(
      '${tempDir.path}${Platform.pathSeparator}memories',
    ).createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);

    await GetIt.I.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    sessionManager = SessionManager();
    registry = ToolsRegistry();

    final thinkingRegistry = buildProviderThinkingRegistry();
    final assembler = ThinkingCapabilityAssembler(thinkingRegistry);
    final cacheResolver = ThinkingControlCacheResolver(repo);
    final selectionResolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: cacheResolver,
      assembler: assembler,
      registry: thinkingRegistry,
    );
    preferenceStore = ThinkingRoutePreferenceStore(sessionManager);
    final revalidator = ThinkingRouteRevalidator(
      resolver: selectionResolver,
      store: preferenceStore,
    );

    GetIt.I.registerSingleton<ThinkingSelectionResolver>(selectionResolver);
    GetIt.I.registerSingleton<ThinkingRoutePreferenceStore>(preferenceStore);
    GetIt.I.registerSingleton<ThinkingRouteRevalidator>(revalidator);
    final sync = ThinkingRouteSessionSync(
      revalidator: revalidator,
      store: preferenceStore,
      sessions: sessionManager,
    );
    GetIt.I.registerSingleton<ThinkingRouteSessionSync>(sync);
    GetIt.I.registerSingleton<Config>(Config());
    GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);

    repo.createInstance(
      ProviderInstance(
        id: 'inst-1',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-test',
        status: InstanceStatus.ready,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          // Provider-reported: the endpoint declares no request-time control.
          'model_metadata': {
            'thinking_control': {'status': 'unsupported'},
          },
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': 'rev-1',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );
  });

  tearDown(() async {
    await GetIt.I.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('unsupported explicit thinking selection skips adapter call', () async {
    final adapter = _CountingAdapter();
    final session = sessionManager.createSession(
      'gpt-test',
      providerId: 'inst-1',
      thinkingMode: 'deep',
    );
    final runner = AgentRunner(
      adapter,
      registry,
      sessionManager,
      existingSessionId: session.sessionId,
    );

    await expectLater(
      runner.sendMessage(
        'Hello',
        providerId: 'inst-1',
        model: 'gpt-test',
        thinkingMode: 'deep',
      ),
      throwsA(isA<ThinkingSelectionException>()),
    );

    expect(adapter.callCount, 0);
  });

  test(
    'absent thinking selection preserves provider default without instance lookup',
    () async {
      final adapter = _CountingAdapter();
      final session = sessionManager.createSession(
        'fixture-model',
        providerId: 'deterministic-fixture',
      );
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      final response = await runner.sendMessage(
        'Hello',
        providerId: 'deterministic-fixture',
        model: 'fixture-model',
      );

      expect(response.content, 'ok');
      expect(adapter.callCount, 1);
      expect(adapter.lastOptions?.thinkingMode, isNull);
      expect(adapter.lastOptions?.thinkingDirective, isNull);
    },
  );

  test(
    'supported explicit thinking selection reaches adapter directive',
    () async {
      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
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
              'capability_revision': 'rev-supported',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final adapter = _CountingAdapter();
      final session = sessionManager.createSession(
        'o3',
        providerId: 'inst-1',
        thinkingMode: 'high',
      );
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      final response = await runner.sendMessage(
        'Hello',
        providerId: 'inst-1',
        model: 'o3',
        thinkingMode: 'high',
      );

      expect(response.content, 'ok');
      expect(adapter.callCount, 1);
      expect(
        adapter.lastOptions?.thinkingDirective,
        isA<OpenAiEffortDirective>(),
      );
      expect(
        (adapter.lastOptions!.thinkingDirective! as OpenAiEffortDirective)
            .effort,
        'high',
      );
    },
  );

  test(
    'thinking selection frozen across turn iterations despite mid-turn config and preference mutation',
    () async {
      registry.registerTool(_SimpleTestTool());

      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
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
              'capability_revision': 'rev-supported',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final adapter = _CountingAdapter();
      adapter.onGenerate = (count, options) {
        if (count == 1) {
          // Mid-turn: modify cache/revisions to revoke thinking
          repo.upsertModelCache(
            instanceId: 'inst-1',
            cacheKey: 'models',
            models: [
              {
                'value': 'o3',
                // Provider-reported Codex-style native levels (capability authority).
                'supported_reasoning_levels': [
                  {'effort': 'low'},
                  {'effort': 'medium'},
                  {'effort': 'high'},
                ],
                'default_reasoning_level': 'medium',
                'thinking_control': {
                  'status': 'unsupported',
                  'capability_revision': 'rev-unsupported',
                  'source': 'profile',
                },
              },
            ],
            fetchedAt: DateTime.now(),
            source: 'live',
            configRevision: 2,
            credentialRevision: 1,
          );

          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: null,
              toolCalls: [
                ToolCall(id: 'call_1', name: 'sample_tool', arguments: {}),
              ],
            ),
            isToolCall: true,
          );
        }
        return AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'completed'),
        );
      };

      final session = sessionManager.createSession(
        'o3',
        providerId: 'inst-1',
        thinkingMode: 'high',
      );
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      final response = await runner.sendMessage(
        'Run tool and reply',
        providerId: 'inst-1',
        model: 'o3',
        thinkingMode: 'high',
      );

      expect(response.content, 'completed');
      expect(adapter.callCount, 2);
      expect(adapter.recordedOptions.length, 2);

      // Both iterations MUST retain the admitted thinking directive and mode
      expect(
        adapter.recordedOptions[0].thinkingDirective,
        isA<OpenAiEffortDirective>(),
      );
      expect(
        (adapter.recordedOptions[0].thinkingDirective as OpenAiEffortDirective)
            .effort,
        'high',
      );
      expect(adapter.recordedOptions[0].thinkingMode, 'high');

      expect(
        adapter.recordedOptions[1].thinkingDirective,
        isA<OpenAiEffortDirective>(),
      );
      expect(
        (adapter.recordedOptions[1].thinkingDirective as OpenAiEffortDirective)
            .effort,
        'high',
      );
      expect(adapter.recordedOptions[1].thinkingMode, 'high');
    },
  );

  test(
    'declared endpoint thinking controls on custom provider resolve to proper native directives',
    () async {
      repo.createInstance(
        ProviderInstance(
          id: 'custom-inst',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom Provider',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'custom-reasoning-model',
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      repo.upsertModelCache(
        instanceId: 'custom-inst',
        cacheKey: 'models',
        models: [
          {
            'value': 'custom-reasoning-model',
            'supports_reasoning_output': true,
            'model_metadata': {
              'thinking_control': {
                'status': 'supported',
                'wire': 'openai_chat_effort',
                'options': {'low': 'low', 'high': 'high'},
                'default_option_id': 'low',
              },
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final adapter = _CountingAdapter();
      final session = sessionManager.createSession(
        'custom-reasoning-model',
        providerId: 'custom-inst',
        thinkingMode: 'high',
      );
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      final response = await runner.sendMessage(
        'Hello custom',
        providerId: 'custom-inst',
        model: 'custom-reasoning-model',
        thinkingMode: 'high',
      );

      expect(response.content, 'ok');
      expect(
        adapter.lastOptions?.thinkingDirective,
        isA<OpenAiEffortDirective>(),
      );
      expect(
        (adapter.lastOptions!.thinkingDirective! as OpenAiEffortDirective)
            .effort,
        'high',
      );
    },
  );

  group('Task 115 - provider-specific thinking admission regression', () {
    setUp(() {
      // OpenCode Go instance (gpt-6-luna): no settings, provider-reported or models.dev evidence => unknown
      repo.createInstance(
        ProviderInstance(
          id: 'inst-opencode',
          templateId: 'opencode-go',
          displayName: 'OpenCode Go',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gpt-6-luna',
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'inst-opencode',
        cacheKey: 'models',
        models: [
          {
            'value': 'gpt-6-luna',
            'model_metadata': {}, // No reported evidence => unknown
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      // Create Moonshot instance (kimi-for-coding, unknown thinking)
      repo.createInstance(
        ProviderInstance(
          id: 'inst-moonshot',
          templateId: 'moonshot',
          displayName: 'Moonshot',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'kimi-for-coding',
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'inst-moonshot',
        cacheKey: 'models',
        models: [
          {
            'value': 'kimi-for-coding',
            'model_metadata': {},
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      // Create Codex instance (gpt-6-luna with native reasoning levels => supported)
      repo.createInstance(
        ProviderInstance(
          id: 'inst-codex',
          templateId: 'openai-codex',
          displayName: 'ChatGPT Codex',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gpt-6-luna',
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'inst-codex',
        cacheKey: 'models',
        models: [
          {
            'value': 'gpt-6-luna',
            'model_metadata': {
              'supported_reasoning_levels': [
                {'effort': 'low'},
                {'effort': 'medium'},
                {'effort': 'high'},
              ],
              'default_reasoning_level': 'medium',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      // Ensure inst-1 has o3 with supported effort thinking
      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
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
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
    });

    test(
      'legitimate route admission succeeds for OpenCode Go gpt-6-luna when session has inherited thinkingMode',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'o3',
          providerId: 'inst-1',
          thinkingMode: 'high',
        );
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // Turn routes to OpenCode Go gpt-6-luna without specifying explicit thinkingMode
        final response = await runner.sendMessage(
          'Hello OpenCode Go',
          providerId: 'inst-opencode',
          model: 'gpt-6-luna',
        );

        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());
      },
    );

    test(
      'legitimate route admission succeeds for Moonshot kimi-for-coding when session has inherited thinkingMode',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'o3',
          providerId: 'inst-1',
          thinkingMode: 'high',
        );
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // Turn routes to Moonshot kimi-for-coding without specifying explicit thinkingMode
        final response = await runner.sendMessage(
          'Hello Moonshot',
          providerId: 'inst-moonshot',
          model: 'kimi-for-coding',
        );

        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());
      },
    );

    test(
      'ChatGPT Codex gpt-6-luna admits supported thinking with wire directive',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'gpt-6-luna',
          providerId: 'inst-codex',
        );
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Hello Codex',
          providerId: 'inst-codex',
          model: 'gpt-6-luna',
          thinkingMode: 'medium',
        );

        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(
          adapter.lastOptions?.thinkingDirective,
          isA<ResponsesReasoningDirective>(),
        );
        expect(
          (adapter.lastOptions!.thinkingDirective as ResponsesReasoningDirective).effort,
          'medium',
        );
      },
    );

    test(
      'explicit thinking selection on OpenCode Go gpt-6-luna with no reported set is admitted with provider default',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'gpt-6-luna',
          providerId: 'inst-opencode',
        );
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // No authority layer reports a set: the selection passes through
        // unchanged and the turn runs with the provider default (no field).
        final response = await runner.sendMessage(
          'Hello explicit with unknown set',
          providerId: 'inst-opencode',
          model: 'gpt-6-luna',
          thinkingMode: 'high',
        );
        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());
      },
    );

    test(
      'explicit thinking selection on Moonshot kimi-for-coding with no reported set is admitted with provider default',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'kimi-for-coding',
          providerId: 'inst-moonshot',
        );
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // No authority layer reports a set: the selection passes through
        // unchanged and the turn runs with the provider default (no field).
        final response = await runner.sendMessage(
          'Hello explicit with unknown set',
          providerId: 'inst-moonshot',
          model: 'kimi-for-coding',
          thinkingMode: 'high',
        );
        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());
      },
    );

    test(
      'persisted valid choices are preserved across route switches without choice clearing',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'o3',
          providerId: 'inst-1',
          thinkingMode: 'high',
        );
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // Turn 1 on o3 with explicit high
        final res1 = await runner.sendMessage(
          'Turn 1 on o3',
          providerId: 'inst-1',
          model: 'o3',
          thinkingMode: 'high',
        );
        expect(res1.content, 'ok');
        expect(
          (adapter.lastOptions!.thinkingDirective as OpenAiEffortDirective).effort,
          'high',
        );

        // Turn 2 switch to opencode gpt-6-luna (unsupported thinking)
        final res2 = await runner.sendMessage(
          'Turn 2 on gpt-6-luna',
          providerId: 'inst-opencode',
          model: 'gpt-6-luna',
        );
        expect(res2.content, 'ok');
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());

        // Turn 3 switch back to o3 without specifying thinkingMode: should restore high
        final res3 = await runner.sendMessage(
          'Turn 3 back on o3',
          providerId: 'inst-1',
          model: 'o3',
        );
        expect(res3.content, 'ok');
        expect(
          adapter.lastOptions?.thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(
          (adapter.lastOptions!.thinkingDirective as OpenAiEffortDirective).effort,
          'high',
        );
      },
    );

    test(
      'saved route preference becoming unavailable after upstream capability revision falls back to provider default without admission crash',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession('o1', providerId: 'inst-1');

        preferenceStore.savePreference(
          sessionId: session.sessionId,
          preference: const ThinkingRoutePreference(
            selectionId: 'low',
            providerInstanceId: 'inst-1',
            modelId: 'o1',
            capabilityRevision: 'rev-1',
          ),
        );

        // Capability revision 2 removes 'low'
        repo.upsertModelCache(
          instanceId: 'inst-1',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
                {'effort': 'medium'},
                {'effort': 'high'},
              ],
              'default_reasoning_level': 'medium',
              'supports_reasoning_output': true,
              'thinking_control': {
                'status': 'supported',
                'kind': 'effort',
                'options': [
                  {'id': 'medium', 'label': 'Medium'},
                ],
                'capability_revision': 'rev-2',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Hello after capability revision',
          providerId: 'inst-1',
          model: 'o1',
        );

        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());
        expect(
          preferenceStore.readCorrection(session.sessionId)?.reason,
          ThinkingSelectionErrorCode.optionUnavailable,
        );
      },
    );

    test(
      'legacy session on unsupported route with legacy thinkingMode admits turn as provider default without metadata',
      () async {
        final adapter = _CountingAdapter();
        final session = sessionManager.createSession(
          'gpt-6-luna',
          providerId: 'inst-opencode',
          thinkingMode: 'high',
        );

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Hello legacy session',
          providerId: 'inst-opencode',
          model: 'gpt-6-luna',
        );

        expect(response.content, 'ok');
        expect(adapter.callCount, 1);
        expect(adapter.lastOptions?.thinkingDirective, isA<UseProviderDefault>());
        // An unknown set is not a rejection, so no correction is recorded.
        expect(preferenceStore.readCorrection(session.sessionId), isNull);
      },
    );
  });

  group('Task 115 - auto-failover thinking inheritance runner regressions', () {
    test(
      'auto-failover preserves supported inherited thinking selection onto candidate route',
      () async {
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-p1',
            templateId: 'openai',
            displayName: 'Primary',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-p1',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
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
                ],
                'capability_revision': 'rev-p1',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-p2',
            templateId: 'openai',
            displayName: 'Candidate',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-p2',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
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
                ],
                'capability_revision': 'rev-p2',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final session = sessionManager.createSession(
          'o1',
          providerId: 'failover-p1',
          thinkingMode: 'medium',
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limit on primary',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'recovered on candidate',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Trigger auto-failover',
          providerId: 'failover-p1',
          model: 'o1',
          thinkingMode: 'medium',
        );

        expect(response.content, 'recovered on candidate');
        expect(adapter.callCount, 2);

        // 1. Directives and wire options asserted on attempt 1 and candidate attempt 2
        expect(adapter.recordedOptions[0].providerInstanceId, 'failover-p1');
        expect(
          adapter.recordedOptions[0].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(
          (adapter.recordedOptions[0].thinkingDirective as OpenAiEffortDirective)
              .effort,
          'medium',
        );
        expect(adapter.recordedOptions[0].thinkingMode, 'medium');

        expect(adapter.recordedOptions[1].providerInstanceId, 'failover-p2');
        expect(
          adapter.recordedOptions[1].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(
          (adapter.recordedOptions[1].thinkingDirective as OpenAiEffortDirective)
              .effort,
          'medium',
        );
        expect(adapter.recordedOptions[1].thinkingMode, 'medium');
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.providerInstanceId,
          'failover-p2',
        );

        // 2. Session mode asserted
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          'failover-p2',
        );
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          'medium',
        );

        // 3. Stored candidate preference asserted
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'failover-p2',
                modelId: 'o1',
              )
              ?.selectionId,
          'medium',
        );
        expect(preferenceStore.readCorrection(session.sessionId), isNull);
      },
    );

    test(
      'auto-failover to unsupported candidate routes through same-route legacy branch and updates session and store without spurious correction',
      () async {
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-u1',
            templateId: 'openai',
            displayName: 'Primary Supported',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-u1',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              'supports_reasoning_output': true,
              'model_metadata': {
                'supported_reasoning_levels': [
                  {'effort': 'medium'},
                  {'effort': 'high'},
                ],
                'default_reasoning_level': 'medium',
                'supports_image_input': true,
              },
              'thinking_control': {
                'status': 'supported',
                'kind': 'effort',
                'options': [
                  {'id': 'low', 'label': 'Low'},
                  {'id': 'medium', 'label': 'Medium'},
                ],
                'capability_revision': 'rev-u1',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-u2',
            templateId: kCustomProviderTemplateId,
            displayName: 'Candidate Unsupported',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-u2',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              'model_metadata': {
                'supports_image_input': false,
                'thinking_control': {
                  'status': 'unsupported',
                },
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final session = sessionManager.createSession(
          'o1',
          providerId: 'failover-u1',
          thinkingMode: 'medium',
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limit on primary',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'recovered on unsupported candidate',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Trigger auto-failover to unsupported',
          providerId: 'failover-u1',
          model: 'o1',
          thinkingMode: 'medium',
        );

        expect(response.content, 'recovered on unsupported candidate');
        expect(adapter.callCount, 2);

        // Wire options on attempt 1 (primary)
        expect(adapter.recordedOptions[0].providerInstanceId, 'failover-u1');
        expect(
          adapter.recordedOptions[0].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(adapter.recordedOptions[0].thinkingMode, 'medium');
        expect(
          adapter.recordedOptions[0].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );

        // Wire options on attempt 2 (candidate after failover)
        expect(adapter.recordedOptions[1].providerInstanceId, 'failover-u2');
        expect(
          adapter.recordedOptions[1].thinkingDirective,
          isA<UseProviderDefault>(),
        );
        expect(adapter.recordedOptions[1].thinkingMode, isNull);
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.providerInstanceId,
          'failover-u2',
        );
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.unsupported,
        );

        // 1. Session mode cleared to null (provider-default)
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          'failover-u2',
        );
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          isNull,
        );

        // 2. Stored candidate preference is provider-default (null)
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'failover-u2',
                modelId: 'o1',
              )
              ?.selectionId,
          isNull,
        );

        // 3. No spurious correction recorded
        expect(preferenceStore.readCorrection(session.sessionId), isNull);

        // 4. Candidate authoritative directive is UseProviderDefault
        final candidateResolution = GetIt.I<ThinkingSelectionResolver>().resolve(
          providerInstanceId: 'failover-u2',
          modelId: 'o1',
          selectionId: sessionManager.getSession(session.sessionId)?.thinkingMode,
        );
        expect(candidateResolution.directive, isA<UseProviderDefault>());
      },
    );

    test(
      'auto-failover respects stored candidate preference over inherited mode',
      () async {
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-s1',
            templateId: 'openai',
            displayName: 'Primary',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o3',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-s1',
          cacheKey: 'models',
          models: [
            {
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
                'capability_revision': 'rev-s1',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-s2',
            templateId: 'openai',
            displayName: 'Candidate with stored low',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o3',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-s2',
          cacheKey: 'models',
          models: [
            {
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
                'capability_revision': 'rev-s2',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final session = sessionManager.createSession(
          'o3',
          providerId: 'failover-s1',
          thinkingMode: 'medium',
        );

        // Pre-store candidate preference as 'low'
        preferenceStore.savePreference(
          sessionId: session.sessionId,
          preference: const ThinkingRoutePreference(
            selectionId: 'low',
            providerInstanceId: 'failover-s2',
            modelId: 'o3',
            capabilityRevision: 'rev-s2',
          ),
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limit on primary',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'recovered on candidate with stored low',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Trigger auto-failover with candidate preference',
          providerId: 'failover-s1',
          model: 'o3',
          thinkingMode: 'medium',
        );

        expect(response.content, 'recovered on candidate with stored low');
        expect(adapter.callCount, 2);

        // Wire options on attempt 1 (primary)
        expect(adapter.recordedOptions[0].providerInstanceId, 'failover-s1');
        expect(
          adapter.recordedOptions[0].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(adapter.recordedOptions[0].thinkingMode, 'medium');

        // Wire options on attempt 2 (candidate after failover with stored preference)
        expect(adapter.recordedOptions[1].providerInstanceId, 'failover-s2');
        expect(
          adapter.recordedOptions[1].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(
          (adapter.recordedOptions[1].thinkingDirective as OpenAiEffortDirective)
              .effort,
          'low',
        );
        expect(adapter.recordedOptions[1].thinkingMode, 'low');
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.providerInstanceId,
          'failover-s2',
        );

        // 1. Session mode updated to stored candidate preference 'low'
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          'failover-s2',
        );
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          'low',
        );

        // 2. Stored candidate preference remains 'low'
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'failover-s2',
                modelId: 'o3',
              )
              ?.selectionId,
          'low',
        );

        // 3. No spurious correction recorded
        expect(preferenceStore.readCorrection(session.sessionId), isNull);

        // 4. Candidate authoritative directive is OpenAiEffortDirective('low')
        final candidateResolution = GetIt.I<ThinkingSelectionResolver>().resolve(
          providerInstanceId: 'failover-s2',
          modelId: 'o3',
          selectionId: sessionManager.getSession(session.sessionId)?.thinkingMode,
        );
        expect(candidateResolution.directive, isA<OpenAiEffortDirective>());
        expect(
          (candidateResolution.directive as OpenAiEffortDirective).effort,
          'low',
        );
      },
    );

    test(
      'auto-failover respects stored candidate provider-default over inherited mode',
      () async {
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-d1',
            templateId: 'openai',
            displayName: 'Primary',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-d1',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
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
                ],
                'capability_revision': 'rev-d1',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        repo.createInstance(
          ProviderInstance(
            id: 'failover-d2',
            templateId: 'openai',
            displayName: 'Candidate with stored default',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'failover-d2',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
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
                ],
                'capability_revision': 'rev-d2',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final session = sessionManager.createSession(
          'o1',
          providerId: 'failover-d1',
          thinkingMode: 'medium',
        );

        // Pre-store candidate preference as provider-default (selectionId: null)
        preferenceStore.savePreference(
          sessionId: session.sessionId,
          preference: const ThinkingRoutePreference(
            selectionId: null,
            providerInstanceId: 'failover-d2',
            modelId: 'o1',
            capabilityRevision: 'provider-default',
          ),
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limit on primary',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'recovered on candidate with default',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Trigger auto-failover with candidate default',
          providerId: 'failover-d1',
          model: 'o1',
          thinkingMode: 'medium',
        );

        expect(response.content, 'recovered on candidate with default');
        expect(adapter.callCount, 2);

        // Wire options on attempt 1 (primary)
        expect(adapter.recordedOptions[0].providerInstanceId, 'failover-d1');
        expect(
          adapter.recordedOptions[0].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(adapter.recordedOptions[0].thinkingMode, 'medium');

        // Wire options on attempt 2 (candidate after failover with stored default)
        expect(adapter.recordedOptions[1].providerInstanceId, 'failover-d2');
        expect(
          adapter.recordedOptions[1].thinkingDirective,
          isA<UseProviderDefault>(),
        );
        expect(adapter.recordedOptions[1].thinkingMode, isNull);
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.providerInstanceId,
          'failover-d2',
        );

        // 1. Session mode cleared to null (stored candidate default wins!)
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          'failover-d2',
        );
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          isNull,
        );

        // 2. Stored candidate preference is provider-default (null)
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'failover-d2',
                modelId: 'o1',
              )
              ?.selectionId,
          isNull,
        );

        // 3. No spurious correction recorded
        expect(preferenceStore.readCorrection(session.sessionId), isNull);

        // 4. Candidate authoritative directive is UseProviderDefault
        final candidateResolution = GetIt.I<ThinkingSelectionResolver>().resolve(
          providerInstanceId: 'failover-d2',
          modelId: 'o1',
          selectionId: sessionManager.getSession(session.sessionId)?.thinkingMode,
        );
        expect(candidateResolution.directive, isA<UseProviderDefault>());
      },
    );
  });

  group('Task 115 - route-checked profile reuse and retry wake regressions', () {
    test(
      'external provider switch during retry wait dispatches new route directive and imageSupport',
      () async {
        final recovery = RuntimeRecoveryService(
          repo,
          ProviderRateLimiter(),
          autoFailoverEnabled: false,
        );
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recovery);

        // Primary route: inst-retry-a, o1 (vision supported, effort medium supported)
        repo.createInstance(
          ProviderInstance(
            id: 'inst-retry-a',
            templateId: 'openai',
            displayName: 'Primary Retry Instance',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'inst-retry-a',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
                {'effort': 'medium'},
                {'effort': 'high'},
              ],
              'default_reasoning_level': 'medium',
              'supports_vision': true,
              'supports_reasoning_output': true,
              'thinking_control': {
                'status': 'supported',
                'kind': 'effort',
                'options': [
                  {'id': 'low', 'label': 'Low'},
                  {'id': 'medium', 'label': 'Medium'},
                ],
                'capability_revision': 'rev-retry-a',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        // Switched route: inst-retry-b, gpt-6-luna (vision unsupported, thinking unsupported)
        repo.createInstance(
          ProviderInstance(
            id: 'inst-retry-b',
            templateId: 'opencode-go',
            displayName: 'Switched Retry Instance',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'gpt-6-luna',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'inst-retry-b',
          cacheKey: 'models',
          models: [
            {
              'value': 'gpt-6-luna',
              'model_metadata': {
                'supports_image_input': false,
              }, // No reasoning -> unsupported, supports_image_input false -> unsupported
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-retry-a',
          thinkingMode: 'medium',
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            // Asynchronously switch session route and wake runner from retry wait
            Future.delayed(const Duration(milliseconds: 50), () {
              sessionManager.updateSessionModeling(
                session.sessionId,
                providerId: 'inst-retry-b',
                model: 'gpt-6-luna',
                clearThinkingMode: true,
              );
              recovery.abort(session.sessionId);
            });

            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limited on primary',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'recovered after external switch',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Test external switch during retry wait',
          providerId: 'inst-retry-a',
          model: 'o1',
          thinkingMode: 'medium',
        );

        expect(response.content, 'recovered after external switch');
        expect(adapter.callCount, 2);

        // Attempt 1: primary route (inst-retry-a)
        expect(adapter.recordedOptions[0].providerInstanceId, 'inst-retry-a');
        expect(
          adapter.recordedOptions[0].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );
        expect(adapter.recordedOptions[0].thinkingMode, 'medium');
        expect(
          adapter.recordedOptions[0].routeCapabilityProfile?.providerInstanceId,
          'inst-retry-a',
        );
        expect(
          adapter.recordedOptions[0].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );

        // Attempt 2: switched route (inst-retry-b)
        expect(adapter.recordedOptions[1].providerInstanceId, 'inst-retry-b');
        expect(
          adapter.recordedOptions[1].thinkingDirective,
          isA<UseProviderDefault>(),
        );
        expect(adapter.recordedOptions[1].thinkingMode, isNull);
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.providerInstanceId,
          'inst-retry-b',
        );
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.unsupported,
        );

        // Runner's active turn capability profile must reflect switched route
        expect(
          runner.debugTurnCapabilityProfile?.providerInstanceId,
          'inst-retry-b',
        );
        expect(
          runner.debugTurnCapabilityProfile?.modelId,
          'gpt-6-luna',
        );
        expect(
          runner.debugTurnCapabilityProfile?.imageSupport,
          RouteImageSupport.unsupported,
        );
      },
    );

    test(
      'same-route multi-step iterations reuse admitted profile and preserve freezing across config changes',
      () async {
        final config = GetIt.I<Config>();
        final configFile = File('${tempDir.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  o1:
    supports_image_input: true
''');

        repo.createInstance(
          ProviderInstance(
            id: 'inst-same-a',
            templateId: 'openai',
            displayName: 'Same Route Instance',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'o1',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'inst-same-a',
          cacheKey: 'models',
          models: [
            {
              'value': 'o1',
              // Provider-reported Codex-style native levels (capability authority).
              'supported_reasoning_levels': [
                {'effort': 'medium'},
                {'effort': 'high'},
              ],
              'default_reasoning_level': 'medium',
              'supports_vision': true,
              'supports_reasoning_output': true,
              'thinking_control': {
                'status': 'supported',
                'kind': 'effort',
                'options': [
                  {'id': 'low', 'label': 'Low'},
                  {'id': 'medium', 'label': 'Medium'},
                ],
                'capability_revision': 'rev-same-a',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        registry.registerTool(_SimpleTestTool());

        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-same-a',
          thinkingMode: 'medium',
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            // Mid-turn config change to simulate cache or disk mutation
            configFile.writeAsStringSync('''
model_capabilities:
  o1:
    supports_image_input: false
''');
            config.reloadModelAwarePolicy();

            return AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'calling tool',
                toolCalls: [
                  ToolCall(
                    id: 'call_1',
                    name: 'sample_tool',
                    arguments: {},
                  ),
                ],
              ),
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'completed after tool',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'Run multi-step turn',
          providerId: 'inst-same-a',
          model: 'o1',
          thinkingMode: 'medium',
        );

        expect(response.content, 'completed after tool');
        expect(adapter.callCount, 2);

        // Both iterations are on the same route (inst-same-a, o1)
        expect(adapter.recordedOptions[0].providerInstanceId, 'inst-same-a');
        expect(adapter.recordedOptions[1].providerInstanceId, 'inst-same-a');

        // Iteration 1 uses admitted profile
        expect(
          adapter.recordedOptions[0].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );
        expect(
          adapter.recordedOptions[0].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );

        // Iteration 2 reuses the frozen profile despite mid-turn config mutation
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );
        expect(
          adapter.recordedOptions[1].thinkingDirective,
          isA<OpenAiEffortDirective>(),
        );

        // Runner's debug profile remains frozen
        expect(
          runner.debugTurnCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );
      },
    );
  });

  group('Task 115 - review repair regressions', () {
    void createEffortRoute(
      String instanceId, {
      String modelId = 'o1',
      Map<String, dynamic>? modelMetadata,
      bool supportsVision = true,
    }) {
      repo.createInstance(
        ProviderInstance(
          id: instanceId,
          templateId: 'openai',
          displayName: 'Route $instanceId',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: modelId,
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: instanceId,
        cacheKey: 'models',
        models: [
          {
            'value': modelId,
            if (supportsVision) 'supports_vision': true,
            'model_metadata': ?modelMetadata,
            // Provider-reported Codex-style native levels (capability authority).
            if (modelMetadata == null) ...{
              'supported_reasoning_levels': [
                for (final effort in modelId == 'o1'
                    ? const ['medium', 'high']
                    : const ['low', 'medium', 'high'])
                  {'effort': effort},
              ],
              'default_reasoning_level': 'medium',
            },
            'supports_reasoning_output': true,
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
                {'id': 'high', 'label': 'High'},
              ],
              'capability_revision': 'rev-$instanceId',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
    }

    test(
      'explicit session thinking clear is not resurrected by the route preference store on the next same-route turn',
      () async {
        createEffortRoute('inst-clear');
        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-clear',
          thinkingMode: 'medium',
        );
        final adapter = _CountingAdapter();
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        await runner.sendMessage(
          'turn with medium',
          providerId: 'inst-clear',
          model: 'o1',
          thinkingMode: 'medium',
        );
        expect(adapter.recordedOptions.single.thinkingMode, 'medium');
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'inst-clear',
                modelId: 'o1',
              )
              ?.selectionId,
          'medium',
        );

        // Session-row-only clear (no route preference write).
        sessionManager.updateSessionModeling(
          session.sessionId,
          thinkingMode: null,
          clearThinkingMode: true,
        );

        await runner.sendMessage(
          'turn after explicit clear',
          providerId: 'inst-clear',
          model: 'o1',
        );

        final second = adapter.recordedOptions.last;
        expect(second.thinkingMode, isNull);
        expect(second.thinkingDirective, isNot(isA<OpenAiEffortDirective>()));
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          isNull,
          reason: 'the cleared session mode must not be re-persisted',
        );
      },
    );

    test(
      'update_session_preferences thinking clear records a route-scoped provider default that survives the next turn and a route round trip',
      () async {
        createEffortRoute('inst-ui-a');
        createEffortRoute('inst-ui-b');
        GetIt.I.registerSingleton<SessionManager>(sessionManager);
        GetIt.I.registerSingleton<AuthManager>(AuthManager());
        final bridge = SanadProtocolBridge();
        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-ui-a',
          thinkingMode: 'medium',
        );
        final adapter = _CountingAdapter();
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        await runner.sendMessage(
          'turn with medium',
          providerId: 'inst-ui-a',
          model: 'o1',
          thinkingMode: 'medium',
        );
        expect(adapter.recordedOptions.single.thinkingMode, 'medium');

        final envelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionPreferences,
            sessionId: session.sessionId,
            payload: {'request_id': 'req-thinking-clear', 'thinking_mode': ''},
          ),
          (envelope) async => envelopes.add(envelope),
        );
        expect(envelopes, hasLength(1));
        expect(
          envelopes.single['payload'],
          containsPair('thinking_mode', null),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          isNull,
        );
        final stored = preferenceStore.readForRoute(
          session.sessionId,
          providerInstanceId: 'inst-ui-a',
          modelId: 'o1',
        );
        expect(stored, isNotNull);
        expect(stored!.selectionId, isNull);
        expect(stored.capabilityRevision, 'provider-default');

        await runner.sendMessage(
          'turn after client clear',
          providerId: 'inst-ui-a',
          model: 'o1',
        );
        expect(adapter.recordedOptions.last.thinkingMode, isNull);
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          isNull,
        );

        // Switching away and back restores the cleared (provider-default)
        // choice for route A instead of the earlier 'medium'.
        await runner.sendMessage(
          'turn on route b',
          providerId: 'inst-ui-b',
          model: 'o1',
          thinkingMode: 'medium',
        );
        expect(adapter.recordedOptions.last.providerInstanceId, 'inst-ui-b');
        expect(adapter.recordedOptions.last.thinkingMode, 'medium');
        await runner.sendMessage(
          'turn back on route a',
          providerId: 'inst-ui-a',
          model: 'o1',
        );
        expect(adapter.recordedOptions.last.providerInstanceId, 'inst-ui-a');
        expect(adapter.recordedOptions.last.thinkingMode, isNull);
      },
    );

    test(
      'update_session_preferences explicit set survives a route round trip instead of the stale stored choice',
      () async {
        createEffortRoute('inst-g-a');
        createEffortRoute('inst-g-b');
        GetIt.I.registerSingleton<SessionManager>(sessionManager);
        GetIt.I.registerSingleton<AuthManager>(AuthManager());
        final bridge = SanadProtocolBridge();
        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-g-a',
          thinkingMode: 'medium',
        );
        final adapter = _CountingAdapter();
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );
        await runner.sendMessage(
          'turn on a',
          providerId: 'inst-g-a',
          model: 'o1',
          thinkingMode: 'medium',
        );

        final envelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionPreferences,
            sessionId: session.sessionId,
            payload: {'request_id': 'req-g', 'thinking_mode': 'high'},
          ),
          (envelope) async => envelopes.add(envelope),
        );
        expect(envelopes.single['payload'], containsPair('thinking_mode', 'high'));
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'inst-g-a',
                modelId: 'o1',
              )
              ?.selectionId,
          'high',
        );

        await runner.sendMessage(
          'turn on b',
          providerId: 'inst-g-b',
          model: 'o1',
          thinkingMode: 'medium',
        );
        await runner.sendMessage(
          'back to a',
          providerId: 'inst-g-a',
          model: 'o1',
        );
        expect(adapter.recordedOptions.last.providerInstanceId, 'inst-g-a');
        expect(
          adapter.recordedOptions.last.thinkingMode,
          'high',
          reason: 'route A must restore the explicit high, not the stale medium',
        );
      },
    );

    test(
      'update_session_preferences set with a route change records the choice for the target route and keeps row-only writes for unoffered options',
      () async {
        createEffortRoute('inst-h-a');
        createEffortRoute('inst-h-b');
        GetIt.I.registerSingleton<SessionManager>(sessionManager);
        GetIt.I.registerSingleton<AuthManager>(AuthManager());
        final bridge = SanadProtocolBridge();
        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-h-a',
          thinkingMode: 'medium',
        );
        final adapter = _CountingAdapter();
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );
        await runner.sendMessage(
          'turn on a',
          providerId: 'inst-h-a',
          model: 'o1',
          thinkingMode: 'medium',
        );

        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionPreferences,
            sessionId: session.sessionId,
            payload: {
              'request_id': 'req-h',
              'provider_instance_id': 'inst-h-b',
              'model': 'o1',
              'thinking_mode': 'high',
            },
          ),
          (envelope) async {},
        );
        final moved = sessionManager.getSession(session.sessionId);
        expect(moved?.providerId, 'inst-h-b');
        expect(moved?.thinkingMode, 'high');
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'inst-h-b',
                modelId: 'o1',
              )
              ?.selectionId,
          'high',
        );
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'inst-h-a',
                modelId: 'o1',
              )
              ?.selectionId,
          'medium',
          reason: 'the source route keeps its own remembered choice',
        );

        await runner.sendMessage(
          'turn on b',
          providerId: 'inst-h-b',
          model: 'o1',
        );
        expect(adapter.recordedOptions.last.thinkingMode, 'high');

        // An option the route does not offer keeps the row-only write; turn
        // admission then corrects it to provider default as before.
        final envelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionPreferences,
            sessionId: session.sessionId,
            payload: {'request_id': 'req-h-bad', 'thinking_mode': 'ultra'},
          ),
          (envelope) async => envelopes.add(envelope),
        );
        expect(envelopes.single['payload'], containsPair('thinking_mode', 'ultra'));
        expect(
          sessionManager.getSession(session.sessionId)?.thinkingMode,
          'ultra',
        );
        expect(
          preferenceStore
              .readForRoute(
                session.sessionId,
                providerInstanceId: 'inst-h-b',
                modelId: 'o1',
              )
              ?.selectionId,
          'high',
        );
        await runner.sendMessage(
          'turn after unoffered set',
          providerId: 'inst-h-b',
          model: 'o1',
        );
        expect(adapter.recordedOptions.last.thinkingMode, isNull);
        expect(
          preferenceStore.readCorrection(session.sessionId)?.previousSelectionId,
          'ultra',
        );
      },
    );

    test(
      'repeated effectiveThinkingMode reads record one correction without metadata churn',
      () async {
        createEffortRoute('inst-idem');
        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-idem',
          thinkingMode: 'ultra',
        );
        final routeState = TurnRouteState(
          sessionId: session.sessionId,
          fallbackAdapter: _CountingAdapter(),
          sessionManager: sessionManager,
          contextAssembler: AgentContextAssembler(identity: 'test'),
        );

        expect(routeState.effectiveThinkingMode, isNull);
        final afterFirst = jsonEncode(
          sessionManager.getSessionMetadata(session.sessionId),
        );
        expect(
          preferenceStore.readCorrection(session.sessionId)?.previousSelectionId,
          'ultra',
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(routeState.effectiveThinkingMode, isNull);
        expect(routeState.effectiveThinkingMode, isNull);
        expect(
          jsonEncode(sessionManager.getSessionMetadata(session.sessionId)),
          afterFirst,
          reason: 'repeat reads must not rewrite metadata or re-stamp corrected_at',
        );
      },
    );

    test(
      'same-route interrupted-retry wake keeps the admitted capability profile frozen',
      () async {
        final config = GetIt.I<Config>();
        final configFile = File('${tempDir.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  o1:
    supports_image_input: true
''');
        config.reloadModelAwarePolicy();
        createEffortRoute('inst-wake-a');

        final recovery = RuntimeRecoveryService(
          repo,
          ProviderRateLimiter(),
          autoFailoverEnabled: false,
        );
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recovery);

        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-wake-a',
          thinkingMode: 'medium',
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            Future.delayed(const Duration(milliseconds: 50), () {
              // Capability changes mid-wait; the session route does not.
              configFile.writeAsStringSync('''
model_capabilities:
  o1:
    supports_image_input: false
''');
              config.reloadModelAwarePolicy();
              recovery.abort(session.sessionId);
            });
            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limited on the only route',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'recovered after same-route wake',
            ),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage(
          'same-route retry wake',
          providerId: 'inst-wake-a',
          model: 'o1',
          thinkingMode: 'medium',
        );

        expect(response.content, 'recovered after same-route wake');
        expect(adapter.callCount, 2);
        expect(adapter.recordedOptions[1].providerInstanceId, 'inst-wake-a');
        final first = adapter.recordedOptions[0].routeCapabilityProfile;
        final second = adapter.recordedOptions[1].routeCapabilityProfile;
        expect(first?.imageSupport, RouteImageSupport.supported);
        expect(second?.imageSupport, RouteImageSupport.supported);
        expect(identical(first, second), isTrue);
        expect(adapter.recordedOptions[1].thinkingMode, 'medium');
        expect(
          runner.debugTurnCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );
      },
    );

    test(
      'request-option queries outside an admitted turn do not rewrite the turn capability profile',
      () async {
        createEffortRoute('inst-idle-a');
        createEffortRoute('inst-idle-b');
        final session = sessionManager.createSession(
          'o1',
          providerId: 'inst-idle-a',
          thinkingMode: 'medium',
        );
        final adapter = _CountingAdapter();
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        await runner.sendMessage(
          'completed turn',
          providerId: 'inst-idle-a',
          model: 'o1',
          thinkingMode: 'medium',
        );
        final admitted = runner.debugTurnCapabilityProfile;
        expect(admitted?.providerInstanceId, 'inst-idle-a');

        final foreign = runner.debugRequestOptionsForTurn('inst-idle-b');
        expect(
          foreign.routeCapabilityProfile?.providerInstanceId,
          'inst-idle-b',
        );
        expect(identical(runner.debugTurnCapabilityProfile, admitted), isTrue);
      },
    );

    test(
      'route-checked profile reuse compares trimmed route identities on both sides',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-pad',
            templateId: 'openai',
            displayName: 'Padded Route',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'pad-model',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        registry.registerTool(_SimpleTestTool());
        final session = sessionManager.createSession(
          'pad-model',
          providerId: 'inst-pad',
        );
        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            return AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'calling tool',
                toolCalls: [
                  ToolCall(id: 'call_pad', name: 'sample_tool', arguments: {}),
                ],
              ),
            );
          }
          return AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'done'),
          );
        };
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // The resolver stores the model id as routed (untrimmed); reuse must
        // still match the same route on the next iteration.
        await runner.sendMessage(
          'padded route turn',
          providerId: 'inst-pad',
          model: 'pad-model ',
        );

        expect(adapter.callCount, 2);
        expect(
          identical(
            adapter.recordedOptions[0].routeCapabilityProfile,
            adapter.recordedOptions[1].routeCapabilityProfile,
          ),
          isTrue,
        );
      },
    );

    test(
      'auto-failover projects user image attachments and ToolContext.imageSupport from the candidate route',
      () async {
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );
        final attachments = AttachmentStore(state, stateHome: tempDir.path);
        await attachments.initialize();
        GetIt.I.registerSingleton<AttachmentStore>(attachments);

        createEffortRoute('vision-p1');
        createEffortRoute(
          'vision-p2',
          supportsVision: false,
          modelMetadata: {'supports_image_input': false},
        );

        final probeTool = _ImageSupportProbeTool();
        registry.registerTool(probeTool);

        final session = sessionManager.createSession(
          'o1',
          providerId: 'vision-p1',
        );
        const requestId = 'req-failover-image';
        final pngBytes = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
        final upload = await attachments.create(
          fileName: 'photo.png',
          declaredMime: 'image/png',
          expectedSize: pngBytes.length,
          expectedSha256: sha256.convert(pngBytes).toString(),
        );
        await attachments.write(upload, pngBytes);
        final attachment = await attachments.commit(
          upload,
          sessionId: session.sessionId,
          admissionId: requestId,
        );

        final adapter = _CountingAdapter();
        adapter.onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 429,
              body: 'Rate limit on vision primary',
              headers: {},
              operation: 'chat.completions',
            );
          }
          if (count == 2) {
            return AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'probing tool context',
                toolCalls: [
                  ToolCall(
                    id: 'call_image_probe',
                    name: 'image_support_probe',
                    arguments: {},
                  ),
                ],
              ),
            );
          }
          return AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'done'),
          );
        };

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
          attachmentStore: attachments,
        );
        runner.configureUserAttachments([attachment]);

        final response = await runner.sendMessage(
          'Describe this photo',
          requestId: requestId,
          providerId: 'vision-p1',
          model: 'o1',
        );

        expect(response.content, 'done');
        expect(adapter.callCount, 3);
        expect(adapter.recordedOptions[0].providerInstanceId, 'vision-p1');
        expect(
          adapter.recordedOptions[0].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.supported,
        );
        expect(adapter.recordedOptions[1].providerInstanceId, 'vision-p2');
        expect(
          adapter.recordedOptions[1].routeCapabilityProfile?.imageSupport,
          RouteImageSupport.unsupported,
        );

        Message userTurn(List<dynamic> history) => history
            .whereType<Message>()
            .lastWhere((m) => m.role == MessageRole.user);

        // Attempt 1 (vision route) keeps the image as a native attachment.
        final primaryUser = userTurn(adapter.recordedHistories[0]);
        expect(primaryUser.attachments, hasLength(1));
        expect(
          primaryUser.content,
          isNot(contains('Agent-local attachments')),
        );

        // Candidate attempt projects the image to honest text guidance.
        final candidateUser = userTurn(adapter.recordedHistories[1]);
        expect(candidateUser.attachments, isEmpty);
        expect(candidateUser.content, contains('Agent-local attachments'));
        expect(
          candidateUser.content,
          contains(
            'image inspection is not supported by the current model route',
          ),
        );

        // Tool execution on the candidate route sees candidate capability.
        expect(probeTool.observed, [RouteImageSupport.unsupported]);
      },
    );
  });

  group('reactive 400 recovery when the provider rejects the thinking field', () {
    late SessionThinkingFieldSuppression suppression;

    setUp(() {
      suppression = SessionThinkingFieldSuppression();
      GetIt.I.registerSingleton<SessionThinkingFieldSuppression>(suppression);
      repo.createInstance(
        ProviderInstance(
          id: 'inst-400',
          templateId: 'openai',
          displayName: 'OpenAI 400',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'o3',
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'inst-400',
        cacheKey: 'models',
        models: [
          {
            'value': 'o3',
            'supported_reasoning_levels': [
              {'effort': 'low'},
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
    });

    AgentRunner runnerFor(String sessionId, _CountingAdapter adapter) =>
        AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: sessionId,
        );

    test('retries the same request exactly once without the field and '
        'remembers the route for the rest of the session', () async {
      final session = sessionManager.createSession('o3', providerId: 'inst-400');
      final adapter = _CountingAdapter()
        ..onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 400,
              body:
                  '{"error":{"message":"Unsupported parameter: '
                  "'reasoning_effort' is not supported with this model.\"}}",
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'ok'),
          );
        };

      final response = await runnerFor(session.sessionId, adapter).sendMessage(
        'hi',
        providerId: 'inst-400',
        model: 'o3',
        thinkingMode: 'high',
      );

      expect(response.content, 'ok');
      expect(adapter.callCount, 2, reason: 'exactly one retry');
      expect(
        adapter.recordedOptions[0].thinkingDirective,
        isA<OpenAiEffortDirective>(),
      );
      expect(
        adapter.recordedOptions[1].thinkingDirective,
        isA<UseProviderDefault>(),
      );
      expect(
        suppression.isSuppressed(session.sessionId, 'inst-400', 'o3', 'high'),
        isTrue,
      );

      // The next turn on the same session and route sends no thinking field
      // without another failed request.
      final next = _CountingAdapter();
      await runnerFor(session.sessionId, next).sendMessage(
        'again',
        providerId: 'inst-400',
        model: 'o3',
        thinkingMode: 'high',
      );
      expect(next.callCount, 1);
      expect(next.lastOptions?.thinkingDirective, isA<UseProviderDefault>());

      // Another session is unaffected (no global state).
      final other = sessionManager.createSession('o3', providerId: 'inst-400');
      final otherAdapter = _CountingAdapter();
      await runnerFor(other.sessionId, otherAdapter).sendMessage(
        'other',
        providerId: 'inst-400',
        model: 'o3',
        thinkingMode: 'high',
      );
      expect(
        otherAdapter.lastOptions?.thinkingDirective,
        isA<OpenAiEffortDirective>(),
      );
    });

    test('G1: a rejected selection suppresses only that value; a later '
        'different selection on the same session is still sent', () async {
      final session = sessionManager.createSession('o3', providerId: 'inst-400');
      final adapter = _CountingAdapter()
        ..onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 400,
              body:
                  '{"error":{"message":"thinking is not supported: the model '
                  'is thinking-only and disabling is not supported."}}',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'ok'),
          );
        };
      await runnerFor(session.sessionId, adapter).sendMessage(
        'hi',
        providerId: 'inst-400',
        model: 'o3',
        thinkingMode: 'low',
      );
      expect(adapter.callCount, 2, reason: 'exactly one retry');
      expect(
        suppression.isSuppressed(session.sessionId, 'inst-400', 'o3', 'low'),
        isTrue,
      );
      expect(
        suppression.isSuppressed(session.sessionId, 'inst-400', 'o3', 'high'),
        isFalse,
      );

      // A later, different explicit selection is honoured on the wire.
      final high = _CountingAdapter();
      await runnerFor(session.sessionId, high).sendMessage(
        'again',
        providerId: 'inst-400',
        model: 'o3',
        thinkingMode: 'high',
      );
      expect(high.callCount, 1);
      final directive = high.lastOptions?.thinkingDirective;
      expect(directive, isA<OpenAiEffortDirective>());
      expect((directive as OpenAiEffortDirective).effort, 'high');

      // The rejected value itself stays suppressed (no second failed call).
      final lowAgain = _CountingAdapter();
      await runnerFor(session.sessionId, lowAgain).sendMessage(
        'low again',
        providerId: 'inst-400',
        model: 'o3',
        thinkingMode: 'low',
      );
      expect(lowAgain.callCount, 1);
      expect(
        lowAgain.lastOptions?.thinkingDirective,
        isA<UseProviderDefault>(),
      );
    });

    test('the streaming path retries once without the field too', () async {
      final session = sessionManager.createSession('o3', providerId: 'inst-400');
      final adapter = _CountingAdapter()
        ..onGenerate = (count, options) {
          if (count == 1) {
            throw const LlmHttpException(
              statusCode: 400,
              body: 'Unrecognized request argument supplied: reasoning_effort',
              headers: {},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'ok'),
          );
        };
      final chunks = await runnerFor(session.sessionId, adapter)
          .streamMessage(
            'hi',
            providerId: 'inst-400',
            model: 'o3',
            thinkingMode: 'high',
          )
          .toList();
      expect(chunks.join(), contains('ok'));
      expect(adapter.callCount, 2);
      expect(
        adapter.recordedOptions[1].thinkingDirective,
        isA<UseProviderDefault>(),
      );
    });

    test('a second thinking-field 400 is not retried again (no loop)',
        () async {
      final session = sessionManager.createSession('o3', providerId: 'inst-400');
      final adapter = _CountingAdapter()
        ..onGenerate = (count, options) {
          throw const LlmHttpException(
            statusCode: 400,
            body: 'reasoning_effort: unsupported parameter',
            headers: {},
            operation: 'chat.completions',
          );
        };
      await expectLater(
        runnerFor(session.sessionId, adapter).sendMessage(
          'hi',
          providerId: 'inst-400',
          model: 'o3',
          thinkingMode: 'high',
        ),
        throwsA(anything),
      );
      expect(adapter.callCount, 2);
    });

    test('a 400 that does not reject the thinking field is not retried',
        () async {
      final session = sessionManager.createSession('o3', providerId: 'inst-400');
      final adapter = _CountingAdapter()
        ..onGenerate = (count, options) {
          throw const LlmHttpException(
            statusCode: 400,
            body:
                '{"error":{"message":"Invalid value for messages[1].content"}}',
            headers: {},
            operation: 'chat.completions',
          );
        };
      await expectLater(
        runnerFor(session.sessionId, adapter).sendMessage(
          'hi',
          providerId: 'inst-400',
          model: 'o3',
          thinkingMode: 'high',
        ),
        throwsA(anything),
      );
      expect(adapter.callCount, 1);
      expect(
        suppression.isSuppressed(session.sessionId, 'inst-400', 'o3', 'high'),
        isFalse,
      );
    });

    test('a thinking-field 400 on a request without the field is not retried',
        () async {
      final session = sessionManager.createSession('o3', providerId: 'inst-400');
      final adapter = _CountingAdapter()
        ..onGenerate = (count, options) {
          throw const LlmHttpException(
            statusCode: 400,
            body: 'reasoning_effort is not supported',
            headers: {},
            operation: 'chat.completions',
          );
        };
      await expectLater(
        runnerFor(session.sessionId, adapter).sendMessage(
          'hi',
          providerId: 'inst-400',
          model: 'o3',
        ),
        throwsA(anything),
      );
      expect(adapter.callCount, 1);
    });
  });
}
