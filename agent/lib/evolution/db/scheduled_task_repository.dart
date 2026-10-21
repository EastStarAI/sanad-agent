import 'package:sqlite3/sqlite3.dart';

import 'agent_state_database.dart';

/// Persistent storage for scheduled tasks (Task 112).
///
/// Owns every read and write of the `scheduled_tasks` table. The table schema
/// and its additive migration are owned by [AgentStateDatabase]; `run_at` is
/// a legacy mirror of `next_run_at` kept for older agents, written on every
/// save and never read here. The only
/// mutation path above this repository is `CronScheduler` (single writer).
class ScheduledTaskRepository {
  final AgentStateDatabase _state;

  ScheduledTaskRepository(this._state);

  Database get _db => _state.db;

  void saveScheduledTask(
    String id,
    String task,
    DateTime nextRunAt,
    String sessionId, {
    String kind = 'once',
    int? intervalMinutes,
    String? atTime,
    String? weekdays,
    int? monthDay,
    String zone = 'local',
    DateTime? updatedAt,
    DateTime? lastRunAt,
    String? lastStatus,
    bool enabled = true,
  }) {
    final now = DateTime.now();
    final nextRunAtValue = _normalizeDateTime(nextRunAt);
    final stmt = _db.prepare('''
      INSERT INTO scheduled_tasks (
        id, task, session_id, kind, interval_minutes, at_time,
        weekdays, month_day, zone, next_run_at, run_at, created_at,
        updated_at, last_run_at, last_status, enabled
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        task = excluded.task,
        session_id = excluded.session_id,
        kind = excluded.kind,
        interval_minutes = excluded.interval_minutes,
        at_time = excluded.at_time,
        weekdays = excluded.weekdays,
        month_day = excluded.month_day,
        zone = excluded.zone,
        next_run_at = excluded.next_run_at,
        run_at = excluded.run_at,
        updated_at = excluded.updated_at,
        last_run_at = excluded.last_run_at,
        last_status = excluded.last_status,
        enabled = excluded.enabled;
    ''');
    try {
      stmt.execute([
        id,
        task,
        sessionId,
        kind,
        intervalMinutes,
        atTime,
        weekdays,
        monthDay,
        zone,
        nextRunAtValue,
        // Mirror for older agents sharing this Home (rollback safety); on an
        // old table `run_at` is still NOT NULL, so it is always written.
        nextRunAtValue,
        _normalizeDateTime(now),
        _normalizeDateTime(updatedAt ?? now),
        lastRunAt != null ? _normalizeDateTime(lastRunAt) : null,
        lastStatus,
        enabled ? 1 : 0,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  Map<String, dynamic>? getScheduledTask(String id) {
    final result = _db.select(
      'SELECT * FROM scheduled_tasks WHERE id = ? LIMIT 1',
      [id],
    );
    if (result.isEmpty) return null;
    return _rowToMap(result.first);
  }

  List<Map<String, dynamic>> getAllScheduledTasks() {
    final result = _db.select(
      'SELECT * FROM scheduled_tasks ORDER BY next_run_at ASC',
    );
    return result.map(_rowToMap).toList();
  }

  void deleteScheduledTask(String id) {
    _db.execute('DELETE FROM scheduled_tasks WHERE id = ?', [id]);
  }

  static Map<String, dynamic> _rowToMap(Row row) => {
    'id': row['id'],
    'task': row['task'],
    'session_id': row['session_id'],
    'kind': row['kind'],
    'interval_minutes': row['interval_minutes'],
    'at_time': row['at_time'],
    'weekdays': row['weekdays'],
    'month_day': row['month_day'],
    'zone': row['zone'],
    'next_run_at': row['next_run_at'],
    'created_at': row['created_at'],
    'updated_at': row['updated_at'],
    'last_run_at': row['last_run_at'],
    'last_status': row['last_status'],
    'enabled': row['enabled'],
  };

  static String _normalizeDateTime(DateTime value) =>
      value.toUtc().toIso8601String();
}
