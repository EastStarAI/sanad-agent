import 'package:test/test.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/runtime/llm_route_snapshot.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

class FakeLLMAdapter implements LLMAdapter {
  AgentResponse? responseToReturn;
  Object? errorToThrow;
  String? lastModelOverride;
  List<Message>? lastHistory;
  LLMRequestOptions? lastOptions;
  final List<LLMRequestOptions> optionsSeen = [];
  final List<Object> scriptedOutcomes = [];
  Duration? responseDelay;

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    lastModelOverride = modelOverride;
    lastHistory = history;
    lastOptions = options;
    optionsSeen.add(options);
    if (responseDelay != null) await Future<void>.delayed(responseDelay!);
    if (scriptedOutcomes.isNotEmpty) {
      final outcome = scriptedOutcomes.removeAt(0);
      if (outcome is AgentResponse) return outcome;
      throw outcome;
    }
    if (errorToThrow != null) throw errorToThrow!;
    return responseToReturn!;
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => Stream.empty();

  @override
  Future<List<ModelOption>> getAvailableModels() async => [];

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;
}

/// Simulates the routing authority after a daemon restart: no turn has run in
/// this process, so no live session signature exists and every route must be
/// derived from the session's persisted provider instance and model.
class _RestartedRuntime extends AgentRuntimeService {
  _RestartedRuntime(super.config, super.instanceRepo);

  final Map<String, FakeLLMAdapter> providerAdapters = {};
  final FakeLLMAdapter defaultRouteAdapter = FakeLLMAdapter();
  int defaultAdapterCalls = 0;
  final List<({String? providerId, String? modelId})> resolvedSignatures = [];

  @override
  RouteSignature? sessionSignature(String sessionId) => null;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    resolvedSignatures.add((providerId: providerId, modelId: modelId));
    return RouteSignature(
      providerInstanceId: providerId!,
      templateId: 'opencode-go',
      protocol: 'openai',
      normalizedBaseUrl: 'https://opencode.example/v1',
      modelId: modelId!,
      configRevision: 1,
      credentialRevision: 1,
    );
  }

  @override
  LLMAdapter adapterFor(RouteSignature signature) => providerAdapters.putIfAbsent(
    signature.providerInstanceId,
    FakeLLMAdapter.new,
  );

  @override
  LLMAdapter defaultAdapter() {
    defaultAdapterCalls++;
    return defaultRouteAdapter;
  }
}

void main() {
  late FakeLLMAdapter fakeAdapter;
  late TitleService titleService;

  setUp(() {
    fakeAdapter = FakeLLMAdapter();
    titleService = TitleService(adapter: fakeAdapter);
  });

  group('TitleService Tests', () {
    test(
      'generateTitle successfully generates intelligent title in Arabic',
      () async {
        fakeAdapter.responseToReturn = AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'العنوان: تطوير تطبيق ديسكتوب ذكي',
          ),
        );

        final title = await titleService.generateTitle(
          sessionId: 'test-session',
          userMessage: 'كيف أنشئ تطبيق ديسكتوب ذكي باستخدام فلاتر؟',
          assistantResponse:
              'يمكنك استخدام فلاتر لإنشاء تطبيق ديسكتوب رائع وسهل.',
        );

        expect(title, equals('تطوير تطبيق ديسكتوب ذكي'));
      },
    );

    test(
      'generateTitle successfully generates intelligent title in English',
      () async {
        fakeAdapter.responseToReturn = AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: '  "Title: How to Build Flutter Apps"  ',
          ),
        );

        final title = await titleService.generateTitle(
          sessionId: 'test-session',
          userMessage: 'How do I build Flutter apps for macOS?',
          assistantResponse: 'You can use the desktop agents framework.',
        );

        expect(title, equals('How to Build Flutter Apps'));
      },
    );

    test('generateTitle cleans <think> tags correctly', () async {
      fakeAdapter.responseToReturn = AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content:
              '<think>User wants to know about LLMs. Let us summarize as "Introduction to LLMs".</think> Introduction to LLMs',
        ),
      );

      final title = await titleService.generateTitle(
        sessionId: 'test-session',
        userMessage: 'What is an LLM?',
        assistantResponse: 'Large Language Model is a deep learning model.',
      );

      expect(title, equals('Introduction to LLMs'));
    });

    test('generateTitle cleans <mm:think> tags correctly', () async {
      fakeAdapter.responseToReturn = AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content:
              '<mm:think>User wants to know about MiniMax. Summary is "MiniMax reasoning".</mm:think> MiniMax reasoning',
        ),
      );

      final title = await titleService.generateTitle(
        sessionId: 'test-session',
        userMessage: 'What is MiniMax?',
        assistantResponse: 'MiniMax is a reasoning model.',
      );

      expect(title, equals('MiniMax reasoning'));
    });

    test(
      'generateTitle falls back to user message snippet if LLM call throws error',
      () async {
        fakeAdapter.errorToThrow = Exception('LLM Timeout');

        final title = await titleService.generateTitle(
          sessionId: 'test-session',
          userMessage:
              'Create a clean architecture local agent framework in Dart.',
          assistantResponse: 'Sure, here is the plan.',
        );

        expect(
          title,
          equals('Create a clean architecture local agent framework in Dart.'),
        );
      },
    );

    test(
      'generateTitle falls back to truncated user message snippet if user message is long',
      () async {
        fakeAdapter.errorToThrow = Exception('LLM Timeout');

        final title = await titleService.generateTitle(
          sessionId: 'test-session',
          userMessage:
              'Create a clean architecture local agent framework in Dart. This should be verified and fully automated.',
          assistantResponse: 'Sure, here is the plan.',
        );

        expect(
          title,
          equals(
            'Create a clean architecture local agent framework in Dart...',
          ),
        );
      },
    );

    test(
      'generateTitle fallback returns default "Chat" for empty user message',
      () async {
        fakeAdapter.errorToThrow = Exception('LLM Timeout');

        final title = await titleService.generateTitle(
          sessionId: 'test-session',
          userMessage: '   ',
          assistantResponse: 'Sure.',
        );

        expect(title, equals('Chat'));
      },
    );

    test(
      'generateTitle uses the session-routed adapter and model when available',
      () async {
        final routedAdapter = FakeLLMAdapter()
          ..responseToReturn = AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'عنوان المحادثة',
            ),
          );

        titleService = TitleService(
          adapter: fakeAdapter,
          sessionRouteResolver: (sessionId, modelOverride) => (
            adapter: routedAdapter,
            modelOverride: 'claude-sonnet-4.5',
            providerInstanceId: 'session-provider-instance',
          ),
        );

        final title = await titleService.generateTitle(
          sessionId: 'session-routed',
          userMessage: 'مرحبا',
          assistantResponse: 'مرحباً! كيف أقدر أساعدك اليوم؟',
          modelOverride: 'gpt-5.5',
        );

        expect(title, equals('عنوان المحادثة'));
        expect(fakeAdapter.lastModelOverride, isNull);
        expect(routedAdapter.lastModelOverride, equals('claude-sonnet-4.5'));
      },
    );

    test(
      'generateTitle prefers the completed-turn adapter provider and model snapshot',
      () async {
        final completedTurnAdapter = FakeLLMAdapter()
          ..responseToReturn = AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Exact Turn Route',
            ),
          );
        var sessionResolverCalled = false;
        titleService = TitleService(
          adapter: fakeAdapter,
          sessionRouteResolver: (sessionId, modelOverride) {
            sessionResolverCalled = true;
            return (
              adapter: fakeAdapter,
              modelOverride: 'wrong-model',
              providerInstanceId: 'wrong-provider-instance',
            );
          },
        );

        final title = await titleService.generateTitle(
          sessionId: 'exact-route-session',
          userMessage: 'Keep the exact route',
          assistantResponse: 'Completed with a failover route.',
          modelOverride: 'stale-turn-model',
          route: LLMRouteSnapshot(
            adapter: completedTurnAdapter,
            providerInstanceId: 'provider-after-failover',
            modelOverride: 'model-after-failover',
          ),
        );

        expect(title, equals('Exact Turn Route'));
        expect(sessionResolverCalled, isFalse);
        expect(fakeAdapter.lastHistory, isNull);
        expect(
          completedTurnAdapter.lastModelOverride,
          equals('model-after-failover'),
        );
        expect(
          completedTurnAdapter.lastOptions?.providerInstanceId,
          equals('provider-after-failover'),
        );
        expect(
          completedTurnAdapter.lastOptions?.sessionId,
          equals('exact-route-session'),
        );
      },
    );

    test(
      'generateTitle sends a bounded first-exchange title request',
      () async {
        fakeAdapter.responseToReturn = AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'Stable Conversation Title',
          ),
        );
        final longUserMessage = List.filled(520, 'u').join();
        final longAssistantResponse = List.filled(520, 'a').join();

        await titleService.generateTitle(
          sessionId: 'bounded-title-session',
          userMessage: longUserMessage,
          assistantResponse: longAssistantResponse,
        );

        final history = fakeAdapter.lastHistory!;
        expect(history.first.content, contains('3-7 words'));
        expect(history.first.content, contains('primary topic or intent'));
        expect(history.first.content, contains('SAME LANGUAGE'));
        expect(
          history.last.content,
          equals(
            'User: ${longUserMessage.substring(0, 500)}\n'
            'Assistant: ${longAssistantResponse.substring(0, 500)}',
          ),
        );
        expect(fakeAdapter.lastOptions?.maxOutputTokens, 500);
        expect(fakeAdapter.lastOptions?.timeout, const Duration(seconds: 30));
      },
    );

    test(
      'retries unsupported output-token parameter without a bound',
      () async {
        fakeAdapter.scriptedOutcomes.addAll([
          const LlmHttpException(
            statusCode: 400,
            body: '{"detail":"Unsupported parameter: max_output_tokens"}',
            headers: {},
            operation: 'generateResponse',
          ),
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Recovered Title',
            ),
          ),
        ]);

        final title = await titleService.generateTitle(
          sessionId: 'unsupported-bound',
          userMessage: 'Repair title generation',
          assistantResponse: 'The title request now adapts.',
        );

        expect(title, 'Recovered Title');
        expect(fakeAdapter.optionsSeen, hasLength(2));
        expect(fakeAdapter.optionsSeen.first.maxOutputTokens, 500);
        expect(fakeAdapter.optionsSeen.last.maxOutputTokens, isNull);

        fakeAdapter.responseToReturn = AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'Cached Capability',
          ),
        );
        await titleService.generateTitle(
          sessionId: 'cached-capability',
          userMessage: 'Reuse provider capability',
          assistantResponse: 'Do not send the rejected option again.',
        );
        expect(fakeAdapter.optionsSeen.last.maxOutputTokens, isNull);
      },
    );

    test('does not retry unrelated HTTP 400 failures', () async {
      fakeAdapter.errorToThrow = const LlmHttpException(
        statusCode: 400,
        body: '{"detail":"Invalid model"}',
        headers: {},
        operation: 'generateResponse',
      );

      final title = await titleService.generateTitle(
        sessionId: 'invalid-model',
        userMessage: 'Use a valid model',
        assistantResponse: 'The configured model is invalid.',
      );

      expect(title, 'Use a valid model');
      expect(fakeAdapter.optionsSeen, hasLength(1));
    });

    test('accepts a non-empty two-character title', () async {
      fakeAdapter.responseToReturn = AgentResponse(
        message: Message(role: MessageRole.assistant, content: 'AI'),
      );

      final title = await titleService.generateTitle(
        sessionId: 'short-title',
        userMessage: 'AI',
        assistantResponse: 'Artificial intelligence.',
      );

      expect(title, 'AI');
    });

    test(
      'enforces timeout even when the adapter ignores request options',
      () async {
        fakeAdapter
          ..responseDelay = const Duration(milliseconds: 40)
          ..responseToReturn = AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Too Late'),
          );
        titleService = TitleService(
          adapter: fakeAdapter,
          requestTimeout: const Duration(milliseconds: 5),
        );

        final title = await titleService.generateTitle(
          sessionId: 'service-timeout',
          userMessage: 'Bound the background call',
          assistantResponse: 'The adapter itself does not apply a timeout.',
        );

        expect(title, 'Bound the background call');
        expect(
          fakeAdapter.lastOptions?.timeout,
          const Duration(milliseconds: 5),
        );
      },
    );

    test('startup recovery finalizes a persisted pending title', () async {
      await getIt.reset();
      SessionManager.resetForTesting();
      final state = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(state);
      final sessions = SessionManager();
      getIt.registerSingleton<SessionManager>(sessions);
      try {
        final now = DateTime.utc(2026, 7, 28);
        sessions.db.saveSession(
          SessionState(
            sessionId: 'recover-title',
            model: 'model-1',
            title: 'Persisted placeholder',
            titleStatus: SessionTitleStatus.pending,
            createdAt: now,
            updatedAt: now,
          ),
        );
        sessions.saveSessionHistory('recover-title', [
          Message(role: MessageRole.user, content: 'Recover my title'),
          Message(role: MessageRole.assistant, content: 'Recovered answer'),
        ]);
        fakeAdapter.responseToReturn = AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'Recovered Session Title',
          ),
        );

        final recovered = await titleService.recoverPendingTitles();

        expect(recovered, 1);
        final session = sessions.getSession('recover-title');
        expect(session?.title, 'Recovered Session Title');
        expect(session?.titleStatus, SessionTitleStatus.finalized);
      } finally {
        SessionManager.resetForTesting();
        state.dispose();
        await getIt.reset();
      }
    });
  });

  group('recovered session title routing', () {
    late AgentStateDatabase state;
    late SessionManager sessions;
    late _RestartedRuntime runtime;

    setUp(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      state = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(state);
      sessions = SessionManager();
      getIt.registerSingleton<SessionManager>(sessions);
      runtime = _RestartedRuntime(
        Config(
          environment: const {},
          modelAwarePolicy: ModelAwareRuntimePolicy.defaults,
        ),
        ProviderInstanceRepository.fromDatabase(state.db),
      );
      getIt.registerSingleton<AgentRuntimeService>(runtime);
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      state.dispose();
      await getIt.reset();
    });

    void saveSession({
      required String sessionId,
      required String model,
      String? providerId,
      String title = 'New Chat',
      SessionTitleStatus titleStatus = SessionTitleStatus.pending,
    }) {
      final now = DateTime.utc(2026, 11, 9);
      sessions.db.saveSession(
        SessionState(
          sessionId: sessionId,
          model: model,
          providerId: providerId,
          title: title,
          titleStatus: titleStatus,
          createdAt: now,
          updatedAt: now,
        ),
      );
      sessions.saveSessionHistory(sessionId, [
        Message(role: MessageRole.user, content: 'Study the daemon restart'),
        Message(role: MessageRole.assistant, content: 'The daemon resumed.'),
      ]);
    }

    test(
      'startup recovery routes the pending title through the session provider',
      () async {
        saveSession(
          sessionId: 'recovered-opencode-go',
          model: 'deepseek-v4.1-flash',
          providerId: '6982859f-48cb-4025-9821-1326b7d332bf',
        );
        final titleService = TitleService();
        runtime.providerAdapters['6982859f-48cb-4025-9821-1326b7d332bf'] =
            FakeLLMAdapter()
              ..responseToReturn = AgentResponse(
                message: Message(
                  role: MessageRole.assistant,
                  content: 'Daemon Restart Study',
                ),
              );
        runtime.defaultRouteAdapter.responseToReturn = AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'Wrong Provider Title',
          ),
        );

        final recovered = await titleService.recoverPendingTitles();

        expect(runtime.defaultAdapterCalls, 0);
        expect(
          runtime.resolvedSignatures,
          [(providerId: '6982859f-48cb-4025-9821-1326b7d332bf', modelId: 'deepseek-v4.1-flash')],
        );
        final routed = runtime
            .providerAdapters['6982859f-48cb-4025-9821-1326b7d332bf']!;
        expect(routed.lastModelOverride, 'deepseek-v4.1-flash');
        expect(
          routed.lastOptions?.providerInstanceId,
          '6982859f-48cb-4025-9821-1326b7d332bf',
        );
        expect(recovered, 1);
        final session = sessions.getSession('recovered-opencode-go');
        expect(session?.title, 'Daemon Restart Study');
        expect(session?.titleStatus, SessionTitleStatus.finalized);
      },
    );

    test(
      'startup recovery skips a pending title when no session route resolves',
      () async {
        saveSession(
          sessionId: 'recovered-without-provider',
          model: 'deepseek-v4.1-flash',
        );
        final titleService = TitleService();

        final recovered = await titleService.recoverPendingTitles();

        expect(runtime.resolvedSignatures, isEmpty);
        expect(runtime.defaultAdapterCalls, 0);
        expect(runtime.defaultRouteAdapter.lastHistory, isNull);
        expect(recovered, 0);
        final session = sessions.getSession('recovered-without-provider');
        expect(session?.title, 'New Chat');
        expect(session?.titleStatus, SessionTitleStatus.pending);
      },
    );

    test('startup recovery never regenerates a finalized title', () async {
      saveSession(
        sessionId: 'already-titled',
        model: 'deepseek-v4.1-flash',
        providerId: '6982859f-48cb-4025-9821-1326b7d332bf',
        title: 'Daemon Restart Study',
        titleStatus: SessionTitleStatus.finalized,
      );
      final titleService = TitleService();

      final recovered = await titleService.recoverPendingTitles();

      expect(recovered, 0);
      expect(runtime.resolvedSignatures, isEmpty);
      expect(runtime.defaultAdapterCalls, 0);
      expect(sessions.getSession('already-titled')?.title, 'Daemon Restart Study');
    });
  });
}
