import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
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
import 'package:sanad_agent/evolution/compaction/compaction_summary_projection.dart';
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

class _PreflightAdapter implements LLMAdapter {
  @override
  Future<int> getContextLimit([String? modelOverride]) async => 3_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw UnsupportedError('not used');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    throw UnsupportedError('not used');
  }
}

class _FakeRuntimeService extends AgentRuntimeService {
  _FakeRuntimeService(super.config, super.repo);

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return const RouteSignature(
      providerInstanceId: 'provider-1',
      templateId: 'openai',
      protocol: 'openai_compatible',
      normalizedBaseUrl: 'https://api.example.com/v1',
      modelId: 'gpt-4o',
      configRevision: 1,
      credentialRevision: 1,
    );
  }
}

void main() {
  late AgentStateDatabase state;
  late SessionManager sessionManager;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late CompactionCoordinator coordinator;
  late AgentRunner runner;

  setUp(() {
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    SessionManager.resetForTesting();
    sessionManager = SessionManager();
    sessions = sessionManager.db;
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    final activation = CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: SessionProjectionRevisionRepository(state),
    );
    coordinator = CompactionCoordinator(
      engine: ContextCompactionEngine(
        summarizer: StructuredCompactionSummarizer(),
      ),
      boundaries: boundaries,
      activation: activation,
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
    );
    getIt.registerSingleton<CompactionCoordinator>(coordinator);
    getIt.registerSingleton<ModelProjectionBuilder>(
      ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
    );
    getIt.registerSingleton<SessionHistoryRevisionRepository>(
      SessionHistoryRevisionRepository(state),
    );
    getIt.registerSingleton<ContextCompactionEngine>(
      ContextCompactionEngine(
        summarizer: StructuredCompactionSummarizer(),
      ),
    );
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<ProviderRateLimiter>(ProviderRateLimiter());
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(repo, getIt<ProviderRateLimiter>()),
    );
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<AgentRuntimeService>(
      _FakeRuntimeService(Config(), repo),
    );

    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-preflight',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-preflight', [
      Message(role: MessageRole.user, content: 'goal: run preflight compaction'),
      for (var i = 0; i < 30; i++)
        Message(role: MessageRole.user, content: 'filler $i ${'x' * 200}'),
    ]);

    runner = AgentRunner(
      _PreflightAdapter(),
      ToolsRegistry(),
      sessionManager,
      existingSessionId: 'session-preflight',
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  test('preflight rebuilds provider history from activated projection', () async {
    final canonicalLength = runner.history.length;
    final revision = getIt<SessionHistoryRevisionRepository>()
        .read('session-preflight')!;
    final timeline = getIt<ModelProjectionBuilder>()
        .loadCanonicalTimeline('session-preflight');
    final outcome = await coordinator.runCompaction(
      request: CompactionEngineRequest(
        compactionId: 'cmp-preflight',
        sessionId: 'session-preflight',
        trigger: CompactionTrigger.auto,
        sourceRevision: revision.toCompactionRevision(),
        routeSignature: getIt<AgentRuntimeService>().resolveSignature(
          providerId: 'provider-1',
          modelId: 'gpt-4o',
        ),
        contextWindowTokens: 3_000,
        timeline: [
          for (final entry in timeline.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        systemPrompt: 'system',
        runtimeContext: '',
        toolSchemas: const [],
        targetRequestTokens: 2_000,
      ),
      force: true,
    );
    expect(outcome?.status, CompactionStatus.completed);
    expect(boundaries.findLatestCompletedForSession('session-preflight'), isNotNull);

    final history = await runner.debugPrepareProviderHistory();
    expect(history.where((m) => m.role == MessageRole.system), isNotEmpty);
    expect(history.length, lessThan(canonicalLength + 2));
    expect(
      history.any(
        (message) =>
            message.metadata?[CompactionSummaryProjection.projectionMetadataKey] ==
            true,
      ),
      isTrue,
    );
    expect(runner.history.length, canonicalLength);
  });
}
