import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/models/compaction_operation_record.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

RouteSignature _route() {
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

CompactionMessageRange _sourceRange() {
  return CompactionMessageRange(
    start: const CompactionMessageIdentity(1),
    end: const CompactionMessageIdentity(2),
  );
}

CompactionMessageRange _tailRange() {
  return CompactionMessageRange(
    start: const CompactionMessageIdentity(3),
    end: const CompactionMessageIdentity(4),
  );
}

CompactionCandidate _candidate({
  required String compactionId,
  required String sessionId,
  required CompactionHistoryRevision revision,
}) {
  const summary = CompactionInternalSummary(
    currentGoal: 'Goal',
    remainingWork: 'Work left',
  );
  return CompactionCandidate(
    compactionId: compactionId,
    sessionId: sessionId,
    trigger: CompactionTrigger.auto,
    sourceRevision: revision,
    sourceRange: _sourceRange(),
    retainedTailRange: _tailRange(),
    internalSummary: summary,
    continuityResult: CompactionContinuityResult.fromSummary(summary),
    metrics: CompactionMetrics(
      contextWindowTokens: 128_000,
      estimatedRequestTokensBefore: 90_000,
      estimatedRequestTokensAfter: 20_000,
      retainedTailTokens: 5_000,
      duration: const Duration(seconds: 2),
    ),
    routeSignature: _route(),
  );
}

void main() {
  late AgentStateDatabase state;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late SessionHistoryRevisionRepository revisions;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    sessions = SessionDB.fromState(state);
    revisions = SessionHistoryRevisionRepository(state);
    boundaries = CompactionBoundaryRepository(state, revisions);
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
      Message(role: MessageRole.user, content: 'two'),
      Message(role: MessageRole.assistant, content: 'three'),
      Message(role: MessageRole.user, content: 'four'),
    ]);
  });

  tearDown(() {
    sessions.dispose();
    state.dispose();
  });

  test('migration creates compaction table and history revision column', () {
    final tables = state.db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session_compaction_operations'",
    );
    expect(tables, isNotEmpty);

    final columns = state.db.select('PRAGMA table_info(sessions)');
    expect(columns.map((row) => row['name']), contains('history_revision'));
    final compactionColumns = state.db.select(
      'PRAGMA table_info(session_compaction_operations)',
    );
    expect(
      compactionColumns.map((row) => row['name']),
      containsAll([
        'before_measurement_kind',
        'provider_confirmed_request_tokens_after',
      ]),
    );
  });

  test('exclusive claim allows only one started operation per session', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final first = boundaries.tryClaim(
      compactionId: 'cmp-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    expect(first.outcome, CompactionClaimOutcome.claimed);

    final second = boundaries.tryClaim(
      compactionId: 'cmp-2',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    expect(second.outcome, CompactionClaimOutcome.compactionInProgress);
  });

  test(
    'completed boundary survives database reopen and drives eligibility',
    () {
      final startedAt = DateTime.utc(2026, 8, 29, 1);
      final claim = boundaries.tryClaim(
        compactionId: 'cmp-complete',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: startedAt,
      );
      final revision = claim.record!.sourceHistoryRevision;
      final complete = boundaries.completeStarted(
        candidate: _candidate(
          compactionId: 'cmp-complete',
          sessionId: 'session-1',
          revision: revision,
        ),
        startedAt: startedAt,
        completedAt: DateTime.utc(2026, 8, 29, 2),
      );
      expect(complete.outcome, CompactionTerminalOutcome.completed);

      final latest = boundaries.findLatestCompletedForSession('session-1');
      expect(latest?.compactionId, 'cmp-complete');
      expect(latest?.internalSummary?.currentGoal, 'Goal');

      final rowIds = boundaries.messageRowIdsForSession('session-1');
      expect(
        CompactionBoundaryValidity.isProjectionEligible(
          boundary: latest!,
          existingMessageRowIds: rowIds,
          currentRevision: revisions.read('session-1')!,
        ),
        isTrue,
      );
    },
  );

  test('completion accepts durable ranges with AUTOINCREMENT gaps', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.user, content: 'two edited'),
      Message(role: MessageRole.assistant, content: 'three edited'),
      Message(role: MessageRole.user, content: 'four edited'),
    ]);
    final ids = sessions
        .getPersistedMessages('session-1')
        .map((entry) => entry.rowId)
        .toList();
    expect(ids, [1, 5, 6, 7]);
    final source = CompactionMessageRange(
      start: CompactionMessageIdentity(ids[0]),
      end: CompactionMessageIdentity(ids[1]),
    );
    final tail = CompactionMessageRange(
      start: CompactionMessageIdentity(ids[2]),
      end: CompactionMessageIdentity(ids[3]),
    );
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-gapped',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: source,
      retainedTailRange: tail,
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Preserve gapped identities',
      remainingWork: 'Project the retained tail',
    );
    final result = boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-gapped',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: source,
        retainedTailRange: tail,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    expect(result.outcome, CompactionTerminalOutcome.completed);
  });

  test('failed and started rows are not returned as latest completed', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    boundaries.tryClaim(
      compactionId: 'cmp-fail',
      sessionId: 'session-1',
      trigger: CompactionTrigger.overflow,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.failStarted(
      compactionId: 'cmp-fail',
      failureReason: CompactionFailureReason.summarizationFailed,
      completedAt: DateTime.utc(2026, 8, 29, 2),
      failureDetail: const {'phase': 'summarizer'},
    );

    expect(boundaries.findLatestCompletedForSession('session-1'), isNull);

    boundaries.tryClaim(
      compactionId: 'cmp-started',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    expect(
      boundaries.findStartedForSession('session-1')?.compactionId,
      'cmp-started',
    );
    expect(boundaries.findLatestCompletedForSession('session-1'), isNull);
  });

  test('recoverInterruptedStartedOperations fails orphaned started rows', () {
    boundaries.tryClaim(
      compactionId: 'cmp-interrupted',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 29),
    );

    expect(boundaries.recoverInterruptedStartedOperations(), 1);

    final row = boundaries.findById('cmp-interrupted');
    expect(row?.status, CompactionStatus.failed);
    expect(row?.failureReason, CompactionFailureReason.interrupted);
  });

  test('completeStarted rejects stale history revision', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-stale',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    SessionHistoryRevisionRepository.bumpDatabase(state.db, 'session-1');

    final result = boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-stale',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );
    expect(result.outcome, CompactionTerminalOutcome.sourceRevisionStale);
    expect(boundaries.findById('cmp-stale')?.status, CompactionStatus.started);
  });

  test('summary persistence redacts secret-shaped content', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    boundaries.tryClaim(
      compactionId: 'cmp-redact',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Use sk-12345678901234567890123456789012 safely',
      remainingWork: 'Continue',
    );
    final candidate = CompactionCandidate(
      compactionId: 'cmp-redact',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRevision: const CompactionHistoryRevision(1),
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      internalSummary: summary,
      continuityResult: CompactionContinuityResult.fromSummary(summary),
      metrics: CompactionMetrics(
        contextWindowTokens: 10_000,
        estimatedRequestTokensBefore: 8_000,
        estimatedRequestTokensAfter: 2_000,
        retainedTailTokens: 500,
      ),
      routeSignature: _route(),
    );
    boundaries.completeStarted(
      candidate: candidate,
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    final raw = state.db.select(
      'SELECT internal_summary_json FROM session_compaction_operations WHERE compaction_id = ?',
      ['cmp-redact'],
    );
    final json = raw.first['internal_summary_json'] as String;
    expect(json, isNot(contains('sk-12345678901234567890123456789012')));
    expect(json, contains('***'));
  });

  test('first provider usage reconciles metrics without changing boundary', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-reconcile',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-reconcile',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    final reconciled = boundaries.reconcileProviderUsage(
      compactionId: 'cmp-reconcile',
      inputTokens: 18_750,
    );
    expect(reconciled?.metrics?.providerConfirmedRequestTokensAfter, 18_750);
    expect(reconciled?.sourceRange, _sourceRange());
    expect(reconciled?.retainedTailRange, _tailRange());

    expect(
      boundaries.reconcileProviderUsage(
        compactionId: 'cmp-reconcile',
        inputTokens: 19_000,
      ),
      isNull,
      reason: 'later tool-loop responses must not replace the first response',
    );
    expect(
      boundaries
          .findById('cmp-reconcile')
          ?.metrics
          ?.providerConfirmedRequestTokensAfter,
      18_750,
    );
  });
}
