import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/sqlite_transaction.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// A full disk must surface the real failure, never a second `ROLLBACK`.
///
/// SQLite aborts the whole transaction itself for `SQLITE_FULL` (and
/// `SQLITE_IOERR`, `SQLITE_NOMEM`, `SQLITE_BUSY`, `SQLITE_INTERRUPT`). The old
/// boundaries issued a bare `ROLLBACK` in their catch block, which raised
/// `SqliteException(1): cannot rollback - no transaction is active` and hid the
/// disk-full cause behind it. `PRAGMA max_page_count` makes the database
/// genuinely full without touching the host filesystem.
void main() {
  useIsolatedSanadStateRoot();

  late Directory root;
  late String databasePath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sanad_sqlite_tx_');
    databasePath = p.join(root.path, 'state.db');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Opens a scratch database whose capacity is frozen at its current size.
  Database fullDatabase() {
    final db = sqlite3.open(databasePath);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('CREATE TABLE payloads (value BLOB NOT NULL)');
    final pageCount = db.select('PRAGMA page_count').first.values.first as int;
    db.execute('PRAGMA max_page_count = $pageCount');
    return db;
  }

  /// Inserts more bytes than SQLite may still allocate.
  void writeBeyondCapacity(Database db) {
    db.execute('INSERT INTO payloads VALUES (?)', [
      List<int>.filled(256 * 1024, 7),
    ]);
  }

  test('SqliteException reports SQLITE_FULL and SQLite keeps no transaction', () {
    final db = fullDatabase();
    addTearDown(db.dispose);
    db.execute('BEGIN IMMEDIATE TRANSACTION');
    Object? failure;
    try {
      writeBeyondCapacity(db);
    } on SqliteException catch (error) {
      failure = error;
    }
    expect(failure, isA<SqliteException>());
    expect((failure! as SqliteException).resultCode & 0xff, 13);
    expect(
      db.autocommit,
      isTrue,
      reason: 'SQLite auto-rolls the transaction back on SQLITE_FULL',
    );
  });

  test('rollback is a no-op after SQLite auto-rolled the transaction back', () {
    final db = fullDatabase();
    addTearDown(db.dispose);
    db.execute('BEGIN IMMEDIATE TRANSACTION');
    expect(() => writeBeyondCapacity(db), throwsA(isA<SqliteException>()));
    expect(SqliteTransaction.rollbackQuietly(db), isFalse);
  });

  test('SqliteTransaction.run surfaces the original SQLITE_FULL failure', () {
    final db = fullDatabase();
    addTearDown(db.dispose);
    Object? failure;
    try {
      SqliteTransaction.runVoid(db, () => writeBeyondCapacity(db));
    } on SqliteException catch (error) {
      failure = error;
    }
    expect(failure, isA<SqliteException>());
    expect((failure! as SqliteException).resultCode & 0xff, 13);
    expect(
      (failure as SqliteException).message,
      isNot(contains('cannot rollback')),
    );
  });

  test('SqliteTransaction.run rethrows a failing callback unchanged', () {
    final db = sqlite3.open(databasePath);
    addTearDown(db.dispose);
    db.execute('CREATE TABLE payloads (value BLOB NOT NULL)');

    expect(
      () => SqliteTransaction.runVoid(db, () {
        db.execute('INSERT INTO payloads VALUES (?)', [
          List<int>.filled(16, 1),
        ]);
        throw StateError('repository failure');
      }),
      throwsA(isA<StateError>()),
    );
    expect(db.autocommit, isTrue);
    expect(
      db.select('SELECT COUNT(*) AS total FROM payloads').first['total'],
      0,
      reason: 'the failed transaction must be rolled back',
    );
  });

  test('abort rolls back and returns the reported outcome', () {
    final db = sqlite3.open(databasePath);
    addTearDown(db.dispose);
    db.execute('CREATE TABLE payloads (value BLOB NOT NULL)');

    final outcome = SqliteTransaction.run<String?>(db, () {
      db.execute('INSERT INTO payloads VALUES (?)', [
        List<int>.filled(16, 1),
      ]);
      SqliteTransaction.abort(null);
    });

    expect(outcome, isNull);
    expect(db.autocommit, isTrue);
    expect(
      db.select('SELECT COUNT(*) AS total FROM payloads').first['total'],
      0,
      reason: 'an aborted transaction must not commit its writes',
    );
  });

  test('replaceMessages surfaces SQLITE_FULL instead of a rollback error', () {
    final state = AgentStateDatabase.atPath(root.path);
    addTearDown(state.dispose);
    final db = SessionDB.fromState(state);
    addTearDown(db.dispose);
    const sessionId = 'disk-full-session';
    final now = DateTime.utc(2026, 11, 5);
    db.saveSession(
      SessionState(
        sessionId: sessionId,
        model: 'model',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final pageCount =
        state.db.select('PRAGMA page_count').first.values.first as int;
    state.db.execute('PRAGMA max_page_count = $pageCount');

    Object? failure;
    try {
      db.replaceMessages(sessionId, [
        Message(role: MessageRole.user, content: 'x' * 262144),
      ]);
    } on SqliteException catch (error) {
      failure = error;
    }

    expect(failure, isA<SqliteException>());
    expect((failure! as SqliteException).resultCode & 0xff, 13);
    expect(
      (failure as SqliteException).message,
      isNot(contains('cannot rollback')),
      reason:
          'the original disk-full failure must reach the runtime, not the '
          'double-rollback error',
    );
    expect(state.db.autocommit, isTrue);
  });
}
