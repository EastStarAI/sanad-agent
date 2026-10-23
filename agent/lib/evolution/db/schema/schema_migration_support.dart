import 'package:sqlite3/sqlite3.dart';

/// Whether [error] is a SQLite lock-contention error (`SQLITE_BUSY` or
/// `SQLITE_LOCKED`), either at the top level or inside a transaction.
///
/// The per-domain schema modules, their guarded additive migrations, and
/// `AgentStateDatabase`'s busy-retry boundary share this one predicate, so a
/// lock error is classified identically everywhere and is never mistaken for
/// an already-applied migration.
bool isBusyOrLocked(SqliteException error) {
  final primary = error.resultCode;
  return primary ==
          5 || // SQLITE_BUSY (covers extended codes such as 517 SQLITE_BUSY_SNAPSHOT)
      primary == 6; // SQLITE_LOCKED
}

/// Runs one additive `ALTER TABLE` statement, ignoring the "column already
/// exists" failure that keeps every schema open idempotent.
///
/// Lock contention is never swallowed: an [isBusyOrLocked] failure rethrows so
/// the owning busy-retry boundary can retry the whole open.
void safeAddColumn(Database db, String ddl) {
  try {
    db.execute(ddl);
  } on SqliteException catch (error) {
    if (isBusyOrLocked(error)) rethrow;
    // Column already exists.
  }
}

/// Whether [db] contains a table named [table].
bool tableExists(Database db, String table) {
  return db.select(
    'SELECT 1 FROM sqlite_master WHERE type = \'table\' AND name = ?',
    [table],
  ).isNotEmpty;
}

/// Whether the existing table [table] already has [column].
///
/// A missing table is not an error: every schema module migrates legacy shapes
/// table by table, and an optional table may legitimately be absent.
bool columnExists(Database db, String table, String column) {
  if (!tableExists(db, table)) return false;
  return db
      .select('PRAGMA table_info($table)')
      .any((row) => row['name']?.toString() == column);
}
