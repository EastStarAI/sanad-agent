import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/sanad_home/sanad_home_bootstrap.dart';
import '../../core/sanad_home/test_runtime_isolation.dart';
import '../models/session_search.dart';
import 'migrations/workspace_identity_migration.dart';
import 'schema/attachments_schema.dart';
import 'schema/compaction_schema.dart';
import 'schema/maintenance_schema.dart';
import 'schema/provider_schema.dart';
import 'schema/runtime_work_schema.dart';
import 'schema/scheduling_schema.dart';
import 'schema/schema_migration_support.dart';
import 'schema/sessions_messages_schema.dart';
import 'schema/user_secrets_schema.dart';
import 'schema/workspaces_schema.dart';

/// Single owner of the agent's local SQLite connection (`state.db`).
///
/// Both [`SessionDB`](session_db.dart) and
/// [`ProviderInstanceRepository`](../../core/provider_runtime/provider_instance_repository.dart)
/// consume this shared connection so the runtime never opens `state.db` twice.
/// It enables `PRAGMA foreign_keys = ON` (required for `ON DELETE CASCADE`) and
/// applies the schema for every table — sessions, messages, scheduled tasks,
/// suspended checkpoints, Plan 29 provider instance/cache/recent tables, and
/// `agent_maintenance_state` — through one ordered list of per-domain schema
/// modules under `evolution/db/schema/`. The emitted DDL and the order the
/// modules run in are pinned by
/// `test/evolution/agent_state_schema_snapshot_test.dart`.
///
/// Secrets NEVER live here: API keys and OAuth tokens are stored only in the
/// `SecretStore` (`provider_secrets.json`).
class AgentStateDatabase {
  late final Database _db;
  final void Function(Duration) _busyRetryWait;
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
  AgentStateDatabase() : _busyRetryWait = sleep {
    _openAtPath(getSanadStateHome());
  }

  /// Opens (or creates) `state.db` under an explicit runtime-state directory.
  /// Used by standalone helpers/tests that must not fall back to the global
  /// SANAD_STATE_HOME when a custom sanad home was provided.
  AgentStateDatabase.atPath(
    String stateHomePath, {
    @visibleForTesting void Function(Duration)? busyRetryWait,
  }) : _busyRetryWait = busyRetryWait ?? sleep {
    _openAtPath(stateHomePath);
  }

  /// Opens an existing `state.db` under [stateHomePath] strictly read-only for
  /// CLI inspection while the daemon may own the Home.
  ///
  /// The connection uses SQLite `OpenMode.readOnly` plus `PRAGMA query_only`,
  /// and runs no Home bootstrap, schema creation, migration, WAL switch or
  /// permission repair, so it never writes the database. Throws
  /// [SqliteException] when the file does not exist; callers check first.
  AgentStateDatabase.readOnlyAtPath(String stateHomePath)
    : _busyRetryWait = sleep {
    ensureSqliteOverride();
    _db = sqlite3.open(
      p.join(stateHomePath, stateDatabaseFileName),
      mode: OpenMode.readOnly,
    );
    _owned = true;
    try {
      _db.execute('PRAGMA busy_timeout = 5000');
      _db.execute('PRAGMA query_only = ON');
    } catch (_) {
      _db.dispose();
      _owned = false;
      rethrow;
    }
  }

  /// File name of the agent-state database inside a state root.
  static const String stateDatabaseFileName = 'state.db';

  /// Opens an in-memory database. Used by tests and ephemeral runtimes.
  AgentStateDatabase.inMemory({
    @visibleForTesting void Function(Duration)? busyRetryWait,
  }) : _busyRetryWait = busyRetryWait ?? sleep {
    ensureSqliteOverride();
    _db = sqlite3.openInMemory();
    _owned = true;
    _init();
  }

  /// Wraps an existing connection without taking ownership (caller disposes).
  @visibleForTesting
  AgentStateDatabase.fromConnection(
    this._db, {
    void Function(Duration)? busyRetryWait,
  }) : _busyRetryWait = busyRetryWait ?? sleep {
    _owned = false;
    _init();
  }

  /// Wraps an already initialized connection without owning or migrating it.
  /// Transitional facades use this only for backward-compatible constructors;
  /// production dependency injection passes the original owner directly.
  AgentStateDatabase.attached(this._db) : _busyRetryWait = sleep {
    _owned = false;
  }

  /// The underlying SQLite connection, shared by all consumers.
  Database get db => _db;

  /// Whether this owner currently has an open write transaction or savepoint.
  bool get hasOpenTransaction => _transactionDepth > 0;

  /// Reads SQLite page-layout statistics from the shared connection.
  AgentStatePageStatistics pageStatistics() {
    return AgentStatePageStatistics(
      pageSize: _pragmaInt('page_size'),
      pageCount: _pragmaInt('page_count'),
      freelistCount: _pragmaInt('freelist_count'),
    );
  }

  /// Rebuilds the database file to reclaim free pages.
  ///
  /// SQLite forbids `VACUUM` inside a transaction. This owner rejects the
  /// call when it holds an open transaction rather than letting SQLite fail
  /// with a less specific error.
  void vacuum() {
    if (_transactionDepth > 0) {
      throw StateError('VACUUM is not allowed while a transaction is open.');
    }
    _retryOnBusy(() => _db.execute('VACUUM'));
  }

  int _pragmaInt(String name) {
    final rows = _db.select('PRAGMA $name');
    final value = rows.first.values.first;
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    return int.parse(value.toString());
  }

  /// Runs [action] inside the single agent-state connection's write
  /// transaction and exposes a context that repositories can pass between
  /// one another without opening nested independent transactions.
  ///
  /// Nested calls use SQLite savepoints. This keeps low-level repository APIs
  /// independently usable while allowing aggregate owners to compose several
  /// repositories under one outer commit boundary.
  T transaction<T>(T Function(AgentStateTransaction transaction) action) {
    if (_transactionDepth > 0) {
      return _transactionInner(action);
    }
    return _retryOnBusy(() => _transactionInner(action));
  }

  T _transactionInner<T>(T Function(AgentStateTransaction transaction) action) {
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
      try {
        if (depth == 0) {
          _db.execute('ROLLBACK');
        } else {
          _db.execute('ROLLBACK TO SAVEPOINT $savepoint');
          _db.execute('RELEASE SAVEPOINT $savepoint');
        }
      } catch (_) {
        // Suppress rollback failures so the primary error rethrows.
      }
      rethrow;
    } finally {
      _transactionDepth = depth;
    }
  }

  void _openAtPath(String stateHomePath) {
    rejectUnisolatedTestHomeAccess(
      'open an on-disk Sanad state database',
      path: stateHomePath,
    );
    ensureSqliteOverride();
    // SQLite owns page/WAL/SHM writes and therefore cannot use the generic
    // atomic-file helper. SEC-02 brackets the native connection instead: root,
    // target and legacy sidecars are secured before open; newly created files
    // are secured immediately after open/schema initialization.
    final boundary = SanadHomeBootstrap.atRoot(stateHomePath);
    final dbPath = boundary.prepareDatabaseSync();
    _db = sqlite3.open(dbPath);
    _owned = true;
    try {
      _init();
    } catch (_) {
      _db.dispose();
      _owned = false;
      rethrow;
    } finally {
      boundary.secureDatabaseFilesSync();
    }
  }

  void _init() {
    _retryOnBusy<void>(() {
      // Register the search normalization function used by session search
      // queries before any schema/migration work.
      _db.createFunction(
        functionName: 'sanad_search_normalize',
        argumentCount: const AllowedArgumentCount(1),
        deterministic: true,
        function: (arguments) {
          final value = arguments.first;
          return value is String ? SessionSearchRequest.normalize(value) : '';
        },
      );
      // Configure busy_timeout first so internal waits apply to WAL and all
      // subsequent DDL/migration statements.
      _db.execute('PRAGMA busy_timeout = 5000');
      _db.execute('PRAGMA foreign_keys = ON');
      // Multi-process/multi-instance concurrency: WAL allows concurrent
      // readers with one writer; busy_timeout makes SQLite wait internally
      // for locks before surfacing SQLITE_BUSY to Dart.
      _db.execute('PRAGMA journal_mode = WAL');
      _createSchemaAndMigrate(_db);
    });
  }

  static const int _busyRetryAttempts = 3;
  static const List<Duration> _busyRetryBackoff = [
    Duration(milliseconds: 50),
    Duration(milliseconds: 100),
    Duration(milliseconds: 200),
  ];

  static final Logger _logger = Logger('AgentStateDatabase');

  /// Runs [action], retrying SQLite busy/locked contentions up to
  /// [_busyRetryAttempts] times with progressive backoff. Logs a warning for
  /// each retry; rethrows the original [SqliteException] when exhausted.
  T _retryOnBusy<T>(T Function() action) {
    var attempt = 0;
    while (true) {
      try {
        return action();
      } on SqliteException catch (error) {
        if (!isBusyOrLocked(error) || attempt >= _busyRetryAttempts) rethrow;
        final delay =
            _busyRetryBackoff[attempt.clamp(0, _busyRetryBackoff.length - 1)];
        attempt++;
        _logger.warning(
          'AgentStateDatabase busy (attempt $attempt/$_busyRetryAttempts, '
          'retrying in ${delay.inMilliseconds}ms): '
          '${error.message} (code ${error.resultCode})',
        );
        _busyRetryWait(delay);
      }
    }
  }

  /// Applies the full schema and every in-place migration.
  ///
  /// Each owning module runs at the exact position this method held before the
  /// SRP 138-11 split, so the emitted DDL, the table order, and the row
  /// migrations stay byte-identical. `RuntimeWorkSchema` and `WorkspacesSchema`
  /// contribute a second entry point because the pinned order interleaves their
  /// tables with the provider and compaction tables; never reorder or merge
  /// these calls, and never introduce `PRAGMA user_version` here (decision A3).
  static void _createSchemaAndMigrate(Database db) {
    SessionsMessagesSchema.apply(db);
    AttachmentsSchema.apply(db);
    SchedulingSchema.apply(db);
    WorkspacesSchema.apply(db);
    RuntimeWorkSchema.applySuspendedCheckpoints(db);
    ProviderSchema.apply(db);
    RuntimeWorkSchema.apply(db);
    MaintenanceSchema.apply(db);
    WorkspaceIdentityMigration.apply(db);
    SessionsMessagesSchema.migrateLastUserMessageAt(db);
    CompactionSchema.apply(db);
    WorkspacesSchema.applySecurityPolicies(db);
    // Task 140 A1: appended last so every pre-existing module keeps the
    // position the 138-05 snapshots pinned. One additive table, no migration
    // of any earlier table.
    UserSecretsSchema.apply(db);
  }

  /// Forwarder kept for the migration suites that migrate a bare legacy
  /// `scheduled_tasks` table outside a full schema open.
  @visibleForTesting
  static void migrateScheduledTasks(Database db) =>
      SchedulingSchema.migrateScheduledTasks(db);

  void dispose() {
    if (!_owned) return;
    _owned = false;
    _db.dispose();
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

/// Typed SQLite page-layout statistics used by startup vacuum policy.
class AgentStatePageStatistics {
  final int pageSize;
  final int pageCount;
  final int freelistCount;

  const AgentStatePageStatistics({
    required this.pageSize,
    required this.pageCount,
    required this.freelistCount,
  });

  int get reclaimableBytes => pageSize * freelistCount;

  double get freeRatio => pageCount == 0 ? 0 : freelistCount / pageCount;
}
