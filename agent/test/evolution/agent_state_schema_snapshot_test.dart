// Characterization of the agent-state SQLite schema shape.
//
// SRP item 138-05 pins the shape that `AgentStateDatabase` produces today so
// that the planned split of its 1,635-line DDL block (item 138-11) can be
// proved move-only: this file contains no production code, and every snapshot
// must stay byte-identical before and after that split.
//
// For a fresh database and for three legacy fixtures the snapshots record:
//   * `sqlite_master` rows (tables, indexes, triggers) with their DDL text,
//   * `PRAGMA table_info` (column order, type, NOT NULL, default, PK),
//   * `PRAGMA index_list` plus `PRAGMA index_info` (unique, origin, partial,
//     indexed columns, expression placeholders),
//   * `PRAGMA foreign_key_list` (target, actions).
//
// DDL text is canonicalized by collapsing whitespace and normalizing spacing
// around `,` and `)`. A verbatim move that re-indents the string literals keeps
// the snapshot stable; any change to a token, constraint, column, index,
// trigger, default, or column order fails it.
//
// Deliberate schema changes must regenerate the snapshots and review the diff:
//
//   cd agent && SANAD_UPDATE_AGENT_STATE_SCHEMA_SNAPSHOT=1 fvm dart test \
//     test/evolution/agent_state_schema_snapshot_test.dart
//
// The fixtures contain synthetic placeholders only: no secrets, tokens, or real
// user data. Every database opened here is in-memory or lives in a temporary
// directory with isolated Sanad roots, so no test reaches the real Home.

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const String _fixtureDirectory = 'test/evolution/fixtures/agent_state';

/// Set this to `1` to rewrite the committed snapshots from the live schema.
const String _updateSnapshotVariable =
    'SANAD_UPDATE_AGENT_STATE_SCHEMA_SNAPSHOT';

/// Legacy shapes that `AgentStateDatabase` still has to migrate in place.
const List<String> _legacyFixtures = <String>[
  'legacy_pre_workspace_uuid',
  'legacy_pre_attachments_v2',
  'legacy_pre_112_schedules',
];

const String _freshLabel = 'fresh';

/// Stable UUID v4 shape, the only workspace identity the migration may mint.
final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  setUp(() {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
  });

  tearDown(() {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
  });

  group('fresh database', () {
    test('the in-memory schema matches the pinned snapshot', () {
      final state = _openFreshInMemory();

      _expectSchemaSnapshot(_freshLabel, state.db);
      expect(
        _schemaObjectCount(state.db),
        greaterThan(0),
        reason: 'the snapshot must describe a created schema',
      );
    });

    test('the on-disk database pins the same snapshot and reopens as a no-op', () {
      final root = Directory.systemTemp.createTempSync(
        'sanad-agent-state-schema-',
      );
      addTearDown(() {
        setSanadHomeOverride(null);
        setSanadStateHomeOverride(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      setSanadHomeOverride(root.path);
      setSanadStateHomeOverride(root.path);

      final first = AgentStateDatabase();
      _expectSchemaSnapshot(_freshLabel, first.db);
      first.dispose();

      final reopened = AgentStateDatabase();
      addTearDown(reopened.dispose);

      _expectSchemaSnapshot(_freshLabel, reopened.db);
      expect(
        File(
          p.join(root.path, AgentStateDatabase.stateDatabaseFileName),
        ).existsSync(),
        isTrue,
      );
    });
  });

  group('legacy fixtures', () {
    for (final fixture in _legacyFixtures) {
      test('$fixture migrates to the pinned snapshot', () {
        final state = _openMigratedFixture(fixture);

        _expectSchemaSnapshot(fixture, state.db);
      });
    }

    test('migrating a fixture twice is schema-idempotent', () {
      for (final fixture in _legacyFixtures) {
        final state = _openMigratedFixture(fixture);
        final firstPass = _renderSchemaSnapshot(state.db, fixture);

        // A second open on the same connection runs every migration again.
        AgentStateDatabase.fromConnection(state.db);

        expect(
          _renderSchemaSnapshot(state.db, fixture),
          firstPass,
          reason: '$fixture must not change shape when migrated twice',
        );
      }
    });
  });

  group('pre-workspace-UUID migration', () {
    test('each distinct legacy path becomes one UUID workspace row', () {
      final state = _openMigratedFixture('legacy_pre_workspace_uuid');

      final workspaces = _rowsBy(
        state.db,
        'SELECT id, display_name, path, source, created_at, updated_at '
        'FROM workspaces',
        'path',
      );
      expect(
        workspaces.keys,
        unorderedEquals(<String>[
          '/legacy/workspaces/alpha',
          '/legacy/workspaces/beta',
          '/legacy/workspaces/gamma',
        ]),
        reason: 'every registered path and every referenced path gets one row',
      );
      for (final entry in workspaces.entries) {
        final id = entry.value['id'] as String;
        expect(
          _uuidV4.hasMatch(id),
          isTrue,
          reason: '${entry.key} must map to a v4 UUID, not a path',
        );
      }

      final alpha = workspaces['/legacy/workspaces/alpha']!;
      expect(alpha['source'], 'existing');
      expect(
        alpha['created_at'],
        '2026-09-02T08:00:00.000Z',
        reason: 'created_at and updated_at are the legacy updated_at',
      );
      expect(alpha['updated_at'], '2026-09-02T08:00:00.000Z');
      // Characterizes current behavior; see follow-up: the legacy
      // `workspaces.display_name` is discarded and re-derived from the path
      // basename, so a user-renamed legacy workspace loses its name.
      expect(alpha['display_name'], 'alpha');

      expect(
        workspaces['/legacy/workspaces/gamma']!['source'],
        'migrated_session',
        reason: 'a path referenced only by a session gains a row',
      );

      final sessions = _rowsBy(
        state.db,
        'SELECT session_id, workspace_id, last_user_message_at FROM sessions',
        'session_id',
      );
      expect(
        sessions['legacy_session_alpha']!['workspace_id'],
        alpha['id'],
        reason: 'the session now points at the UUID',
      );
      expect(
        sessions['legacy_session_gamma']!['workspace_id'],
        workspaces['/legacy/workspaces/gamma']!['id'],
      );
      expect(
        sessions['legacy_session_unscoped']!['workspace_id'],
        isNull,
        reason: 'a blank legacy path normalizes to NULL',
      );

      expect(
        sessions['legacy_session_alpha']!['last_user_message_at'],
        '2026-09-05T11:30:00.000Z',
        reason: 'the newest user message orders the session',
      );
      expect(
        sessions['legacy_session_unscoped']!['last_user_message_at'],
        '2026-09-07T08:00:00.000Z',
        reason: 'a non-UTC legacy timestamp is normalized to UTC',
      );
    });

    test('orphaned absolute-path references gain workspace rows on the next open', () {
      final state = _openFreshInMemory();
      final legacyPath = p.absolute(
        p.join('sanad-legacy-workspace', 'orphan-alpha'),
      );
      _seedOrphanedPathReferences(state.db, legacyPath);

      // The next open runs `_migrateOrphanedPathWorkspaceReferences`.
      AgentStateDatabase.fromConnection(state.db);

      final workspaces = _rowsBy(
        state.db,
        'SELECT id, display_name, path, source FROM workspaces WHERE path = ?',
        'path',
        parameters: <Object?>[legacyPath],
      );
      final created = workspaces[legacyPath]!;
      expect(created['source'], 'migrated_session');
      expect(created['display_name'], 'orphan-alpha');
      final workspaceId = created['id'] as String;
      expect(_uuidV4.hasMatch(workspaceId), isTrue);

      final session = state.db.select(
        'SELECT workspace_id FROM sessions WHERE session_id = ?',
        <Object?>['legacy_session_orphan'],
      ).single;
      expect(session['workspace_id'], workspaceId);

      for (final table in <String>[
        'session_work_items',
        'session_suspended_runs',
        'session_pending_runs',
      ]) {
        final raw = state.db.select('SELECT * FROM $table').single;
        final column = table == 'session_work_items'
            ? 'payload_json'
            : 'event_metadata';
        final decoded = raw[column] as String;
        expect(
          decoded,
          isNot(contains(legacyPath)),
          reason: '$table.$column must not keep a path workspace reference',
        );
        expect(
          decoded,
          contains(workspaceId),
          reason: '$table.$column must carry the migrated UUID',
        );
      }
    });
  });

  group('pre-attachments-v2 migration', () {
    test('rows are rebuilt with derived admission ids and the insert trigger is gone', () {
      final state = _openMigratedFixture('legacy_pre_attachments_v2');

      final attachments = _rowsBy(
        state.db,
        'SELECT attachment_id, admission_id, message_id, status, safe_name '
        'FROM user_attachments',
        'attachment_id',
      );
      expect(
        attachments.keys,
        unorderedEquals(<String>[
          'legacy_attachment_attached',
          'legacy_attachment_staged',
        ]),
      );
      for (final entry in attachments.entries) {
        expect(
          entry.value['admission_id'],
          'legacy:${entry.key}',
          reason: 'the rebuild derives one admission id per legacy row',
        );
      }
      expect(
        attachments['legacy_attachment_attached']!['message_id'],
        'legacy_message_attached',
      );
      // Characterizes current behavior; see follow-up: the rebuild has no
      // candidate admission for a staged legacy row, so it becomes attached to
      // its stored message id.
      expect(attachments['legacy_attachment_staged']!['status'], 'attached');

      final triggers = state.db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' "
            "AND tbl_name = 'user_attachments' ORDER BY name ASC",
          )
          .map((row) => row['name'])
          .toList();
      expect(
        triggers,
        <String>['user_attachments_message_owner_update'],
        reason: 'the v1 insert trigger is dropped and never restored',
      );

      final messageIdColumn = state.db
          .select('PRAGMA table_info(user_attachments)')
          .singleWhere((row) => row['name'] == 'message_id');
      expect(
        messageIdColumn['notnull'],
        0,
        reason: 'v2 makes message_id nullable',
      );

      expect(
        state.db.select(
          "SELECT name FROM sqlite_master WHERE name = 'user_attachments_v1'",
        ),
        isEmpty,
        reason: 'the rebuilt-from table does not survive the migration',
      );
    });
  });

  group('pre-112 schedules migration', () {
    test('legacy rows are backfilled and the legacy NOT NULL is kept', () {
      final state = _openMigratedFixture('legacy_pre_112_schedules');

      final rows = state.db.select(
        'SELECT * FROM scheduled_tasks ORDER BY id ASC',
      );
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['next_run_at'], row['run_at'], reason: row['id'] as String);
        expect(row['kind'], 'once');
        expect(row['zone'], 'local');
        expect(row['enabled'], 1);
        expect(
          row['updated_at'],
          row['created_at'],
          reason: 'the migration backfills updated_at from created_at',
        );
        expect(row['interval_minutes'], isNull);
        expect(row['at_time'], isNull);
        expect(row['weekdays'], isNull);
        expect(row['month_day'], isNull);
        expect(row['last_run_at'], isNull);
        expect(row['last_status'], isNull);
        // Task 139: every existing row stays model-owned with one continuous
        // conversation and no dispatch route.
        expect(row['owner_kind'], 'model');
        expect(row['conversation_mode'], 'continuous');
        expect(row['name'], isNull);
        expect(row['run_session_id'], isNull);
        expect(row['workspace_id'], isNull);
        expect(row['provider_instance_id'], isNull);
        expect(row['model'], isNull);
      }

      final runAtColumn = state.db
          .select('PRAGMA table_info(scheduled_tasks)')
          .singleWhere((row) => row['name'] == 'run_at');
      expect(
        runAtColumn['notnull'],
        1,
        reason: 'the migration never relaxes the legacy constraint',
      );

      final indexNames = state.db
          .select('PRAGMA index_list(scheduled_tasks)')
          .map((row) => row['name'])
          .toList();
      expect(indexNames, contains('idx_scheduled_tasks_next_run'));

      // Task 139 adds the run history table beside the schedules it belongs to.
      expect(
        state.db.select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' "
          "AND name = 'scheduled_task_runs'",
        ),
        isNotEmpty,
      );
      expect(
        state.db
            .select('PRAGMA index_list(scheduled_task_runs)')
            .map((row) => row['name']),
        contains('idx_scheduled_task_runs_schedule_run_at'),
      );
    });
  });

  group('migration baseline', () {
    test('no user_version baseline is introduced by schema creation or migration', () {
      final databases = <String, Database>{
        _freshLabel: _openFreshInMemory().db,
        for (final fixture in _legacyFixtures)
          fixture: _openMigratedFixture(fixture).db,
      };

      for (final entry in databases.entries) {
        final version = entry.value
            .select('PRAGMA user_version')
            .single
            .values
            .single;
        expect(
          version,
          0,
          reason:
              '${entry.key} must stay on anonymous additive migration; a '
              'versioned baseline is a separate, unapproved change',
        );
      }
    });
  });
}

/// Opens the single production-shaped in-memory database for the current schema.
AgentStateDatabase _openFreshInMemory() {
  final state = AgentStateDatabase.inMemory();
  addTearDown(state.dispose);
  return state;
}

/// Seeds a legacy fixture into an in-memory connection and lets the current
/// owner migrate it in place, exactly as opening an old Home does.
AgentStateDatabase _openMigratedFixture(String fixture) {
  final raw = sqlite3.openInMemory();
  addTearDown(raw.dispose);
  raw.execute(File(_fixturePath(fixture)).readAsStringSync());
  return AgentStateDatabase.fromConnection(raw);
}

/// Writes absolute-path workspace references into an already created schema, so
/// the next open exercises the orphaned-reference migration.
void _seedOrphanedPathReferences(Database db, String legacyPath) {
  const instant = '2026-10-20T10:00:00.000Z';
  final metadata =
      '{"workspace_id":"$legacyPath",'
      '"workspace":{"id":"$legacyPath","display_name":"orphan-alpha"}}';

  db.execute(
    'INSERT INTO sessions (session_id, model, title, workspace_id, metadata, '
    'created_at, updated_at, last_user_message_at) '
    'VALUES (?, ?, ?, ?, NULL, ?, ?, ?)',
    <Object?>[
      'legacy_session_orphan',
      'legacy-model',
      'Legacy orphan thread',
      legacyPath,
      instant,
      instant,
      instant,
    ],
  );
  db.execute(
    'INSERT INTO session_work_items (work_item_id, session_id, request_id, '
    'sequence, workspace_id, payload_json, state, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      'legacy_work_item',
      'legacy_session_orphan',
      'legacy_request',
      1,
      legacyPath,
      metadata,
      'queued',
      instant,
      instant,
    ],
  );
  db.execute(
    'INSERT INTO session_suspended_runs (session_id, workspace_id, '
    'event_metadata, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
    <Object?>['legacy_session_orphan', legacyPath, metadata, instant, instant],
  );
  db.execute(
    'INSERT INTO session_pending_runs (session_id, workspace_id, '
    'event_metadata, seq, created_at) VALUES (?, ?, ?, ?, ?)',
    <Object?>['legacy_session_orphan', legacyPath, metadata, 1, instant],
  );
}

Map<String, Row> _rowsBy(
  Database db,
  String sql,
  String keyColumn, {
  List<Object?> parameters = const <Object?>[],
}) {
  return <String, Row>{
    for (final row in db.select(sql, parameters)) row[keyColumn] as String: row,
  };
}

int _schemaObjectCount(Database db) => db
    .select(
      "SELECT COUNT(*) AS total FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
    )
    .single['total'] as int;

String _fixturePath(String fixture) =>
    p.join(_fixtureDirectory, '$fixture.sql');

String _snapshotPath(String label) =>
    p.join(_fixtureDirectory, '$label.schema.txt');

/// Compares the live schema with the committed snapshot for [label].
void _expectSchemaSnapshot(String label, Database db) {
  final rendered = _renderSchemaSnapshot(db, label);
  final snapshotFile = File(_snapshotPath(label));

  if (Platform.environment[_updateSnapshotVariable] == '1') {
    snapshotFile.parent.createSync(recursive: true);
    snapshotFile.writeAsStringSync(rendered);
  }

  if (!snapshotFile.existsSync()) {
    fail(
      'Missing schema snapshot ${_snapshotPath(label)}. Regenerate it with '
      '$_updateSnapshotVariable=1.',
    );
  }

  final expected = snapshotFile.readAsStringSync().replaceAll('\r\n', '\n');
  final actualLines = rendered.split('\n');
  final expectedLines = expected.split('\n');
  final lineCount = math.max(actualLines.length, expectedLines.length);
  for (var index = 0; index < lineCount; index++) {
    final actualLine = index < actualLines.length
        ? actualLines[index]
        : '<missing>';
    final expectedLine = index < expectedLines.length
        ? expectedLines[index]
        : '<missing>';
    if (actualLine != expectedLine) {
      fail(
        'Schema snapshot "$label" differs from ${_snapshotPath(label)} at '
        'line ${index + 1}.\n'
        'expected: $expectedLine\n'
        'actual:   $actualLine\n'
        'This file characterizes existing behavior; a schema change requires a '
        'deliberate snapshot update with $_updateSnapshotVariable=1.',
      );
    }
  }
}

/// Renders the complete structural description of [db] used by the snapshots.
String _renderSchemaSnapshot(Database db, String label) {
  final out = StringBuffer()
    ..writeln('# Agent-state schema snapshot (SRP 138-05).')
    ..writeln('# Generated by $_fixtureTestPath; do not edit by hand.')
    ..writeln('# Whitespace is canonicalized; every token and its order is pinned.')
    ..writeln('# label: $label');

  final objects = db.select(
    "SELECT type, name, tbl_name, sql FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite_%' ORDER BY type ASC, name ASC",
  );
  out.writeln('[sqlite_master] objects=${objects.length}');
  for (final row in objects) {
    out
      ..writeln('  ${row['type']} ${row['name']} (on ${row['tbl_name']})')
      ..writeln('    ${_canonicalSql(row['sql']?.toString() ?? '')}');
  }

  for (final table in _tableNames(db)) {
    out.writeln('[table_info] $table');
    for (final column in db.select('PRAGMA table_info($table)')) {
      out.writeln(
        '  ${column['name']}|type=${column['type']}'
        '|notnull=${column['notnull']}'
        '|default=${column['dflt_value'] ?? '<none>'}'
        '|pk=${column['pk']}',
      );
    }

    out.writeln('[index_list] $table');
    final indexes = db
        .select('PRAGMA index_list($table)')
        .map((row) => Map<String, Object?>.from(row))
        .toList()
      ..sort((left, right) {
        return (left['name'] as String).compareTo(right['name'] as String);
      });
    for (final index in indexes) {
      final name = index['name'] as String;
      final columns = db
          .select('PRAGMA index_info($name)')
          .map((row) => row['name'] ?? '<expression>')
          .join(',');
      out.writeln(
        '  $name|unique=${index['unique']}|origin=${index['origin']}'
        '|partial=${index['partial']}|columns=$columns',
      );
    }

    final foreignKeys = db.select('PRAGMA foreign_key_list($table)');
    if (foreignKeys.isNotEmpty) {
      out.writeln('[foreign_key_list] $table');
      for (final foreignKey in foreignKeys) {
        out.writeln(
          '  ${foreignKey['from']}->${foreignKey['table']}'
          '.${foreignKey['to']}'
          '|on_update=${foreignKey['on_update']}'
          '|on_delete=${foreignKey['on_delete']}',
        );
      }
    }
  }

  return out.toString();
}

List<String> _tableNames(Database db) => db
    .select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name ASC",
    )
    .map((row) => row['name'] as String)
    .toList();

/// Collapses whitespace and normalizes spacing around `,` and `)` so a verbatim
/// move that only re-indents the DDL keeps the snapshot stable.
String _canonicalSql(String sql) {
  return sql
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s*,\s*'), ', ')
      .replaceAll(RegExp(r'\s*\)'), ')')
      .replaceAll(RegExp(r'\)\s*(?=[A-Za-z])'), ') ')
      .trim();
}

const String _fixtureTestPath =
    'agent/test/evolution/agent_state_schema_snapshot_test.dart';
