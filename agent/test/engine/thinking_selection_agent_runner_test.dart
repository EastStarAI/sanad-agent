import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

class _CountingAdapter implements LLMAdapter {
  int callCount = 0;
  final List<LLMRequestOptions> recordedOptions = [];
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

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late SessionManager sessionManager;
  late ToolsRegistry registry;

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
    final preferenceStore = ThinkingRoutePreferenceStore(sessionManager);
    final revalidator = ThinkingRouteRevalidator(
      resolver: selectionResolver,
      store: preferenceStore,
    );

    GetIt.I.registerSingleton<ThinkingSelectionResolver>(selectionResolver);
    GetIt.I.registerSingleton<ThinkingRoutePreferenceStore>(preferenceStore);
    GetIt.I.registerSingleton<ThinkingRouteRevalidator>(revalidator);
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
}
