import 'dart:io';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
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

CompactionCandidate _candidate({
  required String id,
  required CompactionHistoryRevision revision,
}) {
  const summary = CompactionInternalSummary(
    currentGoal: 'Goal',
    remainingWork: 'Work left',
  );
  return CompactionCandidate(
    compactionId: id,
    sessionId: 'session-restart',
    trigger: CompactionTrigger.auto,
    sourceRevision: revision,
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
      contextWindowTokens: 128_000,
      estimatedRequestTokensBefore: 90_000,
      estimatedRequestTokensAfter: 20_000,
      retainedTailTokens: 5_000,
    ),
    routeSignature: _route(),
  );
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('compaction-restart-test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('completed boundary survives database reopen for history parity', () {
    final state = AgentStateDatabase.atPath(tempDir.path);
    final sessions = SessionDB.fromState(state);
    final revisions = SessionHistoryRevisionRepository(state);
    final boundaries = CompactionBoundaryRepository(state, revisions);
    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-restart',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-restart', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(role: MessageRole.user, content: 'three'),
    ]);

    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-restart',
      sessionId: 'session-restart',
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
    boundaries.completeStarted(
      candidate: _candidate(
        id: 'cmp-restart',
        revision: claim.record!.sourceHistoryRevision,
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );
    state.dispose();

    final reopened = AgentStateDatabase.atPath(tempDir.path);
    addTearDown(reopened.dispose);
    final reopenedBoundaries = CompactionBoundaryRepository(
      reopened,
      SessionHistoryRevisionRepository(reopened),
    );

    final lifecycle = reopenedBoundaries.listLifecycleForSession(
      'session-restart',
    );
    expect(lifecycle, hasLength(1));
    expect(lifecycle.single.status, CompactionStatus.completed);
    expect(lifecycle.single.compactionId, 'cmp-restart');
    expect(lifecycle.single.internalSummary?.currentGoal, 'Goal');
  });

  test('reopen converts an unactivated started row to interrupted failure', () {
    final state = AgentStateDatabase.atPath(tempDir.path);
    final sessions = SessionDB.fromState(state);
    final boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-restart',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-restart', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(role: MessageRole.user, content: 'three'),
    ]);
    boundaries.tryClaim(
      compactionId: 'cmp-interrupted-restart',
      sessionId: 'session-restart',
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
      startedAt: now,
    );
    state.dispose();

    final reopened = AgentStateDatabase.atPath(tempDir.path);
    addTearDown(reopened.dispose);
    final reopenedBoundaries = CompactionBoundaryRepository(
      reopened,
      SessionHistoryRevisionRepository(reopened),
    );
    reopenedBoundaries.recoverInterruptedStartedOperations(
      completedAt: now.add(const Duration(seconds: 1)),
    );

    final row = reopenedBoundaries.findById('cmp-interrupted-restart');
    expect(row?.status, CompactionStatus.failed);
    expect(row?.failureReason, CompactionFailureReason.interrupted);
    expect(
      reopenedBoundaries.findLatestCompletedForSession('session-restart'),
      isNull,
    );
  });
}
