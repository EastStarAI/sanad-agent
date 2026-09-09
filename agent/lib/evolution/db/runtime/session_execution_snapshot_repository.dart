import '../../models/session_execution_snapshot.dart';
import '../agent_state_database.dart';

/// Sole SQL owner of `session_execution_snapshots`.
class SessionExecutionSnapshotRepository {
  final AgentStateDatabase _state;

  SessionExecutionSnapshotRepository(this._state);

  SessionExecutionSnapshot getSnapshot(String sessionId) {
    return findPersistedSnapshot(sessionId) ??
        SessionExecutionSnapshot.virtualIdle(sessionId);
  }

  SessionExecutionSnapshot? findPersistedSnapshot(String sessionId) {
    final rows = _state.db.select(
      'SELECT * FROM session_execution_snapshots WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    return SessionExecutionSnapshot.fromRow(rows.first);
  }

  Map<String, SessionExecutionSnapshot> findSnapshots(
    Iterable<String> sessionIds,
  ) {
    final ids = sessionIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _state.db.select(
      'SELECT * FROM session_execution_snapshots '
      'WHERE session_id IN ($placeholders)',
      ids,
    );
    final persisted = {
      for (final row in rows)
        (row['session_id']! as String): SessionExecutionSnapshot.fromRow(row),
    };
    return {
      for (final id in ids)
        id: persisted[id] ?? SessionExecutionSnapshot.virtualIdle(id),
    };
  }

  SessionExecutionSnapshotChange updateSnapshot({
    required String sessionId,
    required SessionExecutionState state,
    String? workItemId,
    String? requestId,
    AgentStateTransaction? transaction,
    DateTime? updatedAt,
    DateTime? turnStartedAt,
  }) {
    if (transaction != null) {
      return _updateInTransaction(
        transaction,
        sessionId: sessionId,
        state: state,
        workItemId: workItemId,
        requestId: requestId,
        updatedAt: updatedAt,
        turnStartedAt: turnStartedAt,
      );
    }
    return _state.transaction(
      (tx) => _updateInTransaction(
        tx,
        sessionId: sessionId,
        state: state,
        workItemId: workItemId,
        requestId: requestId,
        updatedAt: updatedAt,
        turnStartedAt: turnStartedAt,
      ),
    );
  }

  SessionExecutionSnapshotChange _updateInTransaction(
    AgentStateTransaction transaction, {
    required String sessionId,
    required SessionExecutionState state,
    required String? workItemId,
    required String? requestId,
    required DateTime? updatedAt,
    required DateTime? turnStartedAt,
  }) {
    final rows = transaction.db.select(
      'SELECT * FROM session_execution_snapshots WHERE session_id = ?',
      [sessionId],
    );
    final current = rows.isEmpty
        ? null
        : SessionExecutionSnapshot.fromRow(rows.first);
    if (current == null &&
        state == SessionExecutionState.idle &&
        workItemId == null &&
        requestId == null) {
      return SessionExecutionSnapshotChange(
        snapshot: SessionExecutionSnapshot.virtualIdle(sessionId),
        changed: false,
      );
    }
    final normalizedTurnStartedAt = turnStartedAt?.toUtc();
    if (current != null &&
        current.state == state &&
        current.workItemId == workItemId &&
        current.requestId == requestId &&
        current.turnStartedAt == normalizedTurnStartedAt) {
      return SessionExecutionSnapshotChange(snapshot: current, changed: false);
    }

    final next = SessionExecutionSnapshot(
      sessionId: sessionId,
      state: state,
      workItemId: workItemId,
      requestId: requestId,
      revision: (current?.revision ?? 0) + 1,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
      turnStartedAt: normalizedTurnStartedAt,
    );
    transaction.db.execute(
      '''
      INSERT INTO session_execution_snapshots (
        session_id, state, work_item_id, request_id, revision, updated_at,
        turn_started_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        state = excluded.state,
        work_item_id = excluded.work_item_id,
        request_id = excluded.request_id,
        revision = excluded.revision,
        updated_at = excluded.updated_at,
        turn_started_at = excluded.turn_started_at
      ''',
      [
        next.sessionId,
        next.state.name,
        next.workItemId,
        next.requestId,
        next.revision,
        next.updatedAt.toIso8601String(),
        next.turnStartedAt?.toIso8601String(),
      ],
    );
    return SessionExecutionSnapshotChange(snapshot: next, changed: true);
  }
}
