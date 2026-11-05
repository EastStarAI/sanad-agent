import 'package:sqlite3/sqlite3.dart';

/// One reusable SQLite write-transaction boundary over a raw [Database].
///
/// SQLite aborts the whole transaction itself for fatal errors such as
/// `SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_NOMEM`, `SQLITE_BUSY`, and
/// `SQLITE_INTERRUPT`. A later bare `ROLLBACK` then raises
/// `cannot rollback - no transaction is active`, which replaces the real
/// failure before it can reach the operator (a full disk surfaced as a
/// provider error). Every write boundary therefore rolls back only while the
/// connection still has a transaction, and always lets the original error
/// escape.
class SqliteTransaction {
  SqliteTransaction._();

  /// Opens the transaction these helpers bracket.
  static void begin(Database db, {bool immediate = false}) {
    db.execute(immediate ? 'BEGIN IMMEDIATE TRANSACTION' : 'BEGIN TRANSACTION');
  }

  /// Runs [action] inside one write transaction and returns its result.
  ///
  /// [action] must be synchronous. A thrown error rolls the transaction back
  /// when SQLite still has one and rethrows that same error unchanged, so an
  /// auto-rolled-back transaction can never surface a rollback failure instead
  /// of the failure that caused it. [abort] exits the callback without
  /// committing while still returning a value to the caller.
  static T run<T>(
    Database db,
    T Function() action, {
    bool immediate = false,
  }) {
    begin(db, immediate: immediate);
    try {
      // Invoked through [Function] so a `void` callback type still shares this
      // single commit/rollback path.
      final Object? result = _invoke(action);
      if (result is Future) {
        throw StateError(
          'SqliteTransaction.run callbacks must be synchronous.',
        );
      }
      db.execute('COMMIT');
      return result as T;
    } catch (error) {
      rollbackQuietly(db);
      if (error is _SqliteTransactionAbort) {
        return error.result as T;
      }
      rethrow;
    }
  }

  /// [run] for a callback that produces no value.
  static void runVoid(
    Database db,
    void Function() action, {
    bool immediate = false,
  }) {
    run<void>(db, action, immediate: immediate);
  }

  static Object? _invoke(Function action) => action();

  /// Ends the enclosing [run] transaction without committing and returns
  /// [result] from it.
  ///
  /// Used by boundaries that report a controlled outcome (for example "target
  /// not found") instead of throwing a failure.
  static Never abort(Object? result) => throw _SqliteTransactionAbort(result);

  /// Rolls back the connection's open transaction when SQLite still holds one.
  ///
  /// Returns `false` when nothing was rolled back, which is the normal outcome
  /// after SQLite already auto-rolled the transaction back. A rollback failure
  /// propagates so a deliberate abort can never leave a transaction open.
  static bool rollback(Database db) {
    if (db.autocommit) return false;
    db.execute('ROLLBACK');
    return true;
  }

  /// Rolls back [db] like [rollback] but never throws.
  ///
  /// Error paths use this so a failed rollback cannot mask the original
  /// failure the caller is about to rethrow.
  static bool rollbackQuietly(Database db) {
    try {
      return rollback(db);
    } on SqliteException {
      return false;
    }
  }

  /// Rolls [savepoint] back when SQLite still has a transaction, then releases
  /// it. Nothing runs when the whole transaction was already auto-rolled back,
  /// because the savepoint no longer exists either. Failure is suppressed for
  /// the same reason as [rollbackQuietly].
  static void rollbackSavepointQuietly(Database db, String savepoint) {
    if (db.autocommit) return;
    try {
      db.execute('ROLLBACK TO SAVEPOINT $savepoint');
      db.execute('RELEASE SAVEPOINT $savepoint');
    } on SqliteException {
      // The original failure is the one that must escape.
    }
  }
}

/// Carries the value a [SqliteTransaction.abort] returns from its `run`.
class _SqliteTransactionAbort implements Exception {
  final Object? result;

  const _SqliteTransactionAbort(this.result);
}
