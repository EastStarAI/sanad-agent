import 'package:sqlite3/sqlite3.dart';

import 'agent_state_database.dart';

/// Persistent storage for scheduled tasks.
class ScheduledTaskRepository {
  final AgentStateDatabase _state;

  ScheduledTaskRepository(this._state);

  Database get _db => _state.db;

  void saveScheduledTask(
    String id,
    String task,
    DateTime runAt,
    String sessionId,
  ) {
    final stmt = _db.prepare('''
      INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        task = excluded.task,
        run_at = excluded.run_at,
        session_id = excluded.session_id;
    ''');
    stmt.execute([
      id,
      task,
      _normalizeDateTime(runAt),
      sessionId,
      _normalizeDateTime(DateTime.now()),
    ]);
    stmt.dispose();
  }

  List<Map<String, dynamic>> getAllScheduledTasks() {
    final result = _db.select(
      'SELECT * FROM scheduled_tasks ORDER BY run_at ASC',
    );
    return result
        .map(
          (row) => {
            'id': row['id'],
            'task': row['task'],
            'run_at': row['run_at'],
            'session_id': row['session_id'],
          },
        )
        .toList();
  }

  void deleteScheduledTask(String id) {
    _db.execute('DELETE FROM scheduled_tasks WHERE id = ?', [id]);
  }

  static String _normalizeDateTime(DateTime value) =>
      value.toUtc().toIso8601String();
}
