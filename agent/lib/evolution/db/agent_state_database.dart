import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/sanad_home/sanad_home_bootstrap.dart';
import 'message_history_identity.dart';
import 'session_lineage.dart';

/// Single owner of the agent's local SQLite connection (`state.db`).
///
/// Both [`SessionDB`](session_db.dart) and
/// [`ProviderInstanceRepository`](../../core/provider_runtime/provider_instance_repository.dart)
/// consume this shared connection so the runtime never opens `state.db` twice.
/// It enables `PRAGMA foreign_keys = ON` (required for `ON DELETE CASCADE`) and
/// owns the schema for every table — sessions, messages, scheduled tasks,
/// suspended checkpoints, and the Plan 29 provider instance/cache/recent tables.
///
/// Secrets NEVER live here: API keys and OAuth tokens are stored only in the
/// `SecretStore` (`provider_secrets.json`).
class AgentStateDatabase {
  late final Database _db;
  bool _owned = false;
  int _transactionDepth = 0;

  static bool _sqliteOverrideInitialized = false;

  /// Ensures that on Linux, the sqlite3 dynamic library is overridden to use
  /// the system runtime library `libsqlite3.so.0`, bypassing the requirement
  /// of the development package (`libsqlite3-dev`).
  static void ensureSqliteOverride() {
    if (_sqliteOverrideInitialized) return;
    _sqliteOverrideInitialized = true;
    if (Platform.isLinux) {
      try {
        open.overrideFor(OperatingSystem.linux, () {
          return DynamicLibrary.open('libsqlite3.so.0');
        });
      } catch (e) {
        stderr.writeln(
          'Warning: Failed to override sqlite3 dynamic library: $e',
        );
      }
    }
  }

  /// Opens (or creates) `state.db` under [getSanadStateHome] and initializes the
  /// full schema. This is the single production connection.
  AgentStateDatabase() {
    _rejectUnisolatedTestOpen();
    _openAtPath(getSanadStateHome());
  }

  static void _rejectUnisolatedTestOpen() {
    if (!_isDartTestRuntime() || hasExplicitSanadStateIsolation()) return;
    throw StateError(
      'Refusing to open the inherited Sanad state database from a Dart test. '
      'Inject AgentStateDatabase.inMemory(), use AgentStateDatabase.atPath(), '
      'or select a temporary state root with setSanadHomeOverride(), '
      'setSanadStateHomeOverride(), or SANAD_STATE_HOME.',
    );
  }

  static bool _isDartTestRuntime() {
    if (Zone.current[#test.invoker] != null) return true;
    // Suite-level initializers run before the test invoker Zone exists. The VM
    // runner executes those initializers from its generated dart_test kernel.
    final script = Platform.script.toString();
    return script.contains('dart_test.kernel.') && script.endsWith('.dill');
  }

  /// Opens (or creates) `state.db` under an explicit runtime-state directory.
  /// Used by standalone helpers/tests that must not fall back to the global
  /// SANAD_STATE_HOME when a custom sanad home was provided.
  AgentStateDatabase.atPath(String stateHomePath) {
    _openAtPath(stateHomePath);
  }

  /// Opens an in-memory database. Used by tests and ephemeral runtimes.
  AgentStateDatabase.inMemory() {
    ensureSqliteOverride();
    _db = sqlite3.openInMemory();
    _owned = true;
    _init();
  }

  /// Wraps an existing connection without taking ownership (caller disposes).
  @visibleForTesting
  AgentStateDatabase.fromConnection(this._db) {
    _owned = false;
    _init();
  }

  /// Wraps an already initialized connection without owning or migrating it.
  /// Transitional facades use this only for backward-compatible constructors;
  /// production dependency injection passes the original owner directly.
  AgentStateDatabase.attached(this._db) {
    _owned = false;
  }

  /// The underlying SQLite connection, shared by all consumers.
  Database get db => _db;

  /// Runs [action] inside the single agent-state connection's write
  /// transaction and exposes a context that repositories can pass between
  /// one another without opening nested independent transactions.
  ///
  /// Nested calls use SQLite savepoints. This keeps low-level repository APIs
  /// independently usable while allowing aggregate owners to compose several
  /// repositories under one outer commit boundary.
  T transaction<T>(T Function(AgentStateTransaction transaction) action) {
    final depth = _transactionDepth;
    final savepoint = 'sanad_state_tx_$depth';
    if (depth == 0) {
      _db.execute('BEGIN IMMEDIATE TRANSACTION');
    } else {
      _db.execute('SAVEPOINT $savepoint');
    }
    _transactionDepth = depth + 1;
    try {
      final result = action(AgentStateTransaction._(_db));
      if (result is Future) {
        throw StateError(
          'AgentStateDatabase.transaction callbacks must be synchronous.',
        );
      }
      if (depth == 0) {
        _db.execute('COMMIT');
      } else {
        _db.execute('RELEASE SAVEPOINT $savepoint');
      }
      return result;
    } catch (_) {
      if (depth == 0) {
        _db.execute('ROLLBACK');
      } else {
        _db.execute('ROLLBACK TO SAVEPOINT $savepoint');
        _db.execute('RELEASE SAVEPOINT $savepoint');
      }
      rethrow;
    } finally {
      _transactionDepth = depth;
    }
  }

  void _openAtPath(String stateHomePath) {
    ensureSqliteOverride();
    // SQLite owns page/WAL/SHM writes and therefore cannot use the generic
    // atomic-file helper. SEC-02 brackets the native connection instead: root,
    // target and legacy sidecars are secured before open; newly created files
    // are secured immediately after open/schema initialization.
    final boundary = SanadHomeBootstrap.atRoot(stateHomePath);
    final dbPath = boundary.prepareDatabaseSync();
    _db = sqlite3.open(dbPath);
    _owned = true;
    _init();
    boundary.secureDatabaseFilesSync();
  }

  void _init() {
    _db.execute('PRAGMA foreign_keys = ON');
    _createSchemaAndMigrate(_db);
  }

  static void _createSchemaAndMigrate(Database db) {
    // ── sessions ──────────────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        title_status TEXT NOT NULL DEFAULT 'final'
          CHECK (title_status IN ('pending', 'final')),
        workspace_id TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_user_message_at TEXT
      );
    ''');
    // Backward-compatible migrations.
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN workspace_id TEXT');
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN metadata TEXT');
    _safeAddColumn(
      db,
      "ALTER TABLE sessions ADD COLUMN title_status TEXT NOT NULL DEFAULT 'final' CHECK (title_status IN ('pending', 'final'))",
    );
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN provider_id TEXT');
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN thinking_mode TEXT');
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN last_user_message_at TEXT',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN route_revision INTEGER NOT NULL DEFAULT 1 CHECK (route_revision > 0)',
    );
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN route_updated_at TEXT');
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN history_revision INTEGER NOT NULL DEFAULT 0',
    );
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN lineage_id TEXT');
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN parent_session_id TEXT',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN forked_from_message_id TEXT',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN forked_from_turn_id TEXT',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN fork_sequence INTEGER NOT NULL DEFAULT 0',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN lineage_base_title TEXT',
    );
    _safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN fork_request_id TEXT');
    SessionLineage.backfill(db);
    db.execute('''
      UPDATE sessions
      SET route_updated_at = updated_at
      WHERE route_updated_at IS NULL OR TRIM(route_updated_at) = '';
    ''');

    // ── messages ──────────────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        data TEXT NOT NULL,
        message_id TEXT,
        turn_id TEXT,
        history_status TEXT NOT NULL DEFAULT 'active'
          CHECK (history_status IN ('active', 'superseded')),
        superseded_by_turn_id TEXT,
        input_kind TEXT
          CHECK (input_kind IS NULL OR input_kind IN ('root_turn', 'steer')),
        request_id TEXT,
        run_id TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
      );
    ''');
    _safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN message_id TEXT');
    _safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN turn_id TEXT');
    _safeAddColumn(
      db,
      "ALTER TABLE messages ADD COLUMN history_status TEXT NOT NULL DEFAULT 'active'",
    );
    _safeAddColumn(
      db,
      'ALTER TABLE messages ADD COLUMN superseded_by_turn_id TEXT',
    );
    _safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN input_kind TEXT');
    _safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN request_id TEXT');
    _safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN run_id TEXT');
    _safeAddColumn(
      db,
      'ALTER TABLE messages ADD COLUMN origin_message_id TEXT',
    );
    _migrateLastUserMessageAt(db);
    MessageHistoryIdentity.backfill(db);
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_message_id
      ON messages(message_id);
    ''');
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_lineage_sequence
      ON sessions(lineage_id, fork_sequence);
    ''');
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_fork_request_id
      ON sessions(fork_request_id)
      WHERE fork_request_id IS NOT NULL;
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sessions_parent
      ON sessions(parent_session_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_origin
      ON messages(origin_message_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_session_active_id
      ON messages(session_id, history_status, id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_session_turn
      ON messages(session_id, turn_id, id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_session_id
      ON messages(session_id, id DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sessions_ordering
      ON sessions(last_user_message_at DESC, session_id DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sessions_workspace_ordering
      ON sessions(workspace_id, last_user_message_at DESC, session_id DESC);
    ''');

    // ── scheduled_tasks ───────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_tasks (
        id TEXT PRIMARY KEY,
        task TEXT NOT NULL,
        run_at TEXT NOT NULL,
        session_id TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
    ''');

    // ── workspaces ────────────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');

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
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');

    // ── Plan 29: provider_instances ───────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS provider_instances (
        id TEXT PRIMARY KEY,
        template_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        display_name_lower TEXT NOT NULL,
        protocol TEXT NOT NULL,
        auth_method TEXT NOT NULL,
        base_url TEXT,
        default_model TEXT,
        status TEXT NOT NULL DEFAULT 'draft',
        is_default INTEGER NOT NULL DEFAULT 0,
        config_revision INTEGER NOT NULL DEFAULT 1,
        credential_revision INTEGER NOT NULL DEFAULT 1,
        requests_per_minute INTEGER NOT NULL DEFAULT 0,
        allow_auto_failover INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    // Plan 30: add rate-limit + auto-failover columns to pre-existing tables.
    _safeAddColumn(
      db,
      'ALTER TABLE provider_instances ADD COLUMN requests_per_minute INTEGER NOT NULL DEFAULT 0',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE provider_instances ADD COLUMN allow_auto_failover INTEGER NOT NULL DEFAULT 1',
    );
    // Task 57 keeps the rate-limit schema for compatibility but makes it
    // dormant. Normalize legacy configured limits on every idempotent upgrade.
    db.execute('''
      UPDATE provider_instances
      SET requests_per_minute = 0
      WHERE requests_per_minute <> 0;
    ''');
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_instances_name_lower '
      'ON provider_instances(display_name_lower);',
    );
    // Enforce at most ONE default instance via a partial unique index on the
    // single row where is_default = 1. The DB rejects a second default even if
    // a writer bypasses setDefault().
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_single_default '
      'ON provider_instances(is_default) WHERE is_default = 1;',
    );

    // ── Plan 29: provider_model_cache ─────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS provider_model_cache (
        instance_id TEXT NOT NULL,
        cache_key TEXT NOT NULL,
        models_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'live',
        endpoint_fingerprint TEXT,
        config_revision INTEGER NOT NULL,
        credential_revision INTEGER NOT NULL,
        last_error TEXT,
        PRIMARY KEY (instance_id, cache_key),
        FOREIGN KEY (instance_id) REFERENCES provider_instances (id) ON DELETE CASCADE
      );
    ''');

    // ── Plan 29: recent_model_selections ──────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS recent_model_selections (
        instance_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        selected_at TEXT NOT NULL,
        PRIMARY KEY (instance_id, model_id),
        FOREIGN KEY (instance_id) REFERENCES provider_instances (id) ON DELETE CASCADE
      );
    ''');

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
    _safeAddColumn(
      db,
      "ALTER TABLE session_stop_recovery_outcomes ADD COLUMN recovery_reason TEXT NOT NULL DEFAULT 'user_stop'",
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_stop_recovery_outcomes ADD COLUMN claim_required INTEGER NOT NULL DEFAULT 0',
    );
    _safeAddColumn(
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
    _safeAddColumn(
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
    _safeAddColumn(
      db,
      'ALTER TABLE session_route_transitions '
      'ADD COLUMN previous_provider_display_name TEXT',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_route_transitions '
      'ADD COLUMN provider_display_name TEXT',
    );
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_route_transitions_created
      ON session_route_transitions(session_id, created_at);
    ''');
    _migrateWorkspaceIdentity(db);
    _migrateLastUserMessageAt(db);
    _migratePlan53Compaction(db);
  }

  static void _migratePlan53Compaction(Database db) {
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN history_revision INTEGER NOT NULL DEFAULT 0 CHECK (history_revision >= 0)',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN projection_revision INTEGER NOT NULL DEFAULT 0 CHECK (projection_revision >= 0)',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS session_compaction_operations (
        compaction_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        trigger TEXT NOT NULL CHECK (trigger IN ('manual', 'auto', 'overflow')),
        status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed')),
        source_history_revision INTEGER NOT NULL CHECK (source_history_revision >= 0),
        source_start_message_id INTEGER NOT NULL,
        source_end_message_id INTEGER NOT NULL,
        tail_start_message_id INTEGER NOT NULL,
        tail_end_message_id INTEGER NOT NULL,
        tail_end_anchor_fingerprint TEXT,
        tail_end_anchor_ordinal INTEGER CHECK (tail_end_anchor_ordinal > 0),
        provider_instance_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        template_id TEXT NOT NULL,
        protocol TEXT NOT NULL,
        normalized_base_url TEXT NOT NULL,
        config_revision INTEGER NOT NULL,
        credential_revision INTEGER NOT NULL,
        context_window_tokens INTEGER,
        effective_input_budget_tokens INTEGER,
        auto_threshold_tokens INTEGER,
        estimated_request_tokens_before INTEGER,
        estimated_request_tokens_after INTEGER,
        before_measurement_kind TEXT NOT NULL DEFAULT 'estimated'
          CHECK (before_measurement_kind IN ('estimated', 'confirmed', 'mixed')),
        provider_confirmed_request_tokens_after INTEGER
          CHECK (provider_confirmed_request_tokens_after >= 0),
        retained_tail_tokens INTEGER,
        duration_ms INTEGER,
        internal_summary_json TEXT,
        failure_reason TEXT,
        failure_detail_json TEXT,
        started_at TEXT NOT NULL,
        completed_at TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE,
        CHECK (source_end_message_id < tail_start_message_id)
      );
    ''');

    _safeAddColumn(
      db,
      "ALTER TABLE session_compaction_operations ADD COLUMN before_measurement_kind TEXT NOT NULL DEFAULT 'estimated' CHECK (before_measurement_kind IN ('estimated', 'confirmed', 'mixed'))",
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN effective_input_budget_tokens INTEGER CHECK (effective_input_budget_tokens > 0)',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN auto_threshold_tokens INTEGER CHECK (auto_threshold_tokens > 0)',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN provider_confirmed_request_tokens_after INTEGER CHECK (provider_confirmed_request_tokens_after >= 0)',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN tail_end_anchor_fingerprint TEXT',
    );
    _safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN tail_end_anchor_ordinal INTEGER CHECK (tail_end_anchor_ordinal > 0)',
    );

    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_session_compaction_one_started
      ON session_compaction_operations(session_id)
      WHERE status = 'started';
    ''');

    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_compaction_completed
      ON session_compaction_operations(session_id, completed_at DESC)
      WHERE status = 'completed';
    ''');
  }

  static void _migrateWorkspaceIdentity(Database db) {
    final columns = db.select('PRAGMA table_info(workspaces)');
    final columnNames = columns.map((row) => row['name']?.toString()).toSet();
    if (columnNames.contains('id')) {
      _migrateOrphanedPathWorkspaceReferences(db);
      return;
    }

    final paths = <String>{};
    final legacyRows = db.select(
      'SELECT path, source, updated_at FROM workspaces',
    );
    for (final row in legacyRows) {
      final path = row['path']?.toString().trim();
      if (path != null && path.isNotEmpty) paths.add(path);
    }

    const referenceTables = [
      'sessions',
      'session_suspended_runs',
      'session_pending_runs',
      'session_work_items',
    ];
    for (final table in referenceTables) {
      if (!_columnExists(db, table, 'workspace_id')) continue;
      for (final row in db.select(
        'SELECT DISTINCT workspace_id FROM $table '
        'WHERE workspace_id IS NOT NULL AND TRIM(workspace_id) != \'\'',
      )) {
        final path = row['workspace_id']?.toString().trim();
        if (path != null && path.isNotEmpty) paths.add(path);
      }
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final idsByPath = <String, String>{
      for (final path in paths) path: const Uuid().v4(),
    };

    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('ALTER TABLE workspaces RENAME TO workspaces_legacy');
      db.execute('''
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          path TEXT NOT NULL UNIQUE,
          source TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');

      final insert = db.prepare('''
        INSERT INTO workspaces (
          id, display_name, path, source, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''');
      for (final entry in idsByPath.entries) {
        final legacy = legacyRows.where(
          (row) => row['path']?.toString().trim() == entry.key,
        );
        final legacyRow = legacy.isEmpty ? null : legacy.first;
        final updatedAt = legacyRow?['updated_at']?.toString() ?? now;
        insert.execute([
          entry.value,
          _workspaceDisplayName(entry.key),
          entry.key,
          legacyRow?['source']?.toString() ?? 'migrated_session',
          updatedAt,
          updatedAt,
        ]);
      }
      insert.dispose();

      for (final table in referenceTables) {
        if (!_columnExists(db, table, 'workspace_id')) continue;
        final update = db.prepare(
          'UPDATE $table SET workspace_id = ? WHERE workspace_id = ?',
        );
        for (final entry in idsByPath.entries) {
          update.execute([entry.value, entry.key]);
        }
        update.dispose();
      }

      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_suspended_runs',
        idColumn: 'session_id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_pending_runs',
        idColumn: 'id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_work_items',
        idColumn: 'work_item_id',
        jsonColumn: 'payload_json',
        idsByPath: idsByPath,
      );

      db.execute('DROP TABLE workspaces_legacy');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _migrateOrphanedPathWorkspaceReferences(Database db) {
    final knownIds = db
        .select('SELECT id FROM workspaces')
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();
    const referenceTables = [
      'sessions',
      'session_suspended_runs',
      'session_pending_runs',
      'session_work_items',
    ];
    final paths = <String>{};
    for (final table in referenceTables) {
      if (!_columnExists(db, table, 'workspace_id')) continue;
      for (final row in db.select(
        'SELECT DISTINCT workspace_id FROM $table '
        'WHERE workspace_id IS NOT NULL AND TRIM(workspace_id) != \'\'',
      )) {
        final value = row['workspace_id']?.toString().trim();
        if (value != null &&
            value.isNotEmpty &&
            !knownIds.contains(value) &&
            p.isAbsolute(value)) {
          paths.add(value);
        }
      }
    }
    if (paths.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    final idsByPath = <String, String>{
      for (final path in paths) path: const Uuid().v4(),
    };
    db.execute('BEGIN IMMEDIATE');
    try {
      final insert = db.prepare('''
        INSERT INTO workspaces (
          id, display_name, path, source, created_at, updated_at
        ) VALUES (?, ?, ?, 'migrated_session', ?, ?)
        ON CONFLICT(path) DO NOTHING
      ''');
      for (final path in idsByPath.keys.toList(growable: false)) {
        insert.execute([
          idsByPath[path],
          _workspaceDisplayName(path),
          path,
          now,
          now,
        ]);
        final stored = db.select(
          'SELECT id FROM workspaces WHERE path = ? LIMIT 1',
          [path],
        );
        if (stored.isNotEmpty) {
          idsByPath[path] = stored.first['id'] as String;
        }
      }
      insert.dispose();

      for (final table in referenceTables) {
        if (!_columnExists(db, table, 'workspace_id')) continue;
        final update = db.prepare(
          'UPDATE $table SET workspace_id = ? WHERE workspace_id = ?',
        );
        for (final entry in idsByPath.entries) {
          update.execute([entry.value, entry.key]);
        }
        update.dispose();
      }
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_suspended_runs',
        idColumn: 'session_id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_pending_runs',
        idColumn: 'id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_work_items',
        idColumn: 'work_item_id',
        jsonColumn: 'payload_json',
        idsByPath: idsByPath,
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _migrateWorkspaceIdsInJsonColumn(
    Database db, {
    required String table,
    required String idColumn,
    required String jsonColumn,
    required Map<String, String> idsByPath,
  }) {
    if (!_columnExists(db, table, idColumn) ||
        !_columnExists(db, table, jsonColumn)) {
      return;
    }
    final rows = db.select('SELECT $idColumn, $jsonColumn FROM $table');
    final update = db.prepare(
      'UPDATE $table SET $jsonColumn = ? WHERE $idColumn = ?',
    );
    for (final row in rows) {
      final raw = row[jsonColumn]?.toString();
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        final migrated = _replaceWorkspaceIds(decoded, idsByPath);
        final encoded = jsonEncode(migrated);
        if (encoded != raw) update.execute([encoded, row[idColumn]]);
      } catch (_) {
        // Preserve malformed legacy payloads; top-level workspace columns are
        // still migrated and remain authoritative for recovery.
      }
    }
    update.dispose();
  }

  static dynamic _replaceWorkspaceIds(
    dynamic value,
    Map<String, String> idsByPath, {
    String? key,
  }) {
    if (value is Map) {
      final migrated = value.map(
        (entryKey, entryValue) => MapEntry(
          entryKey,
          _replaceWorkspaceIds(entryValue, idsByPath, key: entryKey.toString()),
        ),
      );
      if (key == 'workspace' && migrated['id'] is String) {
        final legacyId = migrated['id'] as String;
        migrated['id'] = idsByPath[legacyId] ?? legacyId;
      }
      return migrated;
    }
    if (value is List) {
      return value
          .map((item) => _replaceWorkspaceIds(item, idsByPath))
          .toList();
    }
    if (key == 'workspace_id' && value is String) {
      return idsByPath[value] ?? value;
    }
    return value;
  }

  static bool _tableExists(Database db, String table) {
    return db.select(
      'SELECT 1 FROM sqlite_master WHERE type = \'table\' AND name = ?',
      [table],
    ).isNotEmpty;
  }

  static bool _columnExists(Database db, String table, String column) {
    if (!_tableExists(db, table)) return false;
    return db
        .select('PRAGMA table_info($table)')
        .any((row) => row['name']?.toString() == column);
  }

  static String _workspaceDisplayName(String path) {
    final normalized = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final name = p.basename(normalized).trim();
    return name.isEmpty ? path : name;
  }

  static void _safeAddColumn(Database db, String ddl) {
    try {
      db.execute(ddl);
    } catch (_) {
      // Column already exists.
    }
  }

  static void _migrateLastUserMessageAt(Database db) {
    final sessionsResult = db.select(
      'SELECT session_id, created_at, updated_at, last_user_message_at, workspace_id FROM sessions',
    );
    if (sessionsResult.isEmpty) {
      return;
    }

    final sessionFallbacks = <String, String>{};
    final pendingMigrationSessionIds = <String>[];
    final resolvedFromSession = <String, String?>{};
    final originalLastUserMessageAt = <String, String?>{};
    final originalWorkspaceIds = <String, String?>{};
    for (final sessionRow in sessionsResult) {
      final sessionId = sessionRow['session_id'] as String;
      final createdAt = sessionRow['created_at'] as String;
      final updatedAt = sessionRow['updated_at'] as String;
      final rawLastUserMessageAt =
          sessionRow['last_user_message_at'] as String?;
      final rawWorkspaceId = sessionRow['workspace_id'] as String?;
      sessionFallbacks[sessionId] =
          _normalizeTimestampString(updatedAt) ??
          _normalizeTimestampString(createdAt) ??
          createdAt;
      final normalizedExisting = _normalizeTimestampString(
        rawLastUserMessageAt,
      );
      originalLastUserMessageAt[sessionId] = rawLastUserMessageAt;
      originalWorkspaceIds[sessionId] = rawWorkspaceId;
      if (normalizedExisting == null) {
        pendingMigrationSessionIds.add(sessionId);
      }
      resolvedFromSession[sessionId] = normalizedExisting;
    }

    final resolvedFromMessages = <String, String>{};
    for (
      var start = 0;
      start < pendingMigrationSessionIds.length;
      start += 200
    ) {
      final batch = pendingMigrationSessionIds.skip(start).take(200).toList();
      if (batch.isEmpty) {
        continue;
      }
      final placeholders = List.filled(batch.length, '?').join(', ');
      final messagesResult = db.select(
        'SELECT session_id, data FROM messages '
        'WHERE session_id IN ($placeholders) '
        'ORDER BY session_id ASC, id DESC',
        batch,
      );

      for (final msgRow in messagesResult) {
        final sessionId = msgRow['session_id'] as String;
        if (resolvedFromMessages.containsKey(sessionId)) {
          continue;
        }
        final dataStr = msgRow['data'] as String?;
        if (dataStr == null) {
          continue;
        }
        try {
          final data = jsonDecode(dataStr);
          if (data is! Map || data['role'] != 'user') {
            continue;
          }
          final metadata = data['metadata'];
          final normalized =
              _normalizeTimestampString(
                metadata is Map
                    ? metadata['received_at']?.toString() ??
                          metadata['timestamp']?.toString()
                    : null,
              ) ??
              _normalizeTimestampString(data['timestamp']?.toString());
          if (normalized != null) {
            resolvedFromMessages[sessionId] = normalized;
          }
        } catch (_) {
          // Ignore a malformed legacy message row and continue migration.
        }
      }
    }

    final stmt = db.prepare(
      'UPDATE sessions '
      'SET last_user_message_at = ?, workspace_id = ? '
      'WHERE session_id = ?',
    );
    for (final entry in sessionFallbacks.entries) {
      final sessionId = entry.key;
      final resolvedTimestamp =
          resolvedFromSession[sessionId] ??
          resolvedFromMessages[sessionId] ??
          entry.value;
      final rawWorkspaceId = originalWorkspaceIds[sessionId];
      final normalizedWorkspaceId = (() {
        final trimmed = rawWorkspaceId?.trim();
        if (trimmed == null || trimmed.isEmpty) {
          return null;
        }
        return trimmed;
      })();
      final rawLastUserMessageAt = originalLastUserMessageAt[sessionId];
      final shouldUpdateTimestamp = rawLastUserMessageAt != resolvedTimestamp;
      final shouldUpdateWorkspace = rawWorkspaceId != normalizedWorkspaceId;
      if (!shouldUpdateTimestamp && !shouldUpdateWorkspace) {
        continue;
      }
      stmt.execute([resolvedTimestamp, normalizedWorkspaceId, sessionId]);
    }
    stmt.dispose();
  }

  static String? _normalizeTimestampString(String? value) {
    if (value == null) {
      return null;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return null;
    }
    return parsed.toUtc().toIso8601String();
  }

  void dispose() {
    if (_owned) {
      _db.dispose();
    }
  }
}

/// Passable context for composing repositories inside one
/// [AgentStateDatabase.transaction] boundary.
///
/// The context does not own or close the database connection.
class AgentStateTransaction {
  final Database db;

  const AgentStateTransaction._(this.db);
}
