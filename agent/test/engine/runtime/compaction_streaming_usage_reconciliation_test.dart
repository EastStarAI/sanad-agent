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
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
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

  LLMAdapter? turnAdapter;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) =>
      _testRoute;

  @override
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) =>
      turnAdapter ?? super.adapterForTurn(
        signature,
        sessionId: sessionId,
        requestId: requestId,
        runId: runId,
      );
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

    final rateLimiter = ProviderRateLimiter();
    getIt.registerSingleton<ProviderRateLimiter>(rateLimiter);

    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(providerRepo, rateLimiter),
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
        targetRequestTokens: 10000,
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
      expect(postStatus.targetOutcome, TargetOutcome.unknown);
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
}
