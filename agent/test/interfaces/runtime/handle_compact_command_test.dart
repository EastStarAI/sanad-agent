import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

RouteSignature _route() => const RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-4o',
  configRevision: 1,
  credentialRevision: 1,
);

void main() {
  late AgentStateDatabase state;
  late SessionRunOrchestrator orchestrator;
  late CompactionBoundaryRepository boundaries;

  setUp(() {
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    SessionManager.resetForTesting();
    final sessions = SessionManager();
    final now = DateTime.utc(2026, 8, 29);
    sessions.db.saveSession(
      SessionState(
        sessionId: 'session-compact-cmd',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    getIt.registerSingleton<CompactionBoundaryRepository>(boundaries);
    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  test('returns compaction_in_progress while compaction barrier is active', () async {
    orchestrator.debugEnterCompactionBarrier('session-compact-cmd');

    final result = await orchestrator.handleCompactCommand(
      sessionId: 'session-compact-cmd',
      requestId: 'req-busy',
    );

    expect(
      result['outcome'],
      CompactionFailureReason.compactionInProgress.wireValue,
    );
  });

  test('returns compaction_in_progress when durable started row exists', () async {
    boundaries.tryClaim(
      compactionId: 'cmp-started',
      sessionId: 'session-compact-cmd',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(2),
      ),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 29),
    );

    final result = await orchestrator.handleCompactCommand(
      sessionId: 'session-compact-cmd',
      requestId: 'req-in-progress',
    );

    expect(
      result['outcome'],
      CompactionFailureReason.compactionInProgress.wireValue,
    );
  });

  test('returns unavailable when compaction coordinator is not registered', () async {
    final result = await orchestrator.handleCompactCommand(
      sessionId: 'session-compact-cmd',
      requestId: 'req-unavailable',
    );

    expect(result['outcome'], 'unavailable');
  });

}
