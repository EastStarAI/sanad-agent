import 'package:sqlite3/sqlite3.dart';

import 'agent_state_database.dart';

/// Schema shape of `scheduled_tasks` as seen by a read-only inspection.
enum ScheduledTaskTableShape {
  /// The table does not exist (a Home that never stored a schedule).
  missing,

  /// A pre-Task-112 table that has `run_at` but no recurrence columns.
  legacy,

  /// The current Task 112 table.
  current,
}

/// Persistent storage for scheduled tasks (Task 112).
///
/// Owns every read and write of the `scheduled_tasks` table. The table schema
/// and its additive migration are owned by [AgentStateDatabase]; `run_at` is
/// a legacy mirror of `next_run_at` kept for older agents, written on every
/// save and read only by the tolerant [inspectScheduledTasks] listing. The
/// only mutation path above this repository is `CronScheduler` (single
/// writer).
///
/// Two write paths exist and they are not interchangeable:
///
/// - [saveScheduledTask] writes the recurrence and lifecycle columns of the
///   whole row and leaves the seven Task 139 columns alone on an existing row:
///   `owner_kind`, `name`, `conversation_mode`, `run_session_id`,
///   `workspace_id`, `provider_instance_id`, and `model` are **insert-only**.
///   The scheduler re-saves a schedule after every run and every state change
///   with only the legacy parameters, so a re-save must preserve them exactly.
/// - [updateScheduleSettings] is the single edit path for those six editable
///   settings; `owner_kind` has no writer after the insert.
///
/// An omitted Task 139 value on the first insert is stored as its column
/// default (`model`-owned, one continuous conversation, no route), exactly
/// like an omitted `kind` or `zone`.
class ScheduledTaskRepository {
  final AgentStateDatabase _state;

  ScheduledTaskRepository(this._state);

  /// Sentinel distinguishing "parameter omitted" from "clear this column" in
  /// [updateScheduleSettings].
  ///
  /// Public so that a delegating facade can forward the same default; callers
  /// never pass it explicitly.
  static const Object unset = Object();

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
    String? name,
    String ownerKind = 'model',
    String conversationMode = 'continuous',
    String? runSessionId,
    String? workspaceId,
    String? providerInstanceId,
    String? model,
  }) {
    final now = DateTime.now();
    final nextRunAtValue = _normalizeDateTime(nextRunAt);
    // The Task 139 columns appear in the INSERT and never in the ON CONFLICT
    // update list: a re-save keeps them byte-for-byte, and `owner_kind` is
    // written once at insert so no save can turn a user-owned schedule back
    // into a model-owned one (Task 139 D5). `updateScheduleSettings` is the
    // only writer after that.
    final stmt = _db.prepare('''
      INSERT INTO scheduled_tasks (
        id, task, session_id, kind, interval_minutes, at_time,
        weekdays, month_day, zone, next_run_at, run_at, created_at,
        updated_at, last_run_at, last_status, enabled, name, owner_kind,
        conversation_mode, run_session_id, workspace_id,
        provider_instance_id, model
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        name,
        ownerKind,
        conversationMode,
        runSessionId,
        workspaceId,
        providerInstanceId,
        model,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  /// Updates the editable settings of an existing schedule (Task 139).
  ///
  /// Only the parameters that are *passed* change: an omitted parameter keeps
  /// its stored value, and an explicit `null` clears the column. The
  /// omit-versus-clear distinction uses the same `Object?` sentinel convention
  /// as `AgentTurnRequest.copyWith`.
  ///
  /// This is the single edit path for the six settings. `owner_kind` is not
  /// among them and has no writer here: it is fixed at insert (D5), so no
  /// update can turn a user-owned schedule into a model-owned one or the
  /// reverse. Callers validate values before calling; this method stores what
  /// it is given.
  ///
  /// Returns whether a row matched [id]; a call with no parameters writes
  /// nothing (and therefore does not bump `updated_at`). Every real update
  /// bumps `updated_at`.
  bool updateScheduleSettings(
    String id, {
    Object? name = unset,
    Object? conversationMode = unset,
    Object? runSessionId = unset,
    Object? workspaceId = unset,
    Object? providerInstanceId = unset,
    Object? model = unset,
  }) {
    final assignments = <String>[];
    final parameters = <Object?>[];
    void apply(String column, Object? value) {
      if (identical(value, unset)) return;
      if (value != null && value is! String) {
        throw ArgumentError.value(value, column, 'must be a String or null');
      }
      assignments.add('$column = ?');
      parameters.add(value);
    }

    apply('name', name);
    apply('conversation_mode', conversationMode);
    apply('run_session_id', runSessionId);
    apply('workspace_id', workspaceId);
    apply('provider_instance_id', providerInstanceId);
    apply('model', model);

    if (assignments.isEmpty) return false;
    assignments.add('updated_at = ?');
    parameters
      ..add(_normalizeDateTime(DateTime.now()))
      ..add(id);

    _db.execute(
      'UPDATE scheduled_tasks SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return _db.updatedRows > 0;
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

  /// Read-only listing for inspection surfaces (`sanad schedule list`) that
  /// may run against a Home the current agent has not migrated.
  ///
  /// Issues SELECT/PRAGMA only. A missing table yields
  /// [ScheduledTaskTableShape.missing]; a pre-Task-112 table (no `next_run_at`)
  /// yields [ScheduledTaskTableShape.legacy] with absent columns read as null.
  /// The effective next run follows the migration precedence: a non-blank
  /// `run_at` wins (an older agent may have written it last), else
  /// `next_run_at`.
  ({ScheduledTaskTableShape shape, List<Map<String, dynamic>> rows})
  inspectScheduledTasks() {
    final columns = _db
        .select("PRAGMA table_info('scheduled_tasks')")
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.isEmpty) {
      return (shape: ScheduledTaskTableShape.missing, rows: const []);
    }
    final hasNext = columns.contains('next_run_at');
    final hasRunAt = columns.contains('run_at');
    final nextExpr = switch ((hasRunAt, hasNext)) {
      (true, true) => "COALESCE(NULLIF(TRIM(run_at), ''), next_run_at)",
      (true, false) => 'run_at',
      (false, true) => 'next_run_at',
      (false, false) => 'NULL',
    };
    final result = _db.select(
      'SELECT *, $nextExpr AS effective_next_run_at FROM scheduled_tasks '
      'ORDER BY effective_next_run_at ASC, id ASC',
    );
    return (
      shape: hasNext
          ? ScheduledTaskTableShape.current
          : ScheduledTaskTableShape.legacy,
      rows: [
        for (final row in result)
          {..._rowToMap(row), 'next_run_at': row['effective_next_run_at']},
      ],
    );
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
    // Task 139 columns. A pre-139 table reaches this decoder without them
    // (read-only inspection never migrates), and a missing column reads as
    // null, which is the "old row" default the record expects.
    'name': row['name'],
    'owner_kind': row['owner_kind'],
    'conversation_mode': row['conversation_mode'],
    'run_session_id': row['run_session_id'],
    'workspace_id': row['workspace_id'],
    'provider_instance_id': row['provider_instance_id'],
    'model': row['model'],
  };

  static String _normalizeDateTime(DateTime value) =>
      value.toUtc().toIso8601String();
}
