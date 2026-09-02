import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_execution_registry.dart';

void main() {
  group('SessionExecutionRegistry', () {
    test('accepts a newer snapshot', () {
      final registry = SessionExecutionRegistry();
      final incoming = _snapshot(
        revision: 1,
        state: SessionExecutionState.queued,
      );

      final result = registry.apply(incoming);

      expect(result.disposition, SessionExecutionApplyDisposition.applied);
      expect(result.accepted, isTrue);
      expect(result.changed, isTrue);
      expect(registry.snapshotFor('session-a'), incoming);
    });

    test('accepts an equal identical replay idempotently', () {
      final registry = SessionExecutionRegistry();
      final snapshot = _snapshot(
        revision: 2,
        state: SessionExecutionState.running,
      );
      registry.apply(snapshot);

      final result = registry.apply(snapshot);

      expect(result.disposition, SessionExecutionApplyDisposition.idempotent);
      expect(result.accepted, isTrue);
      expect(result.changed, isFalse);
      expect(result.diagnostic, contains('identical replay'));
    });

    test('refreshes a newer elapsed observation at the same revision', () {
      final registry = SessionExecutionRegistry();
      final startedAt = DateTime.utc(2026, 7, 15, 10);
      final firstReceivedAt = DateTime.utc(2026, 7, 15, 10, 1);
      final refreshedReceivedAt = DateTime.utc(2026, 7, 15, 10, 3);
      registry.apply(
        _snapshot(
          revision: 2,
          state: SessionExecutionState.running,
          turnStartedAt: startedAt,
          elapsedMs: 60000,
          baselineReceivedAt: firstReceivedAt,
        ),
      );

      final result = registry.apply(
        _snapshot(
          revision: 2,
          state: SessionExecutionState.running,
          turnStartedAt: startedAt,
          elapsedMs: 180000,
          baselineReceivedAt: refreshedReceivedAt,
        ),
      );

      expect(
        result.disposition,
        SessionExecutionApplyDisposition.refreshedObservation,
      );
      expect(result.changed, isTrue);
      expect(registry.snapshotFor('session-a').elapsedMs, 180000);
      expect(
        registry.snapshotFor('session-a').elapsedAt(DateTime.utc(2026, 7, 15, 10, 3, 5)),
        const Duration(minutes: 3, seconds: 5),
      );
    });

    test('rejects an equal conflicting payload', () {
      final registry = SessionExecutionRegistry();
      registry.apply(
        _snapshot(revision: 3, state: SessionExecutionState.running),
      );

      final result = registry.apply(
        _snapshot(revision: 3, state: SessionExecutionState.waiting),
      );

      expect(
        result.disposition,
        SessionExecutionApplyDisposition.rejectedConflictingRevision,
      );
      expect(result.accepted, isFalse);
      expect(result.diagnostic, contains('conflicting'));
      expect(
        registry.snapshotFor('session-a').state,
        SessionExecutionState.running,
      );
    });

    test('rejects a stale revision', () {
      final registry = SessionExecutionRegistry();
      registry.apply(
        _snapshot(revision: 5, state: SessionExecutionState.resuming),
      );

      final result = registry.apply(
        _snapshot(revision: 4, state: SessionExecutionState.blocked),
      );

      expect(
        result.disposition,
        SessionExecutionApplyDisposition.rejectedStaleRevision,
      );
      expect(result.accepted, isFalse);
      expect(result.diagnostic, contains('current revision is 5'));
      expect(registry.snapshotFor('session-a').revision, 5);
    });

    test('isolates revision streams by session id', () {
      final registry = SessionExecutionRegistry();
      registry.apply(
        _snapshot(revision: 8, state: SessionExecutionState.running),
      );

      final secondResult = registry.apply(
        _snapshot(
          sessionId: 'session-b',
          revision: 1,
          state: SessionExecutionState.waiting,
        ),
      );

      expect(
        secondResult.disposition,
        SessionExecutionApplyDisposition.applied,
      );
      expect(registry.snapshotFor('session-a').revision, 8);
      expect(
        registry.snapshotFor('session-a').state,
        SessionExecutionState.running,
      );
      expect(registry.snapshotFor('session-b').revision, 1);
      expect(
        registry.snapshotFor('session-b').state,
        SessionExecutionState.waiting,
      );
      expect(
        registry.snapshotFor('session-c'),
        SessionExecutionSnapshot.virtualIdle('session-c'),
      );
    });

    test('applyPayload enforces the expected session id', () {
      final registry = SessionExecutionRegistry();

      expect(
        () => registry.applyPayload({
          'session_id': 'session-a',
          'state': 'running',
          'work_item_id': 'work-1',
          'request_id': 'request-1',
          'revision': 1,
          'updated_at': '2026-07-15T10:30:00Z',
        }, expectedSessionId: 'session-b'),
        throwsFormatException,
      );
      expect(registry.snapshotsBySessionId, isEmpty);
    });
  });
}

SessionExecutionSnapshot _snapshot({
  String sessionId = 'session-a',
  required int revision,
  required SessionExecutionState state,
  DateTime? turnStartedAt,
  int? elapsedMs,
  DateTime? baselineReceivedAt,
}) {
  return SessionExecutionSnapshot(
    sessionId: sessionId,
    state: state,
    workItemId: state == SessionExecutionState.idle ? null : 'work-$sessionId',
    requestId: state == SessionExecutionState.idle ? null : 'request-$sessionId',
    revision: revision,
    updatedAt: DateTime.utc(2026, 7, 15, 10, revision),
    turnStartedAt: turnStartedAt,
    elapsedMs: elapsedMs,
    baselineReceivedAt: baselineReceivedAt,
  );
}
