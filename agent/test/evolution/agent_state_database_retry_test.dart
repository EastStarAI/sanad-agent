import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('on-disk database initializes in WAL mode with 5000ms busy_timeout', () {
    final dir = Directory.systemTemp.createTempSync('sanad_wal_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final db = AgentStateDatabase.atPath(dir.path);
    addTearDown(db.dispose);
    final journalMode = db.db.select('PRAGMA journal_mode').first.values.first;
    final busyTimeout = db.db.select('PRAGMA busy_timeout').first.values.first;
    expect(journalMode, 'wal');
    expect(busyTimeout, 5000);
  });

  test('inMemory database applies the 5000ms busy_timeout', () {
    final db = AgentStateDatabase.inMemory();
    addTearDown(db.dispose);
    final busyTimeout = db.db.select('PRAGMA busy_timeout').first.values.first;
    expect(busyTimeout, 5000);
    // In-memory databases cannot enable WAL; journal_mode stays `memory`.
    expect(
      db.db.select('PRAGMA journal_mode').first.values.first,
      isIn(['memory', 'wal']),
    );
  });

  test(
    'transient lock contention succeeds on retry after blocker releases lock',
    () {
      final dir = Directory.systemTemp.createTempSync('sanad_transient_retry_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final delays = <Duration>[];
      final target = AgentStateDatabase.atPath(
        dir.path,
        busyRetryWait: delays.add,
      );
      addTearDown(target.dispose);
      target.db.execute('PRAGMA busy_timeout = 50');

      final blocker = sqlite3.open('${dir.path}/state.db');
      var blockerDisposed = false;
      addTearDown(() {
        if (!blockerDisposed) blocker.dispose();
      });
      blocker.execute('BEGIN EXCLUSIVE');

      final warnings = <String>[];
      final subscription = Logger('AgentStateDatabase').onRecord.listen((
        record,
      ) {
        if (record.level >= Level.WARNING) {
          warnings.add(record.message);
          // Release blocker on the first retry warning.
          try {
            blocker.execute('ROLLBACK');
            blocker.dispose();
            blockerDisposed = true;
          } catch (_) {}
        }
      });
      addTearDown(subscription.cancel);

      final result = target.transaction((tx) {
        return tx.db.select('SELECT 42 AS value').first['value'];
      });

      expect(result, 42);
      expect(delays, [const Duration(milliseconds: 50)]);
      expect(warnings.length, 1);
      expect(warnings.first, contains('AgentStateDatabase busy (attempt 1/3'));
    },
  );

  test('persistent lock contention emits 3 retry warnings then rethrows', () {
    final dir = Directory.systemTemp.createTempSync('sanad_retry_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final delays = <Duration>[];
    final target = AgentStateDatabase.atPath(
      dir.path,
      busyRetryWait: delays.add,
    );
    addTearDown(target.dispose);
    target.db.execute('PRAGMA busy_timeout = 50');

    // Keep this connection's exclusive transaction open for every attempt so
    // all 3 retries observe SQLITE_BUSY and the loop finally rethrows.
    final blocker = sqlite3.open('${dir.path}/state.db');
    blocker.execute('BEGIN EXCLUSIVE');

    final warnings = <String>[];
    final subscription = Logger('AgentStateDatabase').onRecord.listen((record) {
      if (record.level >= Level.WARNING) warnings.add(record.message);
    });
    addTearDown(subscription.cancel);

    Object? caught;
    try {
      target.transaction((tx) => tx.db.select('SELECT 1'));
    } on SqliteException catch (error) {
      caught = error;
    } finally {
      blocker.execute('ROLLBACK');
      blocker.dispose();
    }

    expect(caught, isA<SqliteException>());
    expect(
      (caught as SqliteException).resultCode,
      anyOf(5, 6),
      reason:
          'original SqliteException must be rethrown when retries are '
          'exhausted',
    );
    expect(delays, const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
    ]);
    expect(warnings.length, 3, reason: 'warnings observed: $warnings');
    expect(
      warnings.every((w) => w.contains('AgentStateDatabase busy')),
      isTrue,
    );
  });

  test('VACUUM uses the shared bounded busy retry policy', () {
    final dir = Directory.systemTemp.createTempSync('sanad_vacuum_retry_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final delays = <Duration>[];
    final target = AgentStateDatabase.atPath(
      dir.path,
      busyRetryWait: delays.add,
    );
    addTearDown(target.dispose);
    target.db.execute('PRAGMA busy_timeout = 50');

    final blocker = sqlite3.open('${dir.path}/state.db');
    blocker.execute('BEGIN EXCLUSIVE');
    try {
      expect(target.vacuum, throwsA(isA<SqliteException>()));
    } finally {
      blocker.execute('ROLLBACK');
      blocker.dispose();
    }

    expect(delays, const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
    ]);
  });

  test('nested transaction does not retry independently inside savepoint', () {
    final dir = Directory.systemTemp.createTempSync('sanad_nested_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final delays = <Duration>[];
    final target = AgentStateDatabase.atPath(
      dir.path,
      busyRetryWait: delays.add,
    );
    addTearDown(target.dispose);
    final warnings = <String>[];
    final subscription = Logger('AgentStateDatabase').onRecord.listen((record) {
      if (record.level >= Level.WARNING) warnings.add(record.message);
    });
    addTearDown(subscription.cancel);

    var outerAttempts = 0;
    var innerAttempts = 0;

    try {
      target.transaction((outerTx) {
        outerAttempts++;
        target.transaction((innerTx) {
          innerAttempts++;
          throw SqliteException(5, 'database is locked');
        });
      });
    } on SqliteException {
      // Expected exhaustion.
    }

    // Outer transaction attempts 1 initial + 3 retries = 4 total attempts.
    // Because the inner transaction does not retry independently, both
    // callbacks run four times and only the outer boundary emits warnings.
    expect(outerAttempts, 4);
    expect(innerAttempts, 4);
    expect(delays, const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
    ]);
    expect(warnings.length, 3);
  });
}
