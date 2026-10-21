import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_history_projection_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/plugins/base_plugin.dart';
import 'package:sanad_agent/plugins/plugin_manager.dart';
import 'package:test/test.dart';

const _testRoute = RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-4o',
  configRevision: 1,
  credentialRevision: 1,
);

class _StreamingTestAdapter implements LLMAdapter {
  final List<AgentResponse> Function() streamChunks;
  final bool shouldThrow;

  _StreamingTestAdapter({
    required this.streamChunks,
    this.shouldThrow = false,
  });

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw UnsupportedError('streaming used in this test');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    for (final chunk in streamChunks()) {
      yield chunk;
    }
    if (shouldThrow) {
      throw StateError('simulated provider stream drop');
    }
  }
}

class _TestRuntimeService extends AgentRuntimeService {
  _TestRuntimeService(super.config, super.repo);

  final Map<String, LLMAdapter> adaptersByProvider = {};
  LLMAdapter? turnAdapter;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    if (providerId == 'provider-2') {
      return const RouteSignature(
        providerInstanceId: 'provider-2',
        templateId: 'anthropic',
        protocol: 'anthropic',
        normalizedBaseUrl: 'https://api.anthropic.com/v1',
        modelId: 'gpt-4o',
        configRevision: 1,
        credentialRevision: 1,
      );
    }
    return _testRoute;
  }

  @override
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) =>
      adaptersByProvider[signature.providerInstanceId] ??
      turnAdapter ??
      super.adapterForTurn(
        signature,
        sessionId: sessionId,
        requestId: requestId,
        runId: runId,
      );
}

class _AutoFailoverStreamingAdapter implements LLMAdapter {
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    throw const LlmHttpException(
      statusCode: 402,
      body: '{"error": {"message": "insufficient funds"}}',
      headers: {},
      operation: 'chat.completions',
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    throw const LlmHttpException(
      statusCode: 402,
      body: '{"error": {"message": "insufficient funds"}}',
      headers: {},
      operation: 'generateStream',
    );
  }
}

class _SuccessStreamingAdapter implements LLMAdapter {
  int callCount = 0;
  final int usageTokens;

  _SuccessStreamingAdapter({this.usageTokens = 2000});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Success reply',
      ),
      usage: {'prompt_tokens': usageTokens, 'completion_tokens': 20},
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    yield AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Success chunk',
      ),
      usage: {'prompt_tokens': usageTokens, 'completion_tokens': 20},
    );
  }
}

class _RateLimitThenSuccessStreamingAdapter implements LLMAdapter {
  int callCount = 0;
  final int usageTokens;

  _RateLimitThenSuccessStreamingAdapter({this.usageTokens = 1800});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    if (callCount == 1) {
      throw LlmHttpException(
        statusCode: 429,
        body: '{"error": "rate limit"}',
        headers: const {'retry-after-ms': '1'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Recovered after rate limit',
      ),
      usage: {'prompt_tokens': usageTokens, 'completion_tokens': 25},
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    if (callCount == 1) {
      throw LlmHttpException(
        statusCode: 429,
        body: '{"error": "rate limit"}',
        headers: const {'retry-after-ms': '1'},
        operation: 'generateStream',
      );
    }
    yield AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Recovered streaming chunk',
      ),
      usage: {'prompt_tokens': usageTokens, 'completion_tokens': 25},
    );
  }
}

class _ThrowingPreExecutionPlugin extends BasePlugin {
  int callCount = 0;
  final int throwOnCall;

  _ThrowingPreExecutionPlugin({this.throwOnCall = 2});

  @override
  String get name => 'ThrowingPreExecutionPlugin';

  @override
  String get description => 'Simulates exception in _prepareProviderHistory';

  @override
  Future<List<Message>> preExecution(List<Message> history) async {
    callCount++;
    if (callCount >= throwOnCall) {
      throw StateError(
        'Simulated projection / preExecution throw in _prepareProviderHistory',
      );
    }
    return history;
  }
}

class _StopOnChunkStreamingAdapter implements LLMAdapter {
  final void Function() onChunk;

  _StopOnChunkStreamingAdapter({required this.onChunk});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw UnsupportedError('streaming used in this test');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'Chunk 1'),
    );
    onChunk();
    yield AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'Chunk 2'),
    );
  }
}

class _RateLimitThenStopAdapter implements LLMAdapter {
  int callCount = 0;
  final void Function() onFirstAttempt;

  _RateLimitThenStopAdapter({required this.onFirstAttempt});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    if (callCount == 1) {
      onFirstAttempt();
      throw const LlmHttpException(
        statusCode: 429,
        body: '{"error": {"message": "rate limit"}}',
        headers: {'retry-after-ms': '1'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'Retry succeeded'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    if (callCount == 1) {
      onFirstAttempt();
      throw const LlmHttpException(
        statusCode: 429,
        body: '{"error": {"message": "rate limit"}}',
        headers: {'retry-after-ms': '1'},
        operation: 'generateStream',
      );
    }
    yield AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'Retry succeeded'),
    );
  }
}

class _CancellableStreamingAdapter implements LLMAdapter {
  final Stream<AgentResponse> Function() streamFactory;
  final Future<AgentResponse> Function()? responseFactory;

  _CancellableStreamingAdapter({
    required this.streamFactory,
    this.responseFactory,
  });

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final factory = responseFactory;
    if (factory == null) {
      throw UnsupportedError('streaming used in this test');
    }
    return factory();
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) {
    return streamFactory();
  }
}

class _HistoryProjectionRejectingAdapter implements LLMAdapter {
  int callCount = 0;

  ProviderHistoryProjectionException _rejection() =>
      ProviderHistoryProjectionException(
        route: 'provider-1/gpt-4o',
        reasonCode: ProviderHistoryProjectionException.unpairedToolCall,
        affectedCount: 1,
      );

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 100_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    throw _rejection();
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    throw _rejection();
  }
}

List<IndexedConversationMessage> _timeline() {
  return [
    IndexedConversationMessage(
      rowId: 1,
      message: Message(
        role: MessageRole.user,
        content: 'goal: test streaming post-boundary usage reconciliation',
      ),
    ),
    for (var i = 2; i <= 25; i++)
      IndexedConversationMessage(
        rowId: i,
        message: Message(
          role: MessageRole.user,
          content: 'filler message $i ${'y' * 150}',
        ),
      ),
  ];
}

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionDB sessions;
  late SessionHistoryRevisionRepository historyRevisions;
  late SessionProjectionRevisionRepository projectionRevisions;
  late CompactionBoundaryRepository boundaries;
  late CompactionActivationService activation;
  late ModelProjectionBuilder projectionBuilder;
  late CompactionCoordinator coordinator;
  late ToolsRegistry registry;
  late SessionManager sessionManager;
  late _TestRuntimeService runtimeService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad_stream_test_');
    Directory('${tempDir.path}${Platform.pathSeparator}memories')
        .createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);

    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);

    SessionManager.resetForTesting();
    sessionManager = SessionManager();
    sessions = sessionManager.db;
    getIt.registerSingleton<SessionDB>(sessions);

    historyRevisions = SessionHistoryRevisionRepository(state);
    getIt.registerSingleton<SessionHistoryRevisionRepository>(historyRevisions);

    projectionRevisions = SessionProjectionRevisionRepository(state);
    getIt.registerSingleton<SessionProjectionRevisionRepository>(
      projectionRevisions,
    );

    boundaries = CompactionBoundaryRepository(state, historyRevisions);
    getIt.registerSingleton<CompactionBoundaryRepository>(boundaries);

    activation = CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: projectionRevisions,
    );

    projectionBuilder = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    );
    getIt.registerSingleton<ModelProjectionBuilder>(projectionBuilder);

    final engine = ContextCompactionEngine(
      summarizer: StructuredCompactionSummarizer(),
    );
    getIt.registerSingleton<ContextCompactionEngine>(engine);

    coordinator = CompactionCoordinator(
      engine: engine,
      boundaries: boundaries,
      activation: activation,
      projectionBuilder: projectionBuilder,
    );
    getIt.registerSingleton<CompactionCoordinator>(coordinator);

    final providerRepo = ProviderInstanceRepository.fromDatabase(state.db);
    getIt.registerSingleton<ProviderInstanceRepository>(providerRepo);

    final nowTime = DateTime.utc(2026, 8, 29);
    providerRepo.createInstance(
      ProviderInstance(
        id: 'provider-1',
        templateId: 'openai',
        displayName: 'Provider 1',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o',
        status: InstanceStatus.ready,
        createdAt: nowTime,
        updatedAt: nowTime,
      ),
    );
    providerRepo.createInstance(
      ProviderInstance(
        id: 'provider-2',
        templateId: 'anthropic',
        displayName: 'Provider 2',
        protocol: ProviderProtocol.anthropicCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o',
        status: InstanceStatus.ready,
        createdAt: nowTime,
        updatedAt: nowTime,
      ),
    );

    final rateLimiter = ProviderRateLimiter();
    getIt.registerSingleton<ProviderRateLimiter>(rateLimiter);

    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(
        providerRepo,
        rateLimiter,
        autoFailoverEnabled: true,
      ),
    );

    getIt.registerSingleton<Config>(Config());

    runtimeService = _TestRuntimeService(Config(), providerRepo);
    getIt.registerSingleton<AgentRuntimeService>(runtimeService);

    registry = ToolsRegistry();

    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-stream',
        providerId: 'provider-1',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages(
      'session-stream',
      _timeline().map((entry) => entry.message).toList(),
    );
  });

  tearDown(() {
    getIt.reset();
    SessionManager.resetForTesting();
    sessions.dispose();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<CompactionOutcome> prepareActiveCompactionBoundary() async {
    final canonical = projectionBuilder.loadCanonicalTimeline('session-stream');
    final revision = historyRevisions.read('session-stream')!;
    final outcome = await coordinator.runCompaction(
      request: CompactionEngineRequest(
        compactionId: 'cmp-stream-test',
        sessionId: 'session-stream',
        trigger: CompactionTrigger.manual,
        sourceRevision: revision.toCompactionRevision(),
        routeSignature: _testRoute,
        contextWindowTokens: 50000,
        // Above the complete-request target (Task 118 small-session no-op).
        targetRequestTokens: 100,
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        systemPrompt: 'system prompt',
        runtimeContext: 'runtime context',
        toolSchemas: const [],
      ),
      force: true,
    );
    expect(outcome, isNotNull);
    final projection = projectionBuilder.buildForSession('session-stream');
    expect(projection.activeBoundary, isNotNull);
    return outcome!;
  }

  test(
    'streaming OpenAI-compatible trailing usage reconciles successfully after finish chunk with null usage',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      // Simulate OpenAI streaming response:
      // Chunk 1: content only, usage null
      // Chunk 2: content only, finish_reason 'stop', usage null
      // Chunk 3: empty content, usage object with prompt_tokens
      final adapter = _StreamingTestAdapter(
        streamChunks: () => [
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Hello, here is the answer.',
            ),
            finishReason: LLMFinishReason.unknown,
            usage: null,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: ''),
            finishReason: LLMFinishReason.stop,
            usage: null,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: ''),
            finishReason: LLMFinishReason.unknown,
            usage: const {'prompt_tokens': 1420, 'completion_tokens': 18},
          ),
        ],
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );
      await runner.streamMessage(
        'What is next?',
        requestId: 'turn-req-trailing',
        providerId: 'provider-1',
        model: 'gpt-4o',
      ).drain();

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, 1420);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'confirmed');
      expect(postStatus.inputTokens, 1420);
      // Task 118: the first confirmed post-input is judged against the
      // complete-request target over W (the fixture's small target).
      expect(postStatus.targetOutcome, TargetOutcome.notMet);
      expect(postStatus.requestId, startsWith('turn-req-trailing:'));
    },
  );

  test(
    'streaming absent usage finalizes as missing only at stream completion, not on intermediate chunks',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      // Simulate stream with NO usage emitted anywhere
      final adapter = _StreamingTestAdapter(
        streamChunks: () => [
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Partial chunk 1',
            ),
            finishReason: LLMFinishReason.unknown,
            usage: null,
          ),
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Final chunk 2',
            ),
            finishReason: LLMFinishReason.stop,
            usage: null,
          ),
        ],
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner.streamMessage(
        'What is next without usage?',
        requestId: 'turn-req-absent',
        providerId: 'provider-1',
        model: 'gpt-4o',
      ).drain();

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
      expect(postStatus.targetOutcome, TargetOutcome.unknown);
      expect(postStatus.requestId, startsWith('turn-req-absent:'));
    },
  );

  test(
    'streaming failure before usage finalizes as missing upon exception',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      final adapter = _StreamingTestAdapter(
        streamChunks: () => [
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Chunk before drop'),
            finishReason: LLMFinishReason.unknown,
            usage: null,
          ),
        ],
        shouldThrow: true,
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await expectLater(
        runner.streamMessage(
          'What is next with failure?',
          requestId: 'turn-req-failure',
          providerId: 'provider-1',
          model: 'gpt-4o',
        ).drain(),
        throwsA(anything),
      );

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
      expect(postStatus.requestId, startsWith('turn-req-failure:'));
    },
  );

  test(
    'handled auto-failover from provider-1 to provider-2 finalizes abandoned route reservation as missing with route_failover (streaming)',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      final failoverAdapter = _AutoFailoverStreamingAdapter();
      final successAdapter = _SuccessStreamingAdapter(usageTokens: 2500);
      runtimeService.adaptersByProvider['provider-1'] = failoverAdapter;
      runtimeService.adaptersByProvider['provider-2'] = successAdapter;

      final runner = AgentRunner(
        failoverAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner.streamMessage(
        'Trigger failover during stream',
        requestId: 'turn-failover-stream',
        providerId: 'provider-1',
        model: 'gpt-4o',
      ).drain();

      expect(failoverAdapter.callCount, 1);
      expect(successAdapter.callCount, 1);

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      // Provider 2's usage must NOT be fabricated into Provider 1's boundary
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'route_failover');
      expect(postStatus.targetOutcome, TargetOutcome.unknown);
    },
  );

  test(
    'handled auto-failover from provider-1 to provider-2 finalizes abandoned route reservation as missing with route_failover (non-streaming)',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      final failoverAdapter = _AutoFailoverStreamingAdapter();
      final successAdapter = _SuccessStreamingAdapter(usageTokens: 2500);
      runtimeService.adaptersByProvider['provider-1'] = failoverAdapter;
      runtimeService.adaptersByProvider['provider-2'] = successAdapter;

      final runner = AgentRunner(
        failoverAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      final response = await runner.sendMessage(
        'Trigger failover non-streaming',
        requestId: 'turn-failover-sync',
        providerId: 'provider-1',
        model: 'gpt-4o',
      );

      expect(response.content, 'Success reply');
      expect(failoverAdapter.callCount, 1);
      expect(successAdapter.callCount, 1);

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'route_failover');
      expect(postStatus.targetOutcome, TargetOutcome.unknown);
    },
  );

  test(
    'same-route retry under 429 keeps reservation and reconciles on retry success (streaming)',
    () async {
      // In same-route retry, no alternate failover candidate is available for the model
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();

      final retryAdapter = _RateLimitThenSuccessStreamingAdapter(usageTokens: 1800);
      runtimeService.adaptersByProvider['provider-1'] = retryAdapter;

      final runner = AgentRunner(
        retryAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner.streamMessage(
        'Trigger retry streaming',
        requestId: 'turn-retry-stream',
        providerId: 'provider-1',
        model: 'gpt-4o',
      ).drain();

      expect(retryAdapter.callCount, 2);

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, 1800);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'confirmed');
      expect(postStatus.inputTokens, 1800);
    },
  );

  test(
    'same-route retry under 429 keeps reservation and reconciles on retry success (non-streaming)',
    () async {
      // In same-route retry, no alternate failover candidate is available for the model
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();

      final retryAdapter = _RateLimitThenSuccessStreamingAdapter(usageTokens: 1800);
      runtimeService.adaptersByProvider['provider-1'] = retryAdapter;

      final runner = AgentRunner(
        retryAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      final response = await runner.sendMessage(
        'Trigger retry non-streaming',
        requestId: 'turn-retry-sync',
        providerId: 'provider-1',
        model: 'gpt-4o',
      );

      expect(response.content, 'Recovered after rate limit');
      expect(retryAdapter.callCount, 2);

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, 1800);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'confirmed');
      expect(postStatus.inputTokens, 1800);
    },
  );

  test(
    'throw in history prep after handled auto-failover leaves reservation finalized as route_failover (non-streaming)',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      final failoverAdapter = _AutoFailoverStreamingAdapter();
      final successAdapter = _SuccessStreamingAdapter(usageTokens: 2500);
      runtimeService.adaptersByProvider['provider-1'] = failoverAdapter;
      runtimeService.adaptersByProvider['provider-2'] = successAdapter;

      final pluginManager = PluginManager();
      pluginManager.registerPlugin(_ThrowingPreExecutionPlugin(throwOnCall: 2));

      final runner = AgentRunner(
        failoverAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
        pluginManager: pluginManager,
      );

      await expectLater(
        runner.sendMessage(
          'Trigger failover with history prep throw',
          requestId: 'turn-failover-prep-sync',
          providerId: 'provider-1',
          model: 'gpt-4o',
        ),
        throwsA(isA<StateError>()),
      );

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'route_failover');
      expect(postStatus.targetOutcome, TargetOutcome.unknown);
    },
  );

  test(
    'throw in history prep after handled auto-failover leaves reservation finalized as route_failover (streaming)',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      final failoverAdapter = _AutoFailoverStreamingAdapter();
      final successAdapter = _SuccessStreamingAdapter(usageTokens: 2500);
      runtimeService.adaptersByProvider['provider-1'] = failoverAdapter;
      runtimeService.adaptersByProvider['provider-2'] = successAdapter;

      final pluginManager = PluginManager();
      pluginManager.registerPlugin(_ThrowingPreExecutionPlugin(throwOnCall: 2));

      final runner = AgentRunner(
        failoverAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
        pluginManager: pluginManager,
      );

      await expectLater(
        runner.streamMessage(
          'Trigger failover with history prep throw streaming',
          requestId: 'turn-failover-prep-stream',
          providerId: 'provider-1',
          model: 'gpt-4o',
        ).drain(),
        throwsA(isA<StateError>()),
      );

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'route_failover');
      expect(postStatus.targetOutcome, TargetOutcome.unknown);
    },
  );

  test(
    'throw in history prep after same-route retry leaves reservation finalized as no_provider_usage (non-streaming)',
    () async {
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();

      final retryAdapter = _RateLimitThenSuccessStreamingAdapter(usageTokens: 1800);
      runtimeService.adaptersByProvider['provider-1'] = retryAdapter;

      final pluginManager = PluginManager();
      pluginManager.registerPlugin(_ThrowingPreExecutionPlugin(throwOnCall: 2));

      final runner = AgentRunner(
        retryAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
        pluginManager: pluginManager,
      );

      await expectLater(
        runner.sendMessage(
          'Trigger retry with history prep throw non-streaming',
          requestId: 'turn-retry-prep-sync',
          providerId: 'provider-1',
          model: 'gpt-4o',
        ),
        throwsA(isA<StateError>()),
      );

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
    },
  );

  test(
    'throw in history prep after same-route retry leaves reservation finalized as no_provider_usage (streaming)',
    () async {
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();

      final retryAdapter = _RateLimitThenSuccessStreamingAdapter(usageTokens: 1800);
      runtimeService.adaptersByProvider['provider-1'] = retryAdapter;

      final pluginManager = PluginManager();
      pluginManager.registerPlugin(_ThrowingPreExecutionPlugin(throwOnCall: 2));

      final runner = AgentRunner(
        retryAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
        pluginManager: pluginManager,
      );

      await expectLater(
        runner.streamMessage(
          'Trigger retry with history prep throw streaming',
          requestId: 'turn-retry-prep-stream',
          providerId: 'provider-1',
          model: 'gpt-4o',
        ).drain(),
        throwsA(isA<StateError>()),
      );

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
    },
  );

  test(
    'streaming stopRequested during stream finalizes reservation as missing with no_provider_usage',
    () async {
      final outcome = await prepareActiveCompactionBoundary();

      late final AgentRunner runner;
      final adapter = _StopOnChunkStreamingAdapter(onChunk: () {
        runner.requestStop();
      });
      runtimeService.turnAdapter = adapter;

      runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner.streamMessage(
        'Stop during stream',
        requestId: 'turn-stop-stream',
        providerId: 'provider-1',
        model: 'gpt-4o',
      ).drain();

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
    },
  );

  test(
    'non-streaming stop before retry dispatch finalizes earlier attempt reservation as no_provider_usage',
    () async {
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();

      late final AgentRunner runner;
      final retryAdapter = _RateLimitThenStopAdapter(onFirstAttempt: () {
        runner.requestStop();
      });
      runtimeService.adaptersByProvider['provider-1'] = retryAdapter;

      runner = AgentRunner(
        retryAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      final response = await runner.sendMessage(
        'Trigger retry then stop non-streaming',
        requestId: 'turn-retry-stop-sync',
        providerId: 'provider-1',
        model: 'gpt-4o',
      );

      expect(retryAdapter.callCount, 1);
      expect(response.content, isNull);

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
    },
  );

  test(
    'streaming stop before retry dispatch finalizes earlier attempt reservation as no_provider_usage',
    () async {
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();

      late final AgentRunner runner;
      final retryAdapter = _RateLimitThenStopAdapter(onFirstAttempt: () {
        runner.requestStop();
      });
      runtimeService.adaptersByProvider['provider-1'] = retryAdapter;

      runner = AgentRunner(
        retryAdapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner.streamMessage(
        'Trigger retry then stop streaming',
        requestId: 'turn-retry-stop-stream',
        providerId: 'provider-1',
        model: 'gpt-4o',
      ).drain();

      expect(retryAdapter.callCount, 1);

      final record = boundaries.findById(outcome.compactionId);
      expect(record, isNotNull);
      expect(record!.metrics?.providerConfirmedRequestTokensAfter, isNull);

      final postStatus = record.diagnostics?.postBoundary;
      expect(postStatus, isNotNull);
      expect(postStatus!.status, 'missing');
      expect(postStatus.missingReason, 'no_provider_usage');
    },
  );

  StreamController<AgentResponse> openProviderStream({
    Map<String, dynamic>? usage,
    String content = 'Partial streaming answer',
  }) {
    final controller = StreamController<AgentResponse>();
    controller.add(
      AgentResponse(
        message: Message(role: MessageRole.assistant, content: content),
        usage: usage,
      ),
    );
    return controller;
  }

  Future<void> cancelBounded(StreamSubscription<String> subscription) async {
    try {
      await subscription.cancel().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // bounded cancel
    }
  }

  test(
    'executor-style subscription cancel after stop must finalize reservation as missing with no_provider_usage',
    () async {
      final outcome = await prepareActiveCompactionBoundary();
      final controller = openProviderStream();
      final adapter = _CancellableStreamingAdapter(
        streamFactory: () => controller.stream,
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      final firstChunk = Completer<void>();
      final subscription = runner
          .streamMessage(
            'Probe cancel during stream',
            requestId: 'turn-probe-cancel',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .listen(
            (chunk) {
              if (!firstChunk.isCompleted) firstChunk.complete();
            },
            onError: (Object error, StackTrace stack) {},
          );

      await firstChunk.future;
      runner.requestStop();
      await cancelBounded(subscription);
      await pumpEventQueue();

      final record = boundaries.findById(outcome.compactionId);
      final post = record?.diagnostics?.postBoundary;
      expect(post?.status, 'missing');
      expect(post?.missingReason, 'no_provider_usage');
    },
  );

  test(
    'consumer subscription cancel without stop flag must finalize reservation as missing with no_provider_usage',
    () async {
      final outcome = await prepareActiveCompactionBoundary();
      final controller = openProviderStream(content: 'Disconnect answer');
      final adapter = _CancellableStreamingAdapter(
        streamFactory: () => controller.stream,
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      final firstChunk = Completer<void>();
      final subscription = runner
          .streamMessage(
            'Probe disconnect during stream',
            requestId: 'turn-probe-disconnect',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .listen(
            (chunk) {
              if (!firstChunk.isCompleted) firstChunk.complete();
            },
            onError: (Object error, StackTrace stack) {},
          );

      await firstChunk.future;
      await cancelBounded(subscription);
      await pumpEventQueue();

      final record = boundaries.findById(outcome.compactionId);
      final post = record?.diagnostics?.postBoundary;
      expect(post?.status, 'missing');
      expect(post?.missingReason, 'no_provider_usage');
    },
  );

  test(
    'same-route streaming retry that activates a newer boundary finalizes abandoned boundary as missing with no_provider_usage',
    () async {
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();
      var secondBoundaryActivated = false;

      Future<void> activateSecondBoundary() async {
        if (secondBoundaryActivated) return;
        secondBoundaryActivated = true;
        final canonical = projectionBuilder.loadCanonicalTimeline(
          'session-stream',
        );
        final revision = historyRevisions.read('session-stream')!;
        await coordinator.runCompaction(
          request: CompactionEngineRequest(
            compactionId: 'cmp-stream-test-second',
            sessionId: 'session-stream',
            trigger: CompactionTrigger.manual,
            sourceRevision: revision.toCompactionRevision(),
            routeSignature: _testRoute,
            contextWindowTokens: 50000,
            // Above the complete-request target (Task 118 small-session no-op).
            targetRequestTokens: 100,
            timeline: [
              for (final entry in canonical.messages)
                IndexedConversationMessage(
                  rowId: entry.rowId,
                  message: entry.message,
                ),
            ],
            systemPrompt: 'system prompt',
            runtimeContext: 'runtime context',
            toolSchemas: const [],
          ),
          force: true,
        );
      }

      var callCount = 0;
      final adapter = _CancellableStreamingAdapter(
        streamFactory: () async* {
          callCount++;
          if (callCount == 1) {
            await activateSecondBoundary();
            throw const LlmHttpException(
              statusCode: 429,
              body: '{"error": "rate limit"}',
              headers: {'retry-after-ms': '1'},
              operation: 'generateStream',
            );
          }
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Retry succeeded on same route',
            ),
            usage: {'prompt_tokens': 1725, 'completion_tokens': 9},
          );
        },
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner
          .streamMessage(
            'Test retry with newer boundary',
            requestId: 'turn-test-retry-boundary',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .drain();

      final first = boundaries.findById(outcome.compactionId);
      final second = boundaries.findById('cmp-stream-test-second');

      final postFirst = first?.diagnostics?.postBoundary;
      expect(postFirst?.status, isNot('reserved'));
      expect(postFirst?.status, 'missing');
      expect(postFirst?.missingReason, 'no_provider_usage');

      final postSecond = second?.diagnostics?.postBoundary;
      expect(postSecond?.status, 'confirmed');
      expect(second?.metrics?.providerConfirmedRequestTokensAfter, 1725);
    },
  );

  test(
    'same-route non-streaming retry that activates a newer boundary finalizes abandoned boundary as missing with no_provider_usage',
    () async {
      getIt<ProviderInstanceRepository>().delete('provider-2');
      final outcome = await prepareActiveCompactionBoundary();
      var secondBoundaryActivated = false;

      Future<void> activateSecondBoundary() async {
        if (secondBoundaryActivated) return;
        secondBoundaryActivated = true;
        final canonical = projectionBuilder.loadCanonicalTimeline(
          'session-stream',
        );
        final revision = historyRevisions.read('session-stream')!;
        await coordinator.runCompaction(
          request: CompactionEngineRequest(
            compactionId: 'cmp-sync-test-second',
            sessionId: 'session-stream',
            trigger: CompactionTrigger.manual,
            sourceRevision: revision.toCompactionRevision(),
            routeSignature: _testRoute,
            contextWindowTokens: 50000,
            // Above the complete-request target (Task 118 small-session no-op).
            targetRequestTokens: 100,
            timeline: [
              for (final entry in canonical.messages)
                IndexedConversationMessage(
                  rowId: entry.rowId,
                  message: entry.message,
                ),
            ],
            systemPrompt: 'system prompt',
            runtimeContext: 'runtime context',
            toolSchemas: const [],
          ),
          force: true,
        );
      }

      var callCount = 0;
      final adapter = _CancellableStreamingAdapter(
        streamFactory: () => const Stream<AgentResponse>.empty(),
        responseFactory: () async {
          callCount++;
          if (callCount == 1) {
            await activateSecondBoundary();
            throw const LlmHttpException(
              statusCode: 429,
              body: '{"error": "rate limit"}',
              headers: {'retry-after-ms': '1'},
              operation: 'chat.completions',
            );
          }
          return AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Sync retry succeeded',
            ),
            usage: {'prompt_tokens': 1844, 'completion_tokens': 6},
          );
        },
      );
      runtimeService.turnAdapter = adapter;

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      await runner.sendMessage(
        'Test sync retry with newer boundary',
        requestId: 'turn-test-sync-retry-boundary',
        providerId: 'provider-1',
        model: 'gpt-4o',
      );

      final first = boundaries.findById(outcome.compactionId);
      final second = boundaries.findById('cmp-sync-test-second');

      final postFirst = first?.diagnostics?.postBoundary;
      expect(postFirst?.status, isNot('reserved'));
      expect(postFirst?.status, 'missing');
      expect(postFirst?.missingReason, 'no_provider_usage');

      final postSecond = second?.diagnostics?.postBoundary;
      expect(postSecond?.status, 'confirmed');
      expect(second?.metrics?.providerConfirmedRequestTokensAfter, 1844);
    },
  );

  test(
    'concurrent streams on same runner isolate reservations: cancelling older stream does not finalize newer stream reservation',
    () async {
      final firstOutcome = await prepareActiveCompactionBoundary();
      var streamCall = 0;
      late StreamController<AgentResponse> streamAController;
      late StreamController<AgentResponse> streamBController;
      final adapter = _CancellableStreamingAdapter(
        streamFactory: () {
          streamCall++;
          if (streamCall == 1) {
            streamAController = openProviderStream(content: 'R5 stream A');
            return streamAController.stream;
          }
          streamBController = openProviderStream(content: 'R5 stream B');
          return streamBController.stream;
        },
      );
      runtimeService.turnAdapter = adapter;
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      final firstChunk = Completer<void>();
      final subA = runner
          .streamMessage(
            'R5 turn A',
            requestId: 'turn-r5-a',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .listen(
            (chunk) {
              if (!firstChunk.isCompleted) firstChunk.complete();
            },
            onError: (Object e, StackTrace s) {},
          );
      await firstChunk.future;

      final canonical = projectionBuilder.loadCanonicalTimeline('session-stream');
      final revision = historyRevisions.read('session-stream')!;
      await coordinator.runCompaction(
        request: CompactionEngineRequest(
          compactionId: 'cmp-r5-second-product',
          sessionId: 'session-stream',
          trigger: CompactionTrigger.manual,
          sourceRevision: revision.toCompactionRevision(),
          routeSignature: _testRoute,
          contextWindowTokens: 50000,
          // Above the complete-request target (Task 118 small-session no-op).
          targetRequestTokens: 100,
          timeline: [
            for (final entry in canonical.messages)
              IndexedConversationMessage(
                rowId: entry.rowId,
                message: entry.message,
              ),
          ],
          systemPrompt: 'system prompt',
          runtimeContext: 'runtime context',
          toolSchemas: const [],
        ),
        force: true,
      );

      final secondChunk = Completer<void>();
      final subB = runner
          .streamMessage(
            'R5 turn B',
            requestId: 'turn-r5-b',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .listen(
            (chunk) {
              if (!secondChunk.isCompleted) secondChunk.complete();
            },
            onError: (Object e, StackTrace s) {},
          );
      await secondChunk.future.timeout(const Duration(seconds: 10));

      final beforeCancel = boundaries.findById('cmp-r5-second-product');
      final postBefore = beforeCancel?.diagnostics?.postBoundary;
      expect(postBefore?.status, 'reserved');

      await cancelBounded(subA);
      await pumpEventQueue();

      final afterCancel = boundaries.findById('cmp-r5-second-product');
      final postAfter = afterCancel?.diagnostics?.postBoundary;
      expect(
        postAfter?.status,
        'reserved',
        reason: 'cancelling stream A must not finalize stream B reservation',
      );

      streamBController.add(
        AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'R5 stream B usage chunk',
          ),
          usage: {'prompt_tokens': 1777, 'completion_tokens': 4},
        ),
      );
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final afterBUsage = boundaries.findById('cmp-r5-second-product');
      final postBUsage = afterBUsage?.diagnostics?.postBoundary;
      expect(postBUsage?.status, 'confirmed');
      expect(afterBUsage?.metrics?.providerConfirmedRequestTokensAfter, 1777);

      await streamAController.close();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final firstBoundaryRecord = boundaries.findById(firstOutcome.compactionId);
      final postFirst = firstBoundaryRecord?.diagnostics?.postBoundary;
      expect(postFirst?.status, 'missing');
      expect(postFirst?.missingReason, 'no_provider_usage');

      await cancelBounded(subB);
    },
  );

  test(
    'stream pause delivers no chunks while paused and delivers buffered chunks on resume',
    () async {
      await prepareActiveCompactionBoundary();
      final controller = StreamController<AgentResponse>();
      final adapter = _CancellableStreamingAdapter(
        streamFactory: () => controller.stream,
      );
      runtimeService.turnAdapter = adapter;
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );

      var delivered = 0;
      final firstChunk = Completer<void>();
      final deliveredChunks = <String>[];
      final sub = runner
          .streamMessage(
            'R3 pause verification',
            requestId: 'turn-r3-test',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .listen(
            (chunk) {
              delivered++;
              deliveredChunks.add(chunk);
              if (!firstChunk.isCompleted) firstChunk.complete();
            },
            onError: (Object e, StackTrace s) {},
          );

      controller.add(
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'chunk-1'),
        ),
      );
      await firstChunk.future;
      expect(delivered, 1);

      sub.pause();
      final deliveredAtPause = delivered;

      controller.add(
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'chunk-2'),
        ),
      );
      controller.add(
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'chunk-3'),
        ),
      );
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(delivered, deliveredAtPause);

      sub.resume();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(delivered, 3);
      expect(deliveredChunks, ['chunk-1', 'chunk-2', 'chunk-3']);

      final done = Completer<void>();
      sub.onDone(done.complete);
      await controller.close();
      await done.future.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
    },
  );

  // Task 110 port guard: a stream whose first chunks carry no usage and whose
  // last chunk carries provider usage must still confirm the staged input
  // baseline (the SRP orchestrator once cleared the pending baseline on every
  // chunk, so a usage-less first chunk lost the confirmation).
  test(
    'stream with usage only in the last chunk confirms the input baseline',
    () async {
      final adapter = _StreamingTestAdapter(
        streamChunks: () => [
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'part 1'),
            finishReason: LLMFinishReason.unknown,
            usage: null,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'part 2'),
            finishReason: LLMFinishReason.stop,
            usage: null,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: ''),
            finishReason: LLMFinishReason.unknown,
            usage: const {'prompt_tokens': 1234, 'completion_tokens': 9},
          ),
        ],
      );
      runtimeService.turnAdapter = adapter;
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: 'session-stream',
      );
      expect(runner.debugConfirmedInputUsageBaseline, isNull);

      await runner
          .streamMessage(
            'usage arrives last',
            requestId: 'turn-usage-last',
            providerId: 'provider-1',
            model: 'gpt-4o',
          )
          .drain<void>();

      final confirmed = runner.debugConfirmedInputUsageBaseline;
      expect(confirmed, isNotNull);
      expect(confirmed!.inputTokens, 1234);
      expect(confirmed.routeSignature.providerInstanceId, 'provider-1');
    },
  );

  // Task 110 port guard (Task 116): a provider-history projection rejection
  // is a blocked local invalid request; it never fails over to a ready
  // candidate and never retries on either the stream or non-stream path.
  for (final streaming in [true, false]) {
    test(
      'history projection rejection neither fails over nor retries '
      '(${streaming ? 'stream' : 'non-stream'})',
      () async {
        final primary = _HistoryProjectionRejectingAdapter();
        final candidate = _SuccessStreamingAdapter();
        runtimeService.adaptersByProvider['provider-1'] = primary;
        runtimeService.adaptersByProvider['provider-2'] = candidate;
        final runner = AgentRunner(
          primary,
          registry,
          sessionManager,
          existingSessionId: 'session-stream',
        );

        final matcher = throwsA(
          isA<RuntimeRecoveryRequired>().having(
            (error) => error.reason,
            'reason',
            RuntimeFailureReason.invalidRequest,
          ),
        );
        if (streaming) {
          await expectLater(
            runner
                .streamMessage(
                  'project me',
                  requestId: 'turn-projection-reject',
                  providerId: 'provider-1',
                  model: 'gpt-4o',
                )
                .toList(),
            matcher,
          );
        } else {
          await expectLater(
            runner.sendMessage(
              'project me',
              requestId: 'turn-projection-reject',
              providerId: 'provider-1',
              model: 'gpt-4o',
            ),
            matcher,
          );
        }

        expect(primary.callCount, 1, reason: 'no retry');
        expect(candidate.callCount, 0, reason: 'no failover');
        expect(runner.activeProvider, 'provider-1');
        final notice = getIt<RuntimeRecoveryService>().activeNotice(
          'session-stream',
        );
        expect(notice, isNotNull);
        expect(notice!.title, 'Conversation history not supported by this model');
      },
    );
  }
}
