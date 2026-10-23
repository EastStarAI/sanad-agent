import 'package:sqlite3/sqlite3.dart';

import 'schema_migration_support.dart';

/// `scheduled_tasks`, its additive recurrence and lifecycle columns, and the
/// `scheduled_task_runs` history table.
///
/// `AgentStateDatabase` calls [apply] at the pinned schema position this
/// module occupied before the SRP 138-11 split. [migrateScheduledTasks] stays
/// reachable through `AgentStateDatabase.migrateScheduledTasks` for the
/// migration suites that migrate a bare legacy table.
class SchedulingSchema {
  const SchedulingSchema._();

  /// Creates both scheduling tables, migrates `scheduled_tasks`, and adds
  /// their indexes.
  static void apply(Database db) {
    // ── scheduled_tasks ───────────────────────────────────────────────────
    // Additive and rollback-safe (Tasks 112 and 139): `run_at` stays and
    // mirrors `next_run_at` on every write, and every column an older agent's
    // INSERT omits is nullable or defaulted, so an older agent on the same Home
    // keeps inserting and reading `run_at` successfully.
    //
    // The Task 139 owner, conversation, and route columns come last on
    // purpose: an existing Home receives them through `ALTER TABLE`, which
    // appends them, so a fresh database and a migrated one keep the same
    // trailing column order.
    db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_tasks (
        id TEXT PRIMARY KEY,
        task TEXT NOT NULL,
        run_at TEXT,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'once',
        interval_minutes INTEGER,
        at_time TEXT,
        weekdays TEXT,
        month_day INTEGER,
        zone TEXT NOT NULL DEFAULT 'local',
        next_run_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT,
        last_run_at TEXT,
        last_status TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        name TEXT,
        owner_kind TEXT NOT NULL DEFAULT 'model',
        conversation_mode TEXT NOT NULL DEFAULT 'continuous',
        run_session_id TEXT,
        workspace_id TEXT,
        provider_instance_id TEXT,
        model TEXT
      );
    ''');
    migrateScheduledTasks(db);
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_next_run
      ON scheduled_tasks(next_run_at ASC);
    ''');
    applyScheduledTaskRuns(db);
  }

  /// Adds the Task 112 recurrence columns and the Task 139 owner,
  /// conversation, and route columns beside the legacy `run_at` column, and
  /// backfills the mirrored values on every open.
  static void migrateScheduledTasks(Database db) {
    if (!tableExists(db, 'scheduled_tasks')) return;

    // Never rename or drop: `run_at` is the column older agents read and
    // write. `next_run_at` is added beside it.
    safeAddColumn(db, 'ALTER TABLE scheduled_tasks ADD COLUMN run_at TEXT');
    safeAddColumn(db, 'ALTER TABLE scheduled_tasks ADD COLUMN next_run_at TEXT');

    safeAddColumn(
      db,
      "ALTER TABLE scheduled_tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'once'",
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN interval_minutes INTEGER',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN at_time TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN weekdays TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN month_day INTEGER',
    );
    safeAddColumn(
      db,
      "ALTER TABLE scheduled_tasks ADD COLUMN zone TEXT NOT NULL DEFAULT 'local'",
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN updated_at TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN last_run_at TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN last_status TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1',
    );

    // Task 139 D1. Additive and defaulted exactly like `kind` and `zone`: a
    // pre-139 row becomes model-owned with one continuous conversation and no
    // dispatch route, which is how it already behaved.
    safeAddColumn(db, 'ALTER TABLE scheduled_tasks ADD COLUMN name TEXT');
    safeAddColumn(
      db,
      "ALTER TABLE scheduled_tasks ADD COLUMN owner_kind TEXT NOT NULL DEFAULT 'model'",
    );
    safeAddColumn(
      db,
      "ALTER TABLE scheduled_tasks ADD COLUMN conversation_mode TEXT NOT NULL DEFAULT 'continuous'",
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN run_session_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN workspace_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE scheduled_tasks ADD COLUMN provider_instance_id TEXT',
    );
    safeAddColumn(db, 'ALTER TABLE scheduled_tasks ADD COLUMN model TEXT');

    // Current writes keep both columns equal, so a difference means an older
    // agent wrote `run_at` last (insert or upsert); take its value. Runs at
    // every open, after any rollback period.
    db.execute('''
      UPDATE scheduled_tasks
      SET next_run_at = run_at
      WHERE run_at IS NOT NULL AND TRIM(run_at) <> ''
        AND (next_run_at IS NULL OR next_run_at <> run_at);
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET run_at = next_run_at
      WHERE (run_at IS NULL OR TRIM(run_at) = '') AND next_run_at IS NOT NULL;
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET kind = 'once'
      WHERE kind IS NULL OR TRIM(kind) = '';
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET zone = 'local'
      WHERE zone IS NULL OR TRIM(zone) = '';
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET enabled = 1
      WHERE enabled IS NULL;
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET owner_kind = 'model'
      WHERE owner_kind IS NULL OR TRIM(owner_kind) = '';
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET conversation_mode = 'continuous'
      WHERE conversation_mode IS NULL OR TRIM(conversation_mode) = '';
    ''');
    db.execute('''
      UPDATE scheduled_tasks
      SET updated_at = created_at
      WHERE updated_at IS NULL OR TRIM(updated_at) = '';
    ''');
  }

  /// Creates `scheduled_task_runs` (Task 139 A3) and its
  /// `(schedule_id, run_at DESC)` index.
  ///
  /// Additive for an existing Home: the table appears on the next open, no
  /// `scheduled_tasks` row changes, and an older agent that never reads it
  /// keeps working on the same Home.
  static void applyScheduledTaskRuns(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_task_runs (
        id TEXT PRIMARY KEY,
        schedule_id TEXT NOT NULL,
        run_at TEXT NOT NULL,
        status TEXT NOT NULL,
        trigger TEXT NOT NULL,
        duration_ms INTEGER,
        error TEXT,
        session_id TEXT,
        message_id TEXT,
        created_at TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_schedule_run_at
      ON scheduled_task_runs(schedule_id, run_at DESC);
    ''');
  }
}
