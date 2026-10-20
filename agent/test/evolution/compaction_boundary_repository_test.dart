import 'dart:io';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';
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
  CompactionDurableDiagnostics? diagnostics,
  int contextWindowTokens = 128_000,
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
      contextWindowTokens: contextWindowTokens,
      estimatedRequestTokensBefore: 90_000,
      estimatedRequestTokensAfter: 20_000,
      retainedTailTokens: 5_000,
      duration: const Duration(seconds: 2),
      summarizationInputTokens: 1_200,
      summarizationCachedInputTokens: 900,
      summarizationCacheWriteTokens: 25,
      summarizationOutputTokens: 180,
      summarizationReasoningTokens: 40,
      summarizationAttempts: 2,
    ),
    routeSignature: _route(),
    diagnostics: diagnostics,
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
        'effective_input_budget_tokens',
        'auto_threshold_tokens',
        'summarization_input_tokens',
        'summarization_cached_input_tokens',
        'summarization_attempts',
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
      expect(latest?.metrics?.summarizationInputTokens, 1_200);
      expect(latest?.metrics?.summarizationCachedInputTokens, 900);
      expect(latest?.metrics?.summarizationCacheWriteTokens, 25);
      expect(latest?.metrics?.summarizationOutputTokens, 180);
      expect(latest?.metrics?.summarizationReasoningTokens, 40);
      expect(latest?.metrics?.summarizationAttempts, 2);

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

  test('reconcileOrphanedStartedOperations unblocks subsequent compaction claims', () {
    boundaries.tryClaim(
      compactionId: 'cmp-orphaned',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 29),
    );

    final blocked = boundaries.tryClaim(
      compactionId: 'cmp-second',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 29),
    );
    expect(blocked.outcome, CompactionClaimOutcome.compactionInProgress);

    final recovered = boundaries.reconcileOrphanedStartedOperations();
    expect(recovered, 1);

    final unblocked = boundaries.tryClaim(
      compactionId: 'cmp-third',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 29),
    );
    expect(unblocked.outcome, CompactionClaimOutcome.claimed);
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

  test('reconcilePostBoundaryUsage binds exact request and truthfully records targetOutcome unknown in Stage 1', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-exact-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-exact-1',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
        diagnostics: const CompactionDurableDiagnostics(
          decisionSnapshot: {
            'target_ratio': 0.10,
            'target_scope': 'usable_budget',
          },
        ),
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    final initial = boundaries.findById('cmp-exact-1');
    expect(initial?.diagnostics?.postBoundary.status, 'pending');
    expect(initial?.diagnostics?.postBoundary.targetOutcome, TargetOutcome.unknown);

    final observedAt = DateTime.utc(2026, 8, 29, 2, 5);

    // Negative control: Unsolicited unreserved reply fails closed
    final unreserved = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-exact-1',
      requestId: 'req-first-turn',
      observedAt: observedAt,
      inputTokens: 12_000,
      cachedTokens: 4_000,
      routeSignature: _route(),
    );
    expect(unreserved, isNull);

    // Positive control: reserve first dispatched call
    final reserved = boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-exact-1',
      requestId: 'req-first-turn',
      routeSignature: _route(),
      dispatchedAt: observedAt,
    );
    expect(reserved, isNotNull);
    expect(reserved!.diagnostics?.postBoundary.status, 'reserved');

    // Exact reconciliation succeeds
    final reconciled = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-exact-1',
      requestId: 'req-first-turn',
      observedAt: observedAt,
      inputTokens: 12_000,
      cachedTokens: 4_000,
      routeSignature: _route(),
    );

    expect(reconciled, isNotNull);
    expect(reconciled!.metrics?.providerConfirmedRequestTokensAfter, 12_000);
    final post = reconciled.diagnostics!.postBoundary;
    expect(post.status, 'confirmed');
    expect(post.requestId, 'req-first-turn');
    expect(post.observedAt, observedAt);
    expect(post.inputTokens, 12_000);
    expect(post.cachedTokens, 4_000);
    expect(post.targetOutcome, TargetOutcome.unknown);
    expect(post.postInputRatio, closeTo(12_000 / 128_000, 0.0001));

    // Immutability: later turn growth (e.g. 35_000 tokens) must NOT overwrite
    final laterAttempt = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-exact-1',
      requestId: 'req-second-turn',
      observedAt: DateTime.utc(2026, 8, 29, 2, 10),
      inputTokens: 35_000,
      cachedTokens: 10_000,
      routeSignature: _route(),
    );
    expect(laterAttempt, isNull);
    final current = boundaries.findById('cmp-exact-1');
    expect(current!.metrics?.providerConfirmedRequestTokensAfter, 12_000);
    expect(current.diagnostics!.postBoundary.requestId, 'req-first-turn');
    expect(current.diagnostics!.postBoundary.inputTokens, 12_000);
  });

  test('reservePostBoundaryDispatch reserves first dispatched call and prevents subsequent steps from replacing reservation', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-reserve-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-reserve-1',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    final dispatchedAt = DateTime.utc(2026, 8, 29, 2, 1);
    final reserved = boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-reserve-1',
      requestId: 'turn-1:step-1',
      routeSignature: _route(),
      dispatchedAt: dispatchedAt,
    );
    expect(reserved, isNotNull);
    expect(reserved!.diagnostics?.postBoundary.status, 'reserved');
    expect(reserved.diagnostics?.postBoundary.requestId, 'turn-1:step-1');

    // Subsequent model call or retry in the same turn cannot overwrite the reservation
    final secondDispatch = boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-reserve-1',
      requestId: 'turn-1:step-2',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 2),
    );
    expect(secondDispatch, isNotNull);
    expect(secondDispatch!.diagnostics?.postBoundary.requestId, 'turn-1:step-1');

    // Unrelated step arriving with usage is rejected because it doesn't match the reserved requestId
    final unrelatedArriving = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-reserve-1',
      requestId: 'turn-1:step-2',
      observedAt: DateTime.utc(2026, 8, 29, 2, 3),
      inputTokens: 20_000,
      routeSignature: _route(),
    );
    expect(unrelatedArriving, isNull);

    // Reserved step arrives with confirmed usage and successfully confirms
    final confirmed = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-reserve-1',
      requestId: 'turn-1:step-1',
      observedAt: DateTime.utc(2026, 8, 29, 2, 4),
      inputTokens: 14_500,
      routeSignature: _route(),
    );
    expect(confirmed, isNotNull);
    expect(confirmed!.diagnostics?.postBoundary.status, 'confirmed');
    expect(confirmed.metrics?.providerConfirmedRequestTokensAfter, 14_500);
  });

  test('reconcilePostBoundaryUsage rejects later grown request when first call is marked missing', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-missing-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-missing-1',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    // First call is reserved at dispatch
    boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-missing-1',
      requestId: 'turn-1:step-1',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 1),
    );

    // First call completes with missing usage
    final missing = boundaries.recordPostBoundaryMissingUsage(
      compactionId: 'cmp-missing-1',
      requestId: 'turn-1:step-1',
      observedAt: DateTime.utc(2026, 8, 29, 2, 2),
      missingReason: 'no_provider_usage',
      routeSignature: _route(),
    );
    expect(missing, isNotNull);
    expect(missing!.diagnostics?.postBoundary.status, 'missing');
    expect(missing.metrics?.providerConfirmedRequestTokensAfter, isNull);

    // Later grown request (e.g. step 2 with tool outputs and usage) CANNOT overwrite missing status
    final laterWithUsage = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-missing-1',
      requestId: 'turn-1:step-2',
      observedAt: DateTime.utc(2026, 8, 29, 2, 3),
      inputTokens: 28_000,
      routeSignature: _route(),
    );
    expect(laterWithUsage, isNull);

    final current = boundaries.findById('cmp-missing-1');
    expect(current!.diagnostics?.postBoundary.status, 'missing');
    expect(current.metrics?.providerConfirmedRequestTokensAfter, isNull);
  });

  test('failStarted preserves failure diagnostics and attempt ledger into diagnostics_json', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-failed-diagnostics',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    expect(claim.outcome, CompactionClaimOutcome.claimed);

    final attempts = [
      const CompactionSummarizationAttemptRecord(
        passKind: 'full',
        requestId: 'compaction:cmp-failed-diagnostics:full:0',
        duration: Duration(milliseconds: 350),
        inputTokens: 1200,
        outputTokens: 80,
        outcome: 'invalid_response',
        failureReason: 'json_syntax_error',
      ),
      const CompactionSummarizationAttemptRecord(
        passKind: 'repair',
        requestId: 'compaction:cmp-failed-diagnostics:repair:1',
        duration: Duration(milliseconds: 400),
        inputTokens: 1300,
        outputTokens: 50,
        outcome: 'invalid_response',
        failureReason: 'missing_keys',
      ),
    ];
    const decisionSnapshot = {
      'context_window': 128000,
      'effective_input_budget': 115200,
      'auto_threshold_tokens': 103680,
      'target_request_tokens': 11520,
      'target_ratio': 0.10,
      'target_scope': 'usable_budget',
      'threshold_ratio': 0.90,
    };
    final failureDiagnostics = CompactionDurableDiagnostics(
      attempts: attempts,
      aggregateUsage: {'input_tokens': 2500, 'output_tokens': 130},
      decisionSnapshot: decisionSnapshot,
    );

    final failedResult = boundaries.failStarted(
      compactionId: 'cmp-failed-diagnostics',
      failureReason: CompactionFailureReason.summarizationFailed,
      completedAt: DateTime.utc(2026, 8, 29, 2),
      failureDetail: {
        'stage': CompactionFailureStage.provider,
        'cause': CompactionFailureCause.invalidResponse,
      },
      diagnostics: failureDiagnostics,
    );
    expect(failedResult.outcome, CompactionTerminalOutcome.failed);

    final persisted = boundaries.findById('cmp-failed-diagnostics');
    expect(persisted, isNotNull);
    expect(persisted!.status, CompactionStatus.failed);
    expect(persisted.diagnostics, isNotNull);
    expect(persisted.diagnostics!.attempts.length, 2);
    expect(persisted.diagnostics!.attempts[0].outcome, 'invalid_response');
    expect(persisted.diagnostics!.attempts[0].inputTokens, 1200);
    expect(persisted.diagnostics!.attempts[1].outcome, 'invalid_response');
    expect(persisted.diagnostics!.aggregateUsage['input_tokens'], 2500);
    expect(persisted.diagnostics!.decisionSnapshot?['target_scope'], 'usable_budget');
    expect(persisted.diagnostics!.decisionSnapshot?['target_ratio'], 0.10);
  });

  test('reconcilePostBoundaryUsage leaves targetOutcome unknown when target_ratio is absent', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-unknown-target',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-unknown-target',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
        // No decisionSnapshot with target_ratio
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-unknown-target',
      requestId: 'req-unknown-target',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 4),
    );

    final reconciled = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-unknown-target',
      requestId: 'req-unknown-target',
      observedAt: DateTime.utc(2026, 8, 29, 2, 5),
      inputTokens: 10_000,
      routeSignature: _route(),
    );

    expect(reconciled, isNotNull);
    final post = reconciled!.diagnostics!.postBoundary;
    expect(post.status, 'confirmed');
    expect(post.targetOutcome, TargetOutcome.unknown);
    expect(post.postInputRatio, closeTo(10_000 / 128_000, 0.0001));
  });

  test('reconcilePostBoundaryUsage rejects route mismatch and preserves pending state', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-route-mismatch',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-route-mismatch',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    const differentRoute = RouteSignature(
      providerInstanceId: 'provider-different',
      templateId: 'anthropic',
      protocol: 'anthropic_messages',
      normalizedBaseUrl: 'https://api.anthropic.com',
      modelId: 'claude-3-5-sonnet',
      configRevision: 1,
      credentialRevision: 1,
    );

    final rejected = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-route-mismatch',
      requestId: 'req-mismatch',
      observedAt: DateTime.utc(2026, 8, 29, 2, 5),
      inputTokens: 10_000,
      routeSignature: differentRoute,
    );

    expect(rejected, isNull);
    final current = boundaries.findById('cmp-route-mismatch');
    expect(current?.metrics?.providerConfirmedRequestTokensAfter, isNull);
    expect(current?.diagnostics?.postBoundary.status, 'pending');
  });

  test('recordPostBoundaryMissingUsage explicitly records missing state', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-missing-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-missing-1',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    // Unreserved call fails closed
    final unreserved = boundaries.recordPostBoundaryMissingUsage(
      compactionId: 'cmp-missing-1',
      requestId: 'req-no-usage',
      observedAt: DateTime.utc(2026, 8, 29, 2, 5),
      missingReason: 'no_provider_usage',
      routeSignature: _route(),
    );
    expect(unreserved, isNull);

    // Reserve dispatch
    final reserved = boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-missing-1',
      requestId: 'req-no-usage',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 5),
    );
    expect(reserved, isNotNull);

    final missing = boundaries.recordPostBoundaryMissingUsage(
      compactionId: 'cmp-missing-1',
      requestId: 'req-no-usage',
      observedAt: DateTime.utc(2026, 8, 29, 2, 5),
      missingReason: 'no_provider_usage',
      routeSignature: _route(),
    );

    expect(missing, isNotNull);
    expect(missing!.metrics?.providerConfirmedRequestTokensAfter, isNull);
    final post = missing.diagnostics!.postBoundary;
    expect(post.status, 'missing');
    expect(post.requestId, 'req-no-usage');
    expect(post.missingReason, 'no_provider_usage');
    expect(post.targetOutcome, TargetOutcome.unknown);
  });

  test('legacy compaction rows with null diagnostics fail closed and preserve existing confirmed scalars', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-legacy-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-legacy-1',
        sessionId: 'session-1',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    // Simulate legacy row created before upgrade by clearing diagnostics_json in SQLite
    state.db.execute(
      'UPDATE session_compaction_operations SET diagnostics_json = NULL WHERE compaction_id = ?',
      ['cmp-legacy-1'],
    );

    final legacyRecord = boundaries.findById('cmp-legacy-1');
    expect(legacyRecord?.diagnostics, isNull);

    final now = DateTime.utc(2026, 8, 29, 2, 5);

    // 1. reservePostBoundaryDispatch fails closed (returns null, does not synthesize diagnostics)
    final reserveResult = boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-legacy-1',
      requestId: 'req-legacy-step',
      routeSignature: _route(),
      dispatchedAt: now,
    );
    expect(reserveResult, isNull);

    // 2. reconcilePostBoundaryUsage fails closed
    final reconcileResult = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-legacy-1',
      requestId: 'req-legacy-step',
      observedAt: now,
      inputTokens: 15_000,
      cachedTokens: 2_000,
      routeSignature: _route(),
    );
    expect(reconcileResult, isNull);

    // 3. recordPostBoundaryMissingUsage fails closed
    final missingResult = boundaries.recordPostBoundaryMissingUsage(
      compactionId: 'cmp-legacy-1',
      requestId: 'req-legacy-step',
      observedAt: now,
      missingReason: 'no_provider_usage',
      routeSignature: _route(),
    );
    expect(missingResult, isNull);

    // 4. reconcileProviderUsage fails closed
    final legacyReconcileResult = boundaries.reconcileProviderUsage(
      compactionId: 'cmp-legacy-1',
      inputTokens: 15_000,
    );
    expect(legacyReconcileResult, isNull);

    // Row remains intact with null diagnostics
    final afterAttempts = boundaries.findById('cmp-legacy-1');
    expect(afterAttempts?.diagnostics, isNull);
    expect(afterAttempts?.metrics?.providerConfirmedRequestTokensAfter, isNull);

    // Now test a legacy row that ALREADY had confirmed scalars from before
    state.db.execute(
      '''
      UPDATE session_compaction_operations
      SET provider_confirmed_request_tokens_after = 18000,
          diagnostics_json = NULL
      WHERE compaction_id = ?
      ''',
      ['cmp-legacy-1'],
    );
    final confirmedLegacy = boundaries.findById('cmp-legacy-1');
    expect(confirmedLegacy?.metrics?.providerConfirmedRequestTokensAfter, 18000);
    expect(confirmedLegacy?.diagnostics, isNull);

    // Any new attempt on confirmed legacy row still preserves the 18000
    final overwriteAttempt = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-legacy-1',
      requestId: 'req-legacy-later',
      observedAt: now,
      inputTokens: 25_000,
      routeSignature: _route(),
    );
    expect(overwriteAttempt, isNull);
    expect(boundaries.findById('cmp-legacy-1')?.metrics?.providerConfirmedRequestTokensAfter, 18000);
  });

  test('diagnostics and post-boundary state survive database reopen on disk', () {
    final tempDir = Directory.systemTemp.createTempSync('compaction_restart_test_');
    try {
      final db1 = AgentStateDatabase.atPath(tempDir.path);
      final sessions1 = SessionDB.fromState(db1);
      final revisions1 = SessionHistoryRevisionRepository(db1);
      final boundaries1 = CompactionBoundaryRepository(db1, revisions1);

      final now = DateTime.utc(2026, 8, 29);
      sessions1.saveSession(
        SessionState(
          sessionId: 'session-persist',
          model: 'gpt-4o',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessions1.replaceMessages('session-persist', [
        Message(role: MessageRole.user, content: 'one'),
        Message(role: MessageRole.user, content: 'two'),
        Message(role: MessageRole.assistant, content: 'three'),
        Message(role: MessageRole.user, content: 'four'),
      ]);

      final startedAt = DateTime.utc(2026, 8, 29, 1);
      final claim = boundaries1.tryClaim(
        compactionId: 'cmp-persist-1',
        sessionId: 'session-persist',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: startedAt,
      );

      final candidateWithDiagnostics = CompactionCandidate(
        compactionId: 'cmp-persist-1',
        sessionId: 'session-persist',
        trigger: CompactionTrigger.auto,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        internalSummary: const CompactionInternalSummary(
          currentGoal: 'Persist Goal',
          remainingWork: 'Persist Work',
        ),
        continuityResult: CompactionContinuityResult.fromSummary(
          const CompactionInternalSummary(
            currentGoal: 'Persist Goal',
            remainingWork: 'Persist Work',
          ),
        ),
        metrics: CompactionMetrics(
          contextWindowTokens: 128_000,
          estimatedRequestTokensBefore: 90_000,
          estimatedRequestTokensAfter: 10_000,
          retainedTailTokens: 5_000,
          duration: const Duration(seconds: 2),
          summarizationInputTokens: 1_200,
          summarizationCachedInputTokens: 900,
          summarizationCacheWriteTokens: 25,
          summarizationOutputTokens: 180,
          summarizationReasoningTokens: 40,
          summarizationAttempts: 2,
        ),
        routeSignature: _route(),
        diagnostics: CompactionDurableDiagnostics(
          relativeDumpPath: 'dumps/compaction_dump_cmp-persist-1.json',
          attempts: const [
            CompactionSummarizationAttemptRecord(
              passKind: 'full',
              requestId: 'req-full-1',
              duration: Duration(milliseconds: 450),
              inputTokens: 1200,
              outcome: 'validation_failed',
              failureReason: 'schema_mismatch',
            ),
            CompactionSummarizationAttemptRecord(
              passKind: 'repair',
              requestId: 'req-repair-2',
              duration: Duration(milliseconds: 320),
              inputTokens: 600,
              outcome: 'success',
            ),
          ],
          aggregateUsage: const {'input_tokens': 1800},
          decisionSnapshot: const {'target_ratio': 0.10},
        ),
      );

      boundaries1.completeStarted(
        candidate: candidateWithDiagnostics,
        startedAt: startedAt,
        completedAt: DateTime.utc(2026, 8, 29, 2),
      );

      boundaries1.reservePostBoundaryDispatch(
        compactionId: 'cmp-persist-1',
        requestId: 'req-post-first',
        routeSignature: _route(),
        dispatchedAt: DateTime.utc(2026, 8, 29, 2, 4),
      );

      boundaries1.reconcilePostBoundaryUsage(
        compactionId: 'cmp-persist-1',
        requestId: 'req-post-first',
        observedAt: DateTime.utc(2026, 8, 29, 2, 5),
        inputTokens: 11_500,
        cachedTokens: 2_000,
        routeSignature: _route(),
      );

      // Close the first database connection to simulate daemon shutdown
      db1.dispose();

      // Re-open database from disk simulating daemon restart
      final db2 = AgentStateDatabase.atPath(tempDir.path);
      final revisions2 = SessionHistoryRevisionRepository(db2);
      final boundaries2 = CompactionBoundaryRepository(db2, revisions2);

      final reloaded = boundaries2.findById('cmp-persist-1');
      expect(reloaded, isNotNull);
      expect(reloaded!.compactionId, 'cmp-persist-1');
      expect(reloaded.metrics?.summarizationInputTokens, 1_200);
      expect(reloaded.metrics?.providerConfirmedRequestTokensAfter, 11_500);

      final diag = reloaded.diagnostics;
      expect(diag, isNotNull);
      expect(diag!.relativeDumpPath, 'dumps/compaction_dump_cmp-persist-1.json');
      expect(diag.attempts, hasLength(2));
      expect(diag.attempts[0].passKind, 'full');
      expect(diag.attempts[0].failureReason, 'schema_mismatch');
      expect(diag.attempts[1].passKind, 'repair');
      expect(diag.attempts[1].outcome, 'success');
      expect(diag.aggregateUsage['input_tokens'], 1800);

      final post = diag.postBoundary;
      expect(post.status, 'confirmed');
      expect(post.requestId, 'req-post-first');
      expect(post.inputTokens, 11_500);
      expect(post.cachedTokens, 2_000);
      expect(post.targetOutcome, TargetOutcome.unknown);

      db2.dispose();
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('reconcilePostBoundaryUsage targets specific compactionId in multi-compaction session without affecting others', () {
    final startedAt1 = DateTime.utc(2026, 8, 29, 1);
    final claim1 = boundaries.tryClaim(
      compactionId: 'cmp-multi-1',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt1,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-multi-1',
        sessionId: 'session-1',
        revision: claim1.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt1,
      completedAt: DateTime.utc(2026, 8, 29, 1, 30),
    );

    final startedAt2 = DateTime.utc(2026, 8, 29, 2);
    final claim2 = boundaries.tryClaim(
      compactionId: 'cmp-multi-2',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt2,
    );
    boundaries.completeStarted(
      candidate: _candidate(
        compactionId: 'cmp-multi-2',
        sessionId: 'session-1',
        revision: claim2.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt2,
      completedAt: DateTime.utc(2026, 8, 29, 2, 30),
    );

    boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-multi-1',
      requestId: 'req-multi-1',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 34),
    );

    // Reconcile cmp-multi-1 first (e.g. late out-of-order request or specific boundary binding)
    final rec1 = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-multi-1',
      requestId: 'req-multi-1',
      observedAt: DateTime.utc(2026, 8, 29, 2, 35),
      inputTokens: 8_000,
      cachedTokens: 2_000,
      routeSignature: _route(),
    );
    expect(rec1, isNotNull);
    expect(rec1!.metrics?.providerConfirmedRequestTokensAfter, 8_000);
    expect(rec1.diagnostics?.postBoundary.status, 'confirmed');
    expect(rec1.diagnostics?.postBoundary.requestId, 'req-multi-1');

    // cmp-multi-2 MUST remain pending and unaffected
    final rec2Before = boundaries.findById('cmp-multi-2');
    expect(rec2Before?.metrics?.providerConfirmedRequestTokensAfter, isNull);
    expect(rec2Before?.diagnostics?.postBoundary.status, 'pending');

    boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-multi-2',
      requestId: 'req-multi-2',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 39),
    );

    // Reconcile cmp-multi-2
    final rec2 = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-multi-2',
      requestId: 'req-multi-2',
      observedAt: DateTime.utc(2026, 8, 29, 2, 40),
      inputTokens: 9_500,
      cachedTokens: 3_000,
      routeSignature: _route(),
    );
    expect(rec2, isNotNull);
    expect(rec2!.metrics?.providerConfirmedRequestTokensAfter, 9_500);
    expect(rec2.diagnostics?.postBoundary.status, 'confirmed');
    expect(rec2.diagnostics?.postBoundary.requestId, 'req-multi-2');

    // cmp-multi-1 remains untouched
    final rec1After = boundaries.findById('cmp-multi-1');
    expect(rec1After?.metrics?.providerConfirmedRequestTokensAfter, 8_000);
    expect(rec1After?.diagnostics?.postBoundary.requestId, 'req-multi-1');
  });

  test('reconcilePostBoundaryUsage sets targetOutcome unknown when target ratio is absent or unspecified', () {
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-zero-window',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: _sourceRange(),
      retainedTailRange: _tailRange(),
      routeSignature: _route(),
      startedAt: startedAt,
    );

    final candidate = _candidate(
      compactionId: 'cmp-zero-window',
      sessionId: 'session-1',
      revision: claim.record!.sourceHistoryRevision,
    );

    boundaries.completeStarted(
      candidate: candidate,
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    boundaries.reservePostBoundaryDispatch(
      compactionId: 'cmp-zero-window',
      requestId: 'req-zero-win',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 2, 4),
    );

    final reconciled = boundaries.reconcilePostBoundaryUsage(
      compactionId: 'cmp-zero-window',
      requestId: 'req-zero-win',
      observedAt: DateTime.utc(2026, 8, 29, 2, 5),
      inputTokens: 5_000,
      routeSignature: _route(),
    );

    expect(reconciled, isNotNull);
    final post = reconciled!.diagnostics!.postBoundary;
    expect(post.status, 'confirmed');
    expect(post.targetOutcome, TargetOutcome.unknown);
    expect(post.postInputRatio, closeTo(5000 / 128000, 0.0001));
  });

  test('completeStarted and failStarted automatically discover and persist relativeDumpPath from dumper', () async {
    LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};
    try {
      // 1. Success case: dump created in-flight, completeStarted called without explicit dump path
      const compIdSuccess = 'cmp-auto-dump-success';
      await LLMRequestDumper.recordActualRequest(
        url: Uri.parse('https://api.example.com/v1/chat/completions'),
        headers: {},
        body: {},
        compactionId: compIdSuccess,
        requestId: 'compaction:$compIdSuccess:full:0',
        provider: 'openai',
        model: 'gpt-4o',
      );
      await LLMRequestDumper.dumpResponse(
        {'choices': []},
        compactionId: compIdSuccess,
        requestId: 'compaction:$compIdSuccess:full:0',
        statusCode: 200,
      );

      final startedAt1 = DateTime.utc(2026, 8, 29, 1);
      final claim1 = boundaries.tryClaim(
        compactionId: compIdSuccess,
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: startedAt1,
      );
      boundaries.completeStarted(
        candidate: _candidate(
          compactionId: compIdSuccess,
          sessionId: 'session-1',
          revision: claim1.record!.sourceHistoryRevision,
        ),
        startedAt: startedAt1,
        completedAt: DateTime.utc(2026, 8, 29, 1, 30),
      );

      final completedRecord = boundaries.findById(compIdSuccess);
      expect(completedRecord?.diagnostics?.relativeDumpPath, isNotNull);
      expect(
        completedRecord?.diagnostics?.relativeDumpPath,
        startsWith('request_dumps/compaction_dump_compaction_cmp-auto-dump-success_'),
      );

      // 2. Failure case: dump created in-flight, failStarted called
      const compIdFailure = 'cmp-auto-dump-failure';
      await LLMRequestDumper.recordActualRequest(
        url: Uri.parse('https://api.example.com/v1/chat/completions'),
        headers: {},
        body: {},
        compactionId: compIdFailure,
        requestId: 'compaction:$compIdFailure:full:0',
        provider: 'openai',
        model: 'gpt-4o',
      );
      await LLMRequestDumper.recordError(
        Exception('network timeout'),
        compactionId: compIdFailure,
        requestId: 'compaction:$compIdFailure:full:0',
        statusCode: 504,
      );

      final startedAt2 = DateTime.utc(2026, 8, 29, 2);
      boundaries.tryClaim(
        compactionId: compIdFailure,
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: startedAt2,
      );
      boundaries.failStarted(
        compactionId: compIdFailure,
        failureReason: CompactionFailureReason.summarizationFailed,
        completedAt: DateTime.utc(2026, 8, 29, 2, 30),
      );

      final failedRecord = boundaries.findById(compIdFailure);
      expect(failedRecord?.diagnostics?.relativeDumpPath, isNotNull);
      expect(
        failedRecord?.diagnostics?.relativeDumpPath,
        startsWith('request_dumps/compaction_dump_compaction_cmp-auto-dump-failure_'),
      );
    } finally {
      LLMRequestDumper.environmentOverride = null;
    }
  });

  group('R3/R4 Legacy Provenance and Unreserved Guards', () {
    test('legacy row with null diagnostics and no confirmation fails closed', () {
      final now = DateTime.utc(2026, 8, 29, 1);
      final claim = boundaries.tryClaim(
        compactionId: 'cmp-legacy-null-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: now,
      );
      // Insert a completed row simulating pre-upgrade state with diagnostics_json = NULL
      boundaries.completeStarted(
        candidate: _candidate(
          compactionId: 'cmp-legacy-null-1',
          sessionId: 'session-1',
          revision: claim.record!.sourceHistoryRevision,
        ),
        startedAt: now,
        completedAt: DateTime.utc(2026, 8, 29, 1, 30),
      );
      // Manually null out diagnostics_json to replicate pre-upgrade legacy rows
      state.db.execute(
        'UPDATE session_compaction_operations SET diagnostics_json = NULL, provider_confirmed_request_tokens_after = NULL WHERE compaction_id = ?',
        ['cmp-legacy-null-1'],
      );

      final legacyRow = boundaries.findById('cmp-legacy-null-1');
      expect(legacyRow, isNotNull);
      expect(legacyRow!.diagnostics, isNull);
      expect(legacyRow.metrics?.providerConfirmedRequestTokensAfter, isNull);

      // 1. reservePostBoundaryDispatch MUST fail closed (return null, never synthesize diagnostics)
      final reserveResult = boundaries.reservePostBoundaryDispatch(
        compactionId: 'cmp-legacy-null-1',
        requestId: 'turn-post-upgrade:step-1',
        routeSignature: _route(),
        dispatchedAt: DateTime.utc(2026, 8, 29, 2),
      );
      expect(reserveResult, isNull);

      // Verify DB remains untouched
      final afterReserve = boundaries.findById('cmp-legacy-null-1');
      expect(afterReserve!.diagnostics, isNull);
      expect(afterReserve.metrics?.providerConfirmedRequestTokensAfter, isNull);

      // 2. reconcilePostBoundaryUsage MUST fail closed
      final reconcileResult = boundaries.reconcilePostBoundaryUsage(
        compactionId: 'cmp-legacy-null-1',
        requestId: 'turn-post-upgrade:step-1',
        observedAt: DateTime.utc(2026, 8, 29, 2, 5),
        inputTokens: 12_000,
        routeSignature: _route(),
      );
      expect(reconcileResult, isNull);

      // 3. recordPostBoundaryMissingUsage MUST fail closed
      final missingResult = boundaries.recordPostBoundaryMissingUsage(
        compactionId: 'cmp-legacy-null-1',
        requestId: 'turn-post-upgrade:step-1',
        observedAt: DateTime.utc(2026, 8, 29, 2, 5),
        missingReason: 'no_provider_usage',
        routeSignature: _route(),
      );
      expect(missingResult, isNull);

      // Row still has diagnostics == null and confirmed tokens == null
      final finalRow = boundaries.findById('cmp-legacy-null-1');
      expect(finalRow!.diagnostics, isNull);
      expect(finalRow.metrics?.providerConfirmedRequestTokensAfter, isNull);
    });

    test('unsolicited unreserved reply fails closed on new completed compaction', () {
      final now = DateTime.utc(2026, 8, 29, 1);
      final claim = boundaries.tryClaim(
        compactionId: 'cmp-unreserved-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: now,
      );
      boundaries.completeStarted(
        candidate: _candidate(
          compactionId: 'cmp-unreserved-1',
          sessionId: 'session-1',
          revision: claim.record!.sourceHistoryRevision,
        ),
        startedAt: now,
        completedAt: DateTime.utc(2026, 8, 29, 1, 30),
      );

      final initial = boundaries.findById('cmp-unreserved-1');
      expect(initial?.diagnostics?.postBoundary.status, 'pending');

      // Unsolicited reply arrives without prior reservePostBoundaryDispatch
      final unreservedReconcile = boundaries.reconcilePostBoundaryUsage(
        compactionId: 'cmp-unreserved-1',
        requestId: 'unsolicited-step-1',
        observedAt: DateTime.utc(2026, 8, 29, 2),
        inputTokens: 18_000,
        routeSignature: _route(),
      );
      expect(unreservedReconcile, isNull);

      // Row remains pending and unconfirmed
      final afterAttempt = boundaries.findById('cmp-unreserved-1');
      expect(afterAttempt?.diagnostics?.postBoundary.status, 'pending');
      expect(afterAttempt?.metrics?.providerConfirmedRequestTokensAfter, isNull);

      // Unsolicited missing call also fails closed
      final unreservedMissing = boundaries.recordPostBoundaryMissingUsage(
        compactionId: 'cmp-unreserved-1',
        requestId: 'unsolicited-step-1',
        observedAt: DateTime.utc(2026, 8, 29, 2),
        missingReason: 'timeout',
        routeSignature: _route(),
      );
      expect(unreservedMissing, isNull);
      expect(boundaries.findById('cmp-unreserved-1')?.diagnostics?.postBoundary.status, 'pending');
    });

    test('preserves historical confirmed scalars without synthesizing diagnostics or allowing overwrite', () {
      final now = DateTime.utc(2026, 8, 29, 1);
      final claim = boundaries.tryClaim(
        compactionId: 'cmp-hist-scalar-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: now,
      );
      boundaries.completeStarted(
        candidate: _candidate(
          compactionId: 'cmp-hist-scalar-1',
          sessionId: 'session-1',
          revision: claim.record!.sourceHistoryRevision,
        ),
        startedAt: now,
        completedAt: DateTime.utc(2026, 8, 29, 1, 30),
      );
      // Simulate historical row: confirmed with 19182 tokens, but diagnostics_json was NULL
      state.db.execute(
        'UPDATE session_compaction_operations SET diagnostics_json = NULL, provider_confirmed_request_tokens_after = 19182 WHERE compaction_id = ?',
        ['cmp-hist-scalar-1'],
      );

      final historicalRow = boundaries.findById('cmp-hist-scalar-1');
      expect(historicalRow, isNotNull);
      expect(historicalRow!.diagnostics, isNull);
      expect(historicalRow.metrics?.providerConfirmedRequestTokensAfter, 19182);

      // reservePostBoundaryDispatch returns existing without synthesizing diagnostics
      final reserveResult = boundaries.reservePostBoundaryDispatch(
        compactionId: 'cmp-hist-scalar-1',
        requestId: 'turn-next:step-1',
        routeSignature: _route(),
        dispatchedAt: DateTime.utc(2026, 8, 29, 2),
      );
      expect(reserveResult, isNotNull);
      expect(reserveResult!.metrics?.providerConfirmedRequestTokensAfter, 19182);
      expect(reserveResult.diagnostics, isNull);

      // Duplicate confirmation with same scalar returns existing
      final duplicateReconcile = boundaries.reconcilePostBoundaryUsage(
        compactionId: 'cmp-hist-scalar-1',
        requestId: 'turn-next:step-1',
        observedAt: DateTime.utc(2026, 8, 29, 2, 5),
        inputTokens: 19182,
        routeSignature: _route(),
      );
      expect(duplicateReconcile, isNotNull);
      expect(duplicateReconcile!.metrics?.providerConfirmedRequestTokensAfter, 19182);

      // Later growth (e.g. 35_000 tokens) fails closed and does not overwrite 19182
      final overwriteAttempt = boundaries.reconcilePostBoundaryUsage(
        compactionId: 'cmp-hist-scalar-1',
        requestId: 'turn-next:step-2',
        observedAt: DateTime.utc(2026, 8, 29, 2, 10),
        inputTokens: 35_000,
        routeSignature: _route(),
      );
      expect(overwriteAttempt, isNull);

      // recordPostBoundaryMissingUsage does not clear confirmed tokens
      final missingAttempt = boundaries.recordPostBoundaryMissingUsage(
        compactionId: 'cmp-hist-scalar-1',
        requestId: 'turn-next:step-2',
        observedAt: DateTime.utc(2026, 8, 29, 2, 10),
        missingReason: 'stream_end',
        routeSignature: _route(),
      );
      expect(missingAttempt, isNotNull);
      expect(missingAttempt!.metrics?.providerConfirmedRequestTokensAfter, 19182);

      // Final check: historical scalar 19182 is preserved intact, diagnostics remains null
      final finalCheck = boundaries.findById('cmp-hist-scalar-1');
      expect(finalCheck!.metrics?.providerConfirmedRequestTokensAfter, 19182);
      expect(finalCheck.diagnostics, isNull);
    });

    test('reserved new-operation positive control successfully records first post-boundary confirmation', () {
      final now = DateTime.utc(2026, 8, 29, 1);
      final claim = boundaries.tryClaim(
        compactionId: 'cmp-pos-control-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: _sourceRange(),
        retainedTailRange: _tailRange(),
        routeSignature: _route(),
        startedAt: now,
      );
      boundaries.completeStarted(
        candidate: _candidate(
          compactionId: 'cmp-pos-control-1',
          sessionId: 'session-1',
          revision: claim.record!.sourceHistoryRevision,
        ),
        startedAt: now,
        completedAt: DateTime.utc(2026, 8, 29, 1, 30),
      );

      final completedRow = boundaries.findById('cmp-pos-control-1');
      expect(completedRow?.diagnostics?.postBoundary.status, 'pending');

      // 1. Dispatch is reserved
      final reserved = boundaries.reservePostBoundaryDispatch(
        compactionId: 'cmp-pos-control-1',
        requestId: 'turn-1:step-1',
        routeSignature: _route(),
        dispatchedAt: DateTime.utc(2026, 8, 29, 2),
      );
      expect(reserved, isNotNull);
      expect(reserved!.diagnostics?.postBoundary.status, 'reserved');
      expect(reserved.diagnostics?.postBoundary.requestId, 'turn-1:step-1');

      // 2. Matching reply reconciles
      final reconciled = boundaries.reconcilePostBoundaryUsage(
        compactionId: 'cmp-pos-control-1',
        requestId: 'turn-1:step-1',
        observedAt: DateTime.utc(2026, 8, 29, 2, 2),
        inputTokens: 14_500,
        cachedTokens: 3_000,
        routeSignature: _route(),
      );
      expect(reconciled, isNotNull);
      expect(reconciled!.diagnostics?.postBoundary.status, 'confirmed');
      expect(reconciled.diagnostics?.postBoundary.requestId, 'turn-1:step-1');
      expect(reconciled.diagnostics?.postBoundary.inputTokens, 14_500);
      expect(reconciled.diagnostics?.postBoundary.cachedTokens, 3_000);
      expect(reconciled.metrics?.providerConfirmedRequestTokensAfter, 14_500);

      // 3. Later growth (different step or turn) cannot overwrite confirmed first call
      final laterGrowth = boundaries.reconcilePostBoundaryUsage(
        compactionId: 'cmp-pos-control-1',
        requestId: 'turn-1:step-2',
        observedAt: DateTime.utc(2026, 8, 29, 2, 5),
        inputTokens: 25_000,
        routeSignature: _route(),
      );
      expect(laterGrowth, isNull);

      final finalPosRow = boundaries.findById('cmp-pos-control-1');
      expect(finalPosRow!.metrics?.providerConfirmedRequestTokensAfter, 14_500);
      expect(finalPosRow.diagnostics?.postBoundary.requestId, 'turn-1:step-1');
    });
  });
}
