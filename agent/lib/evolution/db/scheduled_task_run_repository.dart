import 'package:sqlite3/sqlite3.dart';

import '../scheduling/scheduled_task_record.dart';
import 'agent_state_database.dart';

/// Lifecycle of one schedule run (Task 139 D9).
///
/// A run row is written as [running] when dispatch is accepted and reaches
/// exactly one terminal state: [succeeded], [failed], or [skipped] for a
/// missed occurrence that never ran.
enum ScheduledTaskRunStatus {
  running,
  succeeded,
  failed,
  skipped;

  /// The value stored in `scheduled_task_runs.status` and sent on the wire.
  String get wireName => name;

  /// Whether this status ends the run. A terminal row is never rewritten.
  bool get isTerminal => this != running;

  /// Parses a stored value.
  ///
  /// An unrecognized terminal value fails closed to [failed]: history must
  /// never present an unknown outcome as in-flight or as a success.
  static ScheduledTaskRunStatus fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final status in values) {
      if (status.wireName == normalized) return status;
    }
    return failed;
  }
}

/// What caused a run (Task 139 A3).
enum ScheduledTaskRunTrigger {
  /// The schedule's own timer or its in-grace startup recovery.
  scheduled,

  /// Run now, including on a paused schedule (S21).
  manual,

  /// An in-grace recovery dispatch after a restart.
  recovery;

  /// The value stored in `scheduled_task_runs.trigger` and sent on the wire.
  String get wireName => name;

  /// Parses a stored value; an unrecognized value keeps [scheduled], so no
  /// history row is presented as a manual action it never was.
  static ScheduledTaskRunTrigger fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final trigger in values) {
      if (trigger.wireName == normalized) return trigger;
    }
    return scheduled;
  }
}

/// Retention bound for `scheduled_task_runs` (Task 139 D2).
///
/// Pruning happens on write, never on read, so a history page is always a
/// faithful slice of what was retained.
abstract final class ScheduledTaskRunRetention {
  /// Newest rows kept per schedule.
  static const int maxRunsPerSchedule = 200;

  /// Nothing older than this survives a prune.
  static const Duration maxAge = Duration(days: 90);
}

/// One row of `scheduled_task_runs` (Task 139 A3).
class ScheduledTaskRun {
  final String id;
  final String scheduleId;

  /// ISO-8601 UTC instant of the attempt.
  final DateTime runAt;
  final ScheduledTaskRunStatus status;
  final ScheduledTaskRunTrigger trigger;

  /// Dispatch acceptance to terminal state; `null` while running.
  final int? durationMs;

  /// Bounded, already redacted failure text. Never command output (S16).
  final String? error;

  /// The conversation the run appended to.
  final String? sessionId;

  /// Identity of the run's user message, written when that message commits.
  final String? messageId;
  final DateTime createdAt;

  const ScheduledTaskRun({
    required this.id,
    required this.scheduleId,
    required this.runAt,
    required this.status,
    required this.trigger,
    this.durationMs,
    this.error,
    this.sessionId,
    this.messageId,
    required this.createdAt,
  });

  /// Whether the Client can open this run's position inside its conversation
  /// (S9, S20).
  bool get hasPosition => messageId != null;

  Map<String, dynamic> toMap() => {
        'id': id,
        'schedule_id': scheduleId,
        'run_at': runAt.toUtc().toIso8601String(),
        'status': status.wireName,
        'trigger': trigger.wireName,
        'duration_ms': durationMs,
        'error': error,
        'session_id': sessionId,
        'message_id': messageId,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory ScheduledTaskRun.fromRow(Map<String, dynamic> row) {
    final rawRunAt = row['run_at']?.toString();
    if (rawRunAt == null) {
      throw const FormatException('scheduled_task_runs.run_at is required');
    }
    final rawCreatedAt = row['created_at']?.toString();
    return ScheduledTaskRun(
      id: row['id'] as String,
      scheduleId: row['schedule_id'] as String,
      runAt: DateTime.parse(rawRunAt).toUtc(),
      status: ScheduledTaskRunStatus.fromWire(row['status']),
      trigger: ScheduledTaskRunTrigger.fromWire(row['trigger']),
      durationMs: row['duration_ms'] as int?,
      error: blankToNull(row['error']),
      sessionId: blankToNull(row['session_id']),
      messageId: blankToNull(row['message_id']),
      createdAt: rawCreatedAt == null
          ? DateTime.parse(rawRunAt).toUtc()
          : DateTime.parse(rawCreatedAt).toUtc(),
    );
  }
}

/// Persistent storage for `scheduled_task_runs` (Task 139 A3).
///
/// Owns every read and write of the runs table; the table schema is owned by
/// `schema/scheduling_schema.dart`. The only mutation path above this
/// repository is `CronScheduler` and the owners it delegates to (single
/// writer, 112a D7), so a protocol handler or tool never writes a run row.
///
/// Callers store an already bounded and redacted [ScheduledTaskRun.error];
/// this repository persists what it is given and never redacts.
class ScheduledTaskRunRepository {
  final AgentStateDatabase _state;

  ScheduledTaskRunRepository(this._state);

  Database get _db => _state.db;

  /// Writes the `running` row that must exist before a dispatch event leaves
  /// the scheduler (A3, at-most-once B-D1), and returns its identity.
  ///
  /// [id] exists for deterministic tests; production mints
  /// `run_<microseconds>`.
  String startRun({
    String? id,
    required String scheduleId,
    required DateTime runAt,
    required ScheduledTaskRunTrigger trigger,
    DateTime? createdAt,
  }) {
    final now = createdAt ?? DateTime.now();
    final runId = id ?? 'run_${now.microsecondsSinceEpoch}';
    final runAtValue = _normalizeDateTime(runAt);
    final stmt = _db.prepare('''
      INSERT INTO scheduled_task_runs (
        id, schedule_id, run_at, status, trigger, duration_ms, error,
        session_id, message_id, created_at
      )
      VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?);
    ''');
    try {
      stmt.execute([
        runId,
        scheduleId,
        runAtValue,
        ScheduledTaskRunStatus.running.wireName,
        trigger.wireName,
        _normalizeDateTime(now),
      ]);
    } finally {
      stmt.dispose();
    }
    return runId;
  }

  /// Anchors a run on its user message (S9, S20).
  ///
  /// Called by the owner that commits the run's user message, so no
  /// scheduler-side correlation is needed. Returns whether the row existed.
  bool attachMessage(
    String runId, {
    required String sessionId,
    required String messageId,
  }) {
    _db.execute(
      'UPDATE scheduled_task_runs SET session_id = ?, message_id = ? '
      'WHERE id = ?',
      [sessionId, messageId, runId],
    );
    return _db.updatedRows > 0;
  }

  /// Moves a running row to its one terminal state (D9).
  ///
  /// The transition is a compare-and-set: a second observation of the same
  /// run changes nothing and returns `false`, so a run can never be
  /// double-terminal. [status] must be terminal.
  bool completeRun(
    String runId, {
    required ScheduledTaskRunStatus status,
    int? durationMs,
    String? error,
  }) {
    if (!status.isTerminal) {
      throw ArgumentError.value(
        status,
        'status',
        'completeRun requires a terminal status',
      );
    }
    _db.execute(
      'UPDATE scheduled_task_runs '
      'SET status = ?, duration_ms = ?, error = ? '
      "WHERE id = ? AND status = 'running'",
      [status.wireName, durationMs, error, runId],
    );
    return _db.updatedRows > 0;
  }

  ScheduledTaskRun? getRun(String id) {
    final result = _db.select(
      'SELECT * FROM scheduled_task_runs WHERE id = ? LIMIT 1',
      [id],
    );
    if (result.isEmpty) return null;
    return ScheduledTaskRun.fromRow(Map<String, dynamic>.from(result.first));
  }

  /// One newest-first page of a schedule's runs, for `schedule.runs`.
  ///
  /// Pagination is a keyset on `(run_at DESC, id DESC)`: pass the last row's
  /// [ScheduledTaskRun.runAt] and [ScheduledTaskRun.id] as [before] and
  /// [beforeId] to continue. [limit] is clamped to the retention bound, and
  /// reading never prunes.
  ({List<ScheduledTaskRun> runs, bool hasMore}) listRuns(
    String scheduleId, {
    int limit = 50,
    DateTime? before,
    String? beforeId,
  }) {
    final effectiveLimit = limit.clamp(1, ScheduledTaskRunRetention.maxRunsPerSchedule);
    final sql = StringBuffer(
      'SELECT * FROM scheduled_task_runs WHERE schedule_id = ?',
    );
    final parameters = <Object?>[scheduleId];
    if (before != null) {
      final beforeValue = _normalizeDateTime(before);
      if (beforeId == null) {
        sql.write(' AND run_at < ?');
        parameters.add(beforeValue);
      } else {
        sql.write(' AND (run_at < ? OR (run_at = ? AND id < ?))');
        parameters.addAll([beforeValue, beforeValue, beforeId]);
      }
    }
    sql.write(' ORDER BY run_at DESC, id DESC LIMIT ?');
    parameters.add(effectiveLimit + 1);

    final rows = _db.select(sql.toString(), parameters);
    final hasMore = rows.length > effectiveLimit;
    return (
      runs: [
        for (final row in rows.take(effectiveLimit))
          ScheduledTaskRun.fromRow(Map<String, dynamic>.from(row)),
      ],
      hasMore: hasMore,
    );
  }

  int countRuns(String scheduleId) => _db
          .select(
            'SELECT COUNT(*) AS total FROM scheduled_task_runs '
            'WHERE schedule_id = ?',
            [scheduleId],
          )
          .single['total']
      as int;

  /// Applies the [ScheduledTaskRunRetention] bound and returns how many rows
  /// were removed.
  ///
  /// The recorder calls this on write, never on read (D2).
  int pruneRetainedRuns(String scheduleId, {DateTime? now}) {
    final cutoff = _normalizeDateTime(
      (now ?? DateTime.now()).toUtc().subtract(ScheduledTaskRunRetention.maxAge),
    );
    _db.execute(
      'DELETE FROM scheduled_task_runs '
      'WHERE schedule_id = ? '
      'AND (run_at < ? OR id NOT IN ('
      'SELECT id FROM scheduled_task_runs WHERE schedule_id = ? '
      'ORDER BY run_at DESC, id DESC LIMIT ?))',
      [scheduleId, cutoff, scheduleId, ScheduledTaskRunRetention.maxRunsPerSchedule],
    );
    return _db.updatedRows;
  }

  /// Deletes a schedule's run rows and returns how many were removed.
  ///
  /// Deleting a schedule deletes its runs in the same transaction and touches
  /// no session or message (D7, S10).
  int deleteRunsForSchedule(String scheduleId) {
    _db.execute(
      'DELETE FROM scheduled_task_runs WHERE schedule_id = ?',
      [scheduleId],
    );
    return _db.updatedRows;
  }

  static String _normalizeDateTime(DateTime value) =>
      value.toUtc().toIso8601String();
}
