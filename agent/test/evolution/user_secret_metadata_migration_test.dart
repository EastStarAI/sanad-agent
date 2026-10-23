import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Task 140 A1: `user_secret_metadata` is created additively and idempotently
/// on a fresh database and on every database an existing Home can present.
///
/// The table holds non-secret metadata only. No test here writes a value, and
/// the last group proves no column can hold one.
void main() {
  setUp(() {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
  });

  tearDown(() {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
  });

  Map<String, Row> columns(Database db) => {
    for (final row in db.select('PRAGMA table_info(user_secret_metadata)'))
      row['name'] as String: row,
  };

  group('user_secret_metadata DDL (A1)', () {
    test('a fresh database creates the table with the five columns', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);

      final tableColumns = columns(state.db);
      expect(tableColumns.keys, [
        'name',
        'description',
        'source',
        'created_at',
        'updated_at',
      ]);

      expect(tableColumns['name']!['type'], 'TEXT');
      expect(tableColumns['name']!['pk'], 1, reason: 'name is the only identity');
      expect(tableColumns['name']!['notnull'], 1);

      expect(tableColumns['description']!['type'], 'TEXT');
      expect(
        tableColumns['description']!['notnull'],
        0,
        reason: 'a description is optional',
      );

      expect(tableColumns['source']!['type'], 'TEXT');
      expect(tableColumns['source']!['notnull'], 1);
      expect(
        tableColumns['source']!['dflt_value'],
        isNull,
        reason: 'every writer must state how the value arrived',
      );

      for (final instant in ['created_at', 'updated_at']) {
        expect(tableColumns[instant]!['type'], 'TEXT', reason: instant);
        expect(tableColumns[instant]!['notnull'], 1, reason: instant);
      }
    });

    test('source accepts only the two recorded arrival paths', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);

      const insert = '''
        INSERT INTO user_secret_metadata
          (name, description, source, created_at, updated_at)
        VALUES (?, NULL, ?, ?, ?)
      ''';
      const instant = '2026-10-23T08:12:00.000Z';
      for (final source in ['agent_request', 'user']) {
        state.db.execute(insert, [source.toUpperCase(), source, instant, instant]);
      }
      expect(
        state.db.select('SELECT COUNT(*) AS total FROM user_secret_metadata')
            .single['total'],
        2,
      );

      for (final rejected in ['model', '', 'USER']) {
        expect(
          () => state.db.execute(insert, [
            'REJECTED_$rejected',
            rejected,
            instant,
            instant,
          ]),
          throwsA(isA<SqliteException>()),
          reason: 'source=$rejected must not be storable',
        );
      }
      expect(
        state.db.select('SELECT COUNT(*) AS total FROM user_secret_metadata')
            .single['total'],
        2,
        reason: 'a rejected write leaves the table unchanged',
      );
    });

    test('a second open is a schema no-op', () {
      final root = Directory.systemTemp.createTempSync('sanad-secret-meta-');
      addTearDown(() {
        setSanadHomeOverride(null);
        setSanadStateHomeOverride(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      setSanadHomeOverride(root.path);
      setSanadStateHomeOverride(root.path);

      final first = AgentStateDatabase();
      final firstShape = _shape(first.db);
      first.dispose();

      final reopened = AgentStateDatabase();
      addTearDown(reopened.dispose);

      expect(_shape(reopened.db), firstShape);
    });
  });

  group('additive migration for an existing Home (A1)', () {
    test('a database created before the table gains it on the next open', () {
      final raw = sqlite3.openInMemory();
      addTearDown(raw.dispose);
      // A Home that predates Task 140: sessions exist, the secrets table does
      // not.
      raw.execute('''
        CREATE TABLE sessions (
          session_id TEXT PRIMARY KEY,
          model TEXT NOT NULL,
          title TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');
      raw.execute(
        'INSERT INTO sessions (session_id, model, title, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[
          'legacy_session',
          'legacy-model',
          'Legacy thread',
          '2026-09-01T08:00:00.000Z',
          '2026-09-01T08:00:00.000Z',
        ],
      );
      expect(_tableExists(raw), isFalse);

      AgentStateDatabase.fromConnection(raw);

      expect(_tableExists(raw), isTrue);
      expect(
        raw.select('SELECT title FROM sessions').single['title'],
        'Legacy thread',
        reason: 'the migration touches no pre-existing row',
      );
      expect(
        raw.select('SELECT COUNT(*) AS total FROM user_secret_metadata')
            .single['total'],
        0,
        reason: 'an existing Home gains an empty table, never a row',
      );
    });

    test('three consecutive opens keep the schema and every row identical', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);
      final repository = UserSecretMetadataRepository(state);
      repository.recordValue(
        name: 'DATABASE_PASSWORD',
        description: 'Staging database password',
        source: UserSecretSource.user,
        at: DateTime.utc(2026, 10, 23, 8, 12),
      );

      final shape = _shape(state.db);
      final rows = _rows(state.db);

      // A second and a third open, as consecutive daemon starts on one Home.
      AgentStateDatabase.fromConnection(state.db);
      AgentStateDatabase.fromConnection(state.db);

      expect(_shape(state.db), shape);
      expect(_rows(state.db), rows);
    });
  });

  group('no value can be stored (M1)', () {
    test('the table has no value-shaped column', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);

      final tableColumns = columns(state.db).keys.toSet();
      for (final forbidden in [
        'value',
        'secret',
        'secret_value',
        'value_hash',
        'value_prefix',
        'hash',
        'salt',
        'ciphertext',
        'preview',
      ]) {
        expect(
          tableColumns,
          isNot(contains(forbidden)),
          reason:
              'user_secret_metadata must never grow a column that could hold '
              'a value or anything derived from one',
        );
      }
    });
  });
}

bool _tableExists(Database db) => db.select(
  "SELECT 1 FROM sqlite_master WHERE type = 'table' "
  "AND name = 'user_secret_metadata'",
).isNotEmpty;

/// Column and DDL shape of `user_secret_metadata`, used to prove repeated
/// opens change nothing.
String _shape(Database db) {
  final objects = db
      .select(
        'SELECT type, name, sql FROM sqlite_master '
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
      )
      .map((row) => '${row['type']}|${row['name']}|${row['sql']}')
      .join('\n');
  final columns = db
      .select('PRAGMA table_info(user_secret_metadata)')
      .map(
        (row) =>
            '${row['name']}|${row['type']}|${row['notnull']}|'
            '${row['dflt_value']}|${row['pk']}',
      )
      .join('\n');
  return '$objects\n$columns';
}

String _rows(Database db) => db
    .select('SELECT * FROM user_secret_metadata ORDER BY name ASC')
    .map(
      (row) => Map<String, dynamic>.from(row).entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(','),
    )
    .join('\n');
