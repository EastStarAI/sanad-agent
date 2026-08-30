import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/compaction/compaction_boundary_change.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
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

CompactionCandidate _candidate({required String id}) {
  const summary = CompactionInternalSummary(
    currentGoal: 'Ship feature',
    remainingWork: 'Verify activation',
  );
  return CompactionCandidate(
    compactionId: id,
    sessionId: 'session-1',
    trigger: CompactionTrigger.manual,
    sourceRevision: const CompactionHistoryRevision(1),
    sourceRange: CompactionMessageRange(
      start: const CompactionMessageIdentity(1),
      end: const CompactionMessageIdentity(1),
    ),
    retainedTailRange: CompactionMessageRange(
      start: const CompactionMessageIdentity(2),
      end: const CompactionMessageIdentity(3),
    ),
    internalSummary: summary,
    continuityResult: CompactionContinuityResult.fromSummary(summary),
    metrics: CompactionMetrics(
      contextWindowTokens: 100_000,
      estimatedRequestTokensBefore: 80_000,
      estimatedRequestTokensAfter: 20_000,
      retainedTailTokens: 5_000,
    ),
    routeSignature: _route(),
  );
}

void main() {
  late AgentStateDatabase state;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late SessionProjectionRevisionRepository projectionRevisions;
  late CompactionBoundaryActivated? activated;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    sessions = SessionDB.fromState(state);
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    projectionRevisions = SessionProjectionRevisionRepository(state);
    activated = null;
    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-1',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(role: MessageRole.user, content: 'three'),
    ]);
  });

  tearDown(() {
    sessions.dispose();
    state.dispose();
  });

  CompactionActivationService service() {
    return CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: projectionRevisions,
      changes: CompactionBoundaryChangeNotifier(
        onActivated: (change) => activated = change,
      ),
    );
  }

  test('successful activation bumps projection revision and publishes once', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    boundaries.tryClaim(
      compactionId: 'cmp-activate',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(3),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );

    expect(projectionRevisions.read('session-1')!.value, 0);

    final result = service().activateCandidate(
      candidate: _candidate(id: 'cmp-activate'),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    expect(result.outcome, CompactionTerminalOutcome.completed);
    expect(projectionRevisions.read('session-1')!.value, 1);
    expect(activated?.projectionRevision.value, 1);
    expect(activated?.boundary.compactionId, 'cmp-activate');
  });

  test('failed activation does not bump projection revision', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    boundaries.tryClaim(
      compactionId: 'cmp-fail',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(3),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );

    final result = service().failOperation(
      compactionId: 'cmp-fail',
      failureReason: CompactionFailureReason.summarizationFailed,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    expect(result.outcome, CompactionTerminalOutcome.failed);
    expect(projectionRevisions.read('session-1')!.value, 0);
    expect(activated, isNull);
  });

  test('late completion is stale when newer boundary already committed', () {
    final firstStarted = DateTime.utc(2026, 8, 29, 1);
    boundaries.tryClaim(
      compactionId: 'cmp-old',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(2),
      ),
      routeSignature: _route(),
      startedAt: firstStarted,
    );
    service().activateCandidate(
      candidate: _candidate(id: 'cmp-old'),
      startedAt: firstStarted,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    final lateStarted = DateTime.utc(2026, 8, 29, 0, 30);
    boundaries.tryClaim(
      compactionId: 'cmp-late',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(3),
      ),
      routeSignature: _route(),
      startedAt: lateStarted,
    );

    final lateResult = service().activateCandidate(
      candidate: _candidate(id: 'cmp-late'),
      startedAt: lateStarted,
      completedAt: DateTime.utc(2026, 8, 29, 3),
    );

    expect(
      lateResult.outcome,
      CompactionTerminalOutcome.supersededByNewerBoundary,
    );
    expect(
      boundaries.findLatestCompletedForSession('session-1')?.compactionId,
      'cmp-old',
    );
  });

  test('missing message rows reject activation without mutation', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    boundaries.tryClaim(
      compactionId: 'cmp-missing',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(99),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );

    final result = service().activateCandidate(
      candidate: CompactionCandidate(
        compactionId: 'cmp-missing',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(1),
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(1),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(2),
          end: const CompactionMessageIdentity(99),
        ),
        internalSummary: _candidate(id: 'x').internalSummary,
        continuityResult: _candidate(id: 'x').continuityResult,
        metrics: _candidate(id: 'x').metrics,
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    expect(result.outcome, CompactionTerminalOutcome.missingMessageRows);
    expect(boundaries.findStartedForSession('session-1')?.compactionId, 'cmp-missing');
    expect(projectionRevisions.read('session-1')!.value, 0);
  });
}
