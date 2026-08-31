import 'dart:io';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
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

class _OverflowAdapter implements LLMAdapter {
  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4_096;

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
  late SessionDB sessions;
  late SessionManager sessionManager;
  late CompactionBoundaryRepository boundaries;
  late List<CompactionTrigger> triggers;
  late AgentRunner runner;
  late Directory sanadHome;

  setUp(() async {
    sanadHome = Directory.systemTemp.createTempSync('compaction_overflow_');
    setSanadHomeOverride(sanadHome.path);
    await SanadHomeBootstrap.identity().prepare();
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
    triggers = [];
    final activation = CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: SessionProjectionRevisionRepository(state),
    );
    getIt.registerSingleton<CompactionCoordinator>(
      CompactionCoordinator(
        engine: ContextCompactionEngine(
          summarizer: StructuredCompactionSummarizer(),
        ),
        boundaries: boundaries,
        activation: activation,
        projectionBuilder: ModelProjectionBuilder(
          sessions: sessions,
          boundaries: boundaries,
        ),
        onLifecycleEvent: (event) => triggers.add(event.trigger),
      ),
    );
    getIt.registerSingleton<ModelProjectionBuilder>(
      ModelProjectionBuilder(sessions: sessions, boundaries: boundaries),
    );
    getIt.registerSingleton<SessionHistoryRevisionRepository>(
      SessionHistoryRevisionRepository(state),
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
        sessionId: 'session-overflow',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-overflow', [
      Message(role: MessageRole.user, content: 'goal: recover from overflow'),
      for (var i = 0; i < 20; i++)
        Message(role: MessageRole.user, content: 'filler $i ${'x' * 200}'),
    ]);

    runner = AgentRunner(
      _OverflowAdapter(),
      ToolsRegistry(),
      sessionManager,
      existingSessionId: 'session-overflow',
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
    setSanadHomeOverride(null);
    sanadHome.deleteSync(recursive: true);
  });

  test('recovers once from context overflow before stream starts', () async {
    final recovered = await runner.debugTryOverflowCompactionRecovery(
      error: const LlmHttpException(
        statusCode: 400,
        body: 'maximum context length exceeded',
        headers: {},
        operation: 'chat.completions',
      ),
      providerInstanceId: 'provider-1',
      modelId: 'gpt-4o',
    );

    expect(
      recovered,
      isTrue,
      reason: boundaries
          .listLifecycleForSession('session-overflow')
          .map((operation) => operation.failureReason)
          .toList()
          .toString(),
    );
    expect(triggers, contains(CompactionTrigger.overflow));
  });

  test('does not retry overflow compaction twice', () async {
    await runner.debugTryOverflowCompactionRecovery(
      error: const LlmHttpException(
        statusCode: 400,
        body: 'maximum context length exceeded',
        headers: {},
        operation: 'chat.completions',
      ),
      providerInstanceId: 'provider-1',
      modelId: 'gpt-4o',
    );
    triggers.clear();

    final second = await runner.debugTryOverflowCompactionRecovery(
      error: const LlmHttpException(
        statusCode: 400,
        body: 'maximum context length exceeded',
        headers: {},
        operation: 'chat.completions',
      ),
      providerInstanceId: 'provider-1',
      modelId: 'gpt-4o',
    );

    expect(second, isFalse);
    expect(triggers, isEmpty);
  });

  test(
    'skips overflow compaction after visible stream output started',
    () async {
      final recovered = await runner.debugTryOverflowCompactionRecovery(
        error: const LlmHttpException(
          statusCode: 400,
          body: 'maximum context length exceeded',
          headers: {},
          operation: 'chat.completions',
        ),
        providerInstanceId: 'provider-1',
        modelId: 'gpt-4o',
        streamStarted: true,
      );

      expect(recovered, isFalse);
      expect(triggers, isEmpty);
    },
  );
}
