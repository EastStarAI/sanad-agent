import 'package:sqlite3/sqlite3.dart';

import '../models/suspended_checkpoint.dart';
import 'agent_state_database.dart';

/// Persistent storage for suspended checkpoints and work-item state.
class SuspendedCheckpointRepository {
  final AgentStateDatabase _state;

  SuspendedCheckpointRepository(this._state);

  Database get _db => _state.db;

  void saveSuspendedCheckpoint(SuspendedCheckpoint checkpoint) {
    final row = checkpoint.toRow();
    final stmt = _db.prepare('''
      INSERT INTO suspended_checkpoints (
        checkpoint_id,
        session_id,
        request_id,
        tool_call_id,
        tool_name,
        status,
        tool_arguments,
        permission_payload,
        resolved_decision,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(request_id) DO UPDATE SET
        checkpoint_id = excluded.checkpoint_id,
        session_id = excluded.session_id,
        tool_call_id = excluded.tool_call_id,
        tool_name = excluded.tool_name,
        status = excluded.status,
        tool_arguments = excluded.tool_arguments,
        permission_payload = excluded.permission_payload,
        resolved_decision = excluded.resolved_decision,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([
      row['checkpoint_id'],
      row['session_id'],
      row['request_id'],
      row['tool_call_id'],
      row['tool_name'],
      row['status'],
      row['tool_arguments'],
      row['permission_payload'],
      row['resolved_decision'],
      row['created_at'],
      row['updated_at'],
    ]);
    stmt.dispose();
  }

  SuspendedCheckpoint? getSuspendedCheckpointByRequestId(String requestId) {
    final result = _db.select(
      'SELECT * FROM suspended_checkpoints WHERE request_id = ? LIMIT 1',
      [requestId],
    );
    if (result.isEmpty) {
      return null;
    }
    return SuspendedCheckpoint.fromRow(Map<String, Object?>.from(result.first));
  }

  List<SuspendedCheckpoint> listSuspendedCheckpoints({String? status}) {
    final result = status == null
        ? _db.select(
            'SELECT * FROM suspended_checkpoints ORDER BY created_at ASC',
          )
        : _db.select(
            'SELECT * FROM suspended_checkpoints WHERE status = ? ORDER BY created_at ASC',
            [status],
          );
    return result
        .map(
          (row) => SuspendedCheckpoint.fromRow(Map<String, Object?>.from(row)),
        )
        .toList(growable: false);
  }

  void updateSuspendedCheckpointStatus({
    required String requestId,
    required String status,
  }) {
    _db.execute(
      'UPDATE suspended_checkpoints SET status = ?, updated_at = ? WHERE request_id = ?',
      [status, DateTime.now().toIso8601String(), requestId],
    );
  }

  bool claimSuspendedCheckpointDecision({
    required String requestId,
    required String status,
  }) {
    _db.execute(
      '''
      UPDATE suspended_checkpoints
      SET status = ?, updated_at = ?
      WHERE request_id = ? AND status = 'awaiting_permission'
      ''',
      [status, DateTime.now().toIso8601String(), requestId],
    );
    return _db.updatedRows == 1;
  }

  void deleteSuspendedCheckpointByRequestId(String requestId) {
    _db.execute('DELETE FROM suspended_checkpoints WHERE request_id = ?', [
      requestId,
    ]);
  }

  void deleteSuspendedCheckpointByToolCallId(String toolCallId) {
    _db.execute('DELETE FROM suspended_checkpoints WHERE tool_call_id = ?', [
      toolCallId,
    ]);
  }

  /// Deletes every checkpoint of [sessionId].
  ///
  /// An explicit Stop terminalizes the session's interactive waits, so a
  /// leftover `awaiting_permission` row must not outlive it: the history
  /// projection would keep reporting `pending_permission_request` for a
  /// session that is already stopped.
  void deleteSuspendedCheckpointsForSession(String sessionId) {
    _db.execute('DELETE FROM suspended_checkpoints WHERE session_id = ?', [
      sessionId,
    ]);
  }
}
