import 'package:sqlite3/sqlite3.dart';

import 'schema_migration_support.dart';

/// Durable run state: suspended work, queued input, runtime notices, work
/// items, pending steers, stop-recovery outcomes, execution snapshots, and the
/// route-transition audit.
///
/// `AgentStateDatabase` calls [applySuspendedCheckpoints] and later [apply] at
/// the pinned positions this module occupied before the SRP 138-11 split. The
/// two entry points exist because the Plan 29 provider tables are created
/// between them today; neither may be reordered.
class RuntimeWorkSchema {
  const RuntimeWorkSchema._();

  /// Creates `suspended_checkpoints` and adds its decision column.
  static void applySuspendedCheckpoints(Database db) {
    // ── suspended_checkpoints ─────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS suspended_checkpoints (
        checkpoint_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        request_id TEXT NOT NULL UNIQUE,
        tool_call_id TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        status TEXT NOT NULL,
        tool_arguments TEXT NOT NULL,
        permission_payload TEXT NOT NULL,
        resolved_decision TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    safeAddColumn(
      db,
      'ALTER TABLE suspended_checkpoints ADD COLUMN resolved_decision TEXT',
    );
  }

  /// Creates the persisted runtime-state, work-item, steer, and execution-state
  /// tables with their additive columns and indexes.
  static void apply(Database db) {
    // ── Persisted Runtime State (post-Plan 30) ───────────────────────────
    // Mirrors the in-memory `_suspendedEvents`, `_pendingEvents`, and active
    // `RuntimeNotice` maps of `SessionRunOrchestrator`/`RuntimeRecoveryService`
    // so that restarting the daemon restores suspended work, queued messages,
    // and the runtime notice banner across reconnects.
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_suspended_runs (
        session_id TEXT PRIMARY KEY,
        request_id TEXT,
        run_id TEXT,
        message TEXT,
        event_metadata TEXT NOT NULL DEFAULT '{}',
        workspace_id TEXT,
        provider_instance_id TEXT,
        model_id TEXT,
        thinking_mode TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_pending_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        request_id TEXT,
        message TEXT,
        event_metadata TEXT NOT NULL DEFAULT '{}',
        workspace_id TEXT,
        provider_instance_id TEXT,
        model_id TEXT,
        thinking_mode TEXT,
        run_id TEXT,
        event_type TEXT NOT NULL DEFAULT 'message',
        seq INTEGER NOT NULL,
        created_at TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_pending_runs_session
      ON session_pending_runs(session_id, seq);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_runtime_notices (
        session_id TEXT PRIMARY KEY,
        request_id TEXT,
        run_id TEXT,
        status TEXT NOT NULL,
        reason TEXT NOT NULL,
        severity TEXT NOT NULL DEFAULT 'warning',
        title TEXT NOT NULL,
        message TEXT NOT NULL,
        provider_instance_id TEXT,
        provider_display_name TEXT,
        retry_after_ms INTEGER,
        resume_at TEXT,
        limit_rpm INTEGER,
        actions TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');

    // ── session_work_items (Gate C.1) ─────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_work_items (
        work_item_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        request_id TEXT,
        sequence INTEGER NOT NULL,
        provider_instance_id TEXT,
        model_id TEXT,
        workspace_id TEXT,
        payload_json TEXT NOT NULL DEFAULT '{}',
        attempt INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'waiting', 'blocked', 'resuming', 'completed', 'cancelled')),
        continuation_metadata TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE,
        UNIQUE (session_id, request_id)
      );
    ''');

    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_work_items_seq
      ON session_work_items(session_id, sequence);
    ''');

    // Enforce at most ONE active (non-terminal) work item per session (Gate C.1)
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_session_active_work_item
      ON session_work_items(session_id)
      WHERE state IN ('running', 'resuming', 'waiting', 'blocked');
    ''');

    // ── Task 36: durable pending steer lifecycle ────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_pending_steers (
        session_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        generation INTEGER NOT NULL,
        text TEXT NOT NULL,
        received_at TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('pending', 'delivering', 'delivered', 'cancelled', 'recovered')),
        revision INTEGER NOT NULL CHECK (revision > 0),
        updated_at TEXT NOT NULL,
        PRIMARY KEY (session_id, request_id),
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
      );
    ''');
    safeAddColumn(
      db,
      'ALTER TABLE session_pending_steers ADD COLUMN message_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_pending_steers ADD COLUMN turn_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_pending_steers ADD COLUMN anchor_message_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_pending_steers ADD COLUMN anchor_tool_call_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_pending_steers ADD COLUMN history_revision INTEGER',
    );
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_pending_steers_active
      ON session_pending_steers(session_id, state, received_at);
    ''');

    // Stop recovery remains durable until the initiating client confirms
    // that it persisted the recovered input into its session draft.
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_stop_recovery_outcomes (
        stop_request_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        items_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        acknowledged_at TEXT,
        recovery_reason TEXT NOT NULL DEFAULT 'user_stop',
        claim_required INTEGER NOT NULL DEFAULT 0,
        claimed_by TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
      );
    ''');
    safeAddColumn(
      db,
      "ALTER TABLE session_stop_recovery_outcomes ADD COLUMN recovery_reason TEXT NOT NULL DEFAULT 'user_stop'",
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_stop_recovery_outcomes ADD COLUMN claim_required INTEGER NOT NULL DEFAULT 0',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_stop_recovery_outcomes ADD COLUMN claimed_by TEXT',
    );
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_stop_recovery_unacknowledged
      ON session_stop_recovery_outcomes(session_id, created_at)
      WHERE acknowledged_at IS NULL;
    ''');

    // ── Task 31: authoritative session execution state ───────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_execution_snapshots (
        session_id TEXT PRIMARY KEY,
        state TEXT NOT NULL CHECK (state IN ('idle', 'queued', 'running', 'waiting', 'blocked', 'resuming', 'stopping')),
        work_item_id TEXT,
        request_id TEXT,
        revision INTEGER NOT NULL CHECK (revision > 0),
        updated_at TEXT NOT NULL,
        turn_started_at TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
      );
    ''');
    safeAddColumn(
      db,
      'ALTER TABLE session_execution_snapshots ADD COLUMN turn_started_at TEXT',
    );
    db.execute('''
      UPDATE session_execution_snapshots
      SET turn_started_at = (
        SELECT created_at FROM session_work_items
        WHERE session_work_items.work_item_id = session_execution_snapshots.work_item_id
      )
      WHERE turn_started_at IS NULL AND work_item_id IS NOT NULL;
    ''');

    // ── Task 31: durable route transition audit ─────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS session_route_transitions (
        session_id TEXT NOT NULL,
        route_revision INTEGER NOT NULL CHECK (route_revision > 0),
        event_id TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL CHECK (source IN ('user', 'recovery', 'auto_failover')),
        previous_provider_instance_id TEXT,
        provider_instance_id TEXT NOT NULL,
        previous_provider_display_name TEXT,
        provider_display_name TEXT,
        model TEXT NOT NULL,
        reason TEXT,
        request_id TEXT,
        created_at TEXT NOT NULL,
        PRIMARY KEY (session_id, route_revision),
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
      );
    ''');
    safeAddColumn(
      db,
      'ALTER TABLE session_route_transitions '
      'ADD COLUMN previous_provider_display_name TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_route_transitions '
      'ADD COLUMN provider_display_name TEXT',
    );
    // Task 78: causal history anchor for automatic-failover notices.
    safeAddColumn(
      db,
      'ALTER TABLE session_route_transitions '
      'ADD COLUMN anchor_message_id TEXT',
    );
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_route_transitions_created
      ON session_route_transitions(session_id, created_at);
    ''');
  }
}
