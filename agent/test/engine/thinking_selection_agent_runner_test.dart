import 'package:get_it/get_it.dart';
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
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

class _CountingAdapter implements LLMAdapter {
  int callCount = 0;
  LLMRequestOptions? lastOptions;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    lastOptions = options;
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

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late SessionManager sessionManager;
  late ToolsRegistry registry;

  setUp(() {
    GetIt.I.reset();
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

  tearDown(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state.dispose();
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

  test('supported explicit thinking selection reaches adapter directive', () async {
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
    expect(adapter.lastOptions?.thinkingDirective, isA<OpenAiEffortDirective>());
    expect(
      (adapter.lastOptions!.thinkingDirective! as OpenAiEffortDirective).effort,
      'high',
    );
  });
}
