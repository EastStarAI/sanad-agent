import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// The `scheduled_tasks` table as shipped before Task 112 (main at `adc128ec`).
const _legacyCreateTable = '''
  CREATE TABLE scheduled_tasks (
    id TEXT PRIMARY KEY,
    task TEXT NOT NULL,
    run_at TEXT NOT NULL,
    session_id TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
''';

/// Raw statements copied verbatim from the pre-112 `ScheduledTaskRepository`.
/// An older agent (main today, or a rollback) on the same Home runs exactly
/// these, so they must keep working on migrated and freshly created tables.
const _legacyUpsert = '''
      INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        task = excluded.task,
        run_at = excluded.run_at,
        session_id = excluded.session_id;
    ''';
const _legacySelectAll = 'SELECT * FROM scheduled_tasks ORDER BY run_at ASC';
const _legacyDelete = 'DELETE FROM scheduled_tasks WHERE id = ?';

Set<String?> _columns(Database db) => db
    .select('PRAGMA table_info(scheduled_tasks)')
    .map((row) => row['name']?.toString())
    .toSet();

Database _legacyDatabase({List<List<Object?>> rows = const []}) {
  final db = sqlite3.openInMemory();
  db.execute(_legacyCreateTable);
  for (final row in rows) {
    db.execute(
      'INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      row,
    );
  }
  return db;
}

/// Exercises the pre-112 statements against [db] and checks what an older
/// agent would observe.
void _expectLegacyStatementsWork(Database db) {
  const instant = '2026-12-01T08:00:00.000Z';
  const moved = '2026-12-02T08:00:00.000Z';
  final upsert = db.prepare(_legacyUpsert);
  try {
    upsert.execute(['legacy_writer', 'Old agent task', instant, 's1', instant]);
    // ON CONFLICT path: the older agent rescheduling the same id.
    upsert.execute(['legacy_writer', 'Old agent task', moved, 's1', instant]);
  } finally {
    upsert.dispose();
  }

  final rows = db.select(_legacySelectAll);
  final written = rows.singleWhere((row) => row['id'] == 'legacy_writer');
  expect(written['run_at'], moved);
  expect(written['task'], 'Old agent task');
  expect(written['session_id'], 's1');

  db.execute(_legacyDelete, ['legacy_writer']);
  expect(
    db.select(_legacySelectAll).where((row) => row['id'] == 'legacy_writer'),
    isEmpty,
  );
}

void main() {
  group('Scheduled Tasks Database Storage and Migration (Gate A2, Decision D8)', () {
    test(
      'fresh database has the D8 columns plus the nullable legacy run_at',
      () {
        final stateDb = AgentStateDatabase.inMemory();
        addTearDown(stateDb.dispose);

        final columns = _columns(stateDb.db);
        for (final col in {
          'id',
          'task',
          'session_id',
          'kind',
          'interval_minutes',
          'at_time',
          'weekdays',
          'month_day',
          'zone',
          'next_run_at',
          'run_at',
          'created_at',
          'updated_at',
          'last_run_at',
          'last_status',
          'enabled',
        }) {
          expect(columns, contains(col));
        }

        final runAt = stateDb.db
            .select('PRAGMA table_info(scheduled_tasks)')
            .singleWhere((row) => row['name'] == 'run_at');
        expect(runAt['notnull'], 0, reason: 'run_at is nullable on new tables');
      },
    );

    test(
      'old table with rows migrates additively; both columns hold the same instant',
      () {
        const legacyInstant = '2026-10-25T14:30:00.000Z';
        const legacyCreated = '2026-10-18T10:00:00.000Z';
        final db = _legacyDatabase(
          rows: [
            [
              'task_old_1',
              'Legacy Task',
              legacyInstant,
              'session_123',
              legacyCreated,
            ],
            [
              'task_old_2',
              'Legacy Task 2',
              '2026-10-30T10:00:00.000Z',
              'session_abc',
              legacyCreated,
            ],
          ],
        );
        addTearDown(db.dispose);

        AgentStateDatabase.migrateScheduledTasks(db);

        final columns = _columns(db);
        expect(
          columns,
          containsAll([
            'run_at',
            'next_run_at',
            'kind',
            'zone',
            'enabled',
            'updated_at',
          ]),
        );

        final row = db.select('SELECT * FROM scheduled_tasks WHERE id = ?', [
          'task_old_1',
        ]).single;
        expect(row['task'], 'Legacy Task');
        expect(row['session_id'], 'session_123');
        expect(row['run_at'], legacyInstant);
        expect(row['next_run_at'], legacyInstant);
        expect(row['kind'], 'once');
        expect(row['zone'], 'local');
        expect(row['enabled'], 1);
        expect(row['created_at'], legacyCreated);
        expect(row['updated_at'], legacyCreated);

        for (final migrated in db.select(
          'SELECT run_at, next_run_at FROM scheduled_tasks',
        )) {
          expect(migrated['next_run_at'], migrated['run_at']);
        }
      },
    );

    test('second migration run is an idempotent no-op', () {
      final db = _legacyDatabase(
        rows: [
          [
            'task_old_2',
            'Legacy Task 2',
            '2026-10-30T10:00:00.000Z',
            'session_abc',
            '2026-10-18T10:00:00.000Z',
          ],
        ],
      );
      addTearDown(db.dispose);

      AgentStateDatabase.migrateScheduledTasks(db);
      final columnsAfterFirst = _columns(db);
      final rowAfterFirst = db.select('SELECT * FROM scheduled_tasks').single;

      expect(
        () => AgentStateDatabase.migrateScheduledTasks(db),
        returnsNormally,
      );

      expect(_columns(db), columnsAfterFirst);
      final row = db.select('SELECT * FROM scheduled_tasks').single;
      for (final key in rowAfterFirst.keys) {
        expect(row[key], rowAfterFirst[key], reason: key);
      }
    });

    test(
      'writes succeed on an old table where run_at is NOT NULL and keep both columns equal',
      () {
        final db = _legacyDatabase();
        addTearDown(db.dispose);
        final stateDb = AgentStateDatabase.fromConnection(db);
        final sessionDb = SessionDB.fromState(stateDb);

        final runAtColumn = db
            .select('PRAGMA table_info(scheduled_tasks)')
            .singleWhere((row) => row['name'] == 'run_at');
        expect(runAtColumn['notnull'], 1, reason: 'legacy constraint is kept');

        final first = DateTime.utc(2026, 11, 1, 9);
        final second = DateTime.utc(2026, 11, 2, 9);
        sessionDb.saveScheduledTask(
          'task_on_old_table',
          'Daily on old table',
          first,
          'session_old',
          kind: 'daily',
          atTime: '09:00',
          zone: 'Z',
        );
        // ON CONFLICT path, as every recurring advance uses.
        sessionDb.saveScheduledTask(
          'task_on_old_table',
          'Daily on old table',
          second,
          'session_old',
          kind: 'daily',
          atTime: '09:00',
          zone: 'Z',
          lastStatus: 'fired',
        );

        final raw = db.select(
          'SELECT run_at, next_run_at FROM scheduled_tasks WHERE id = ?',
          ['task_on_old_table'],
        ).single;
        expect(raw['next_run_at'], second.toIso8601String());
        expect(raw['run_at'], second.toIso8601String());
        expect(
          sessionDb.getScheduledTask('task_on_old_table')!['next_run_at'],
          second.toIso8601String(),
        );
      },
    );

    test('pre-112 raw INSERT/SELECT/DELETE still work on a migrated table', () {
      final db = _legacyDatabase(
        rows: [
          [
            'task_old_1',
            'Legacy Task',
            '2026-10-25T14:30:00.000Z',
            'session_123',
            '2026-10-18T10:00:00.000Z',
          ],
        ],
      );
      addTearDown(db.dispose);
      AgentStateDatabase.fromConnection(db);

      _expectLegacyStatementsWork(db);
      expect(
        db.select(_legacySelectAll).single['run_at'],
        '2026-10-25T14:30:00.000Z',
        reason: 'migrated rows stay readable through run_at',
      );
    });

    test(
      'pre-112 raw INSERT/SELECT/DELETE work on a freshly created table and see current writes',
      () {
        final stateDb = AgentStateDatabase.inMemory();
        addTearDown(stateDb.dispose);
        final sessionDb = SessionDB.fromState(stateDb);

        _expectLegacyStatementsWork(stateDb.db);

        final nextRunAt = DateTime.utc(2026, 11, 3, 7);
        sessionDb.saveScheduledTask(
          'task_new',
          'New writer',
          nextRunAt,
          'session_new',
        );
        final seenByOldAgent = stateDb.db.select(_legacySelectAll).single;
        expect(seenByOldAgent['id'], 'task_new');
        expect(seenByOldAgent['run_at'], nextRunAt.toIso8601String());
      },
    );

    test(
      'rows written by an older agent are resynchronized at the next open',
      () {
        final db = _legacyDatabase();
        addTearDown(db.dispose);
        final sessionDb = SessionDB.fromState(
          AgentStateDatabase.fromConnection(db),
        );
        sessionDb.saveScheduledTask(
          'task_shared',
          'Shared',
          DateTime.utc(2026, 11, 1, 9),
          's1',
        );

        // A rollback agent inserts a new row and reschedules the shared one.
        final upsert = db.prepare(_legacyUpsert);
        upsert.execute([
          'task_rollback',
          'From old agent',
          '2026-11-05T10:00:00.000Z',
          's2',
          '2026-11-01T00:00:00.000Z',
        ]);
        upsert.execute([
          'task_shared',
          'Shared',
          '2026-11-04T09:00:00.000Z',
          's1',
          '2026-11-01T00:00:00.000Z',
        ]);
        upsert.dispose();

        // The current agent opens the same Home again.
        final reopened = SessionDB.fromState(
          AgentStateDatabase.fromConnection(db),
        );
        expect(
          reopened.getScheduledTask('task_rollback')!['next_run_at'],
          '2026-11-05T10:00:00.000Z',
        );
        expect(
          reopened.getScheduledTask('task_rollback')!['updated_at'],
          '2026-11-01T00:00:00.000Z',
        );
        expect(
          reopened.getScheduledTask('task_shared')!['next_run_at'],
          '2026-11-04T09:00:00.000Z',
        );
      },
    );

    test(
      'SessionDB CRUD operations work with D8 columns and read next_run_at only',
      () {
        final stateDb = AgentStateDatabase.inMemory();
        addTearDown(stateDb.dispose);
        final sessionDb = SessionDB.fromState(stateDb);

        final nextRunAt = DateTime.utc(2026, 11, 1, 9, 0);
        sessionDb.saveScheduledTask(
          'task_crud_1',
          'Recurring Daily',
          nextRunAt,
          'session_crud',
          kind: 'daily',
          atTime: '09:00',
          zone: 'local',
        );

        final retrieved = sessionDb.getScheduledTask('task_crud_1');
        expect(retrieved, isNotNull);
        expect(retrieved!['task'], 'Recurring Daily');
        expect(retrieved['kind'], 'daily');
        expect(retrieved['at_time'], '09:00');
        expect(retrieved['zone'], 'local');
        expect(retrieved['enabled'], 1);
        expect(retrieved['next_run_at'], nextRunAt.toIso8601String());
        expect(retrieved.containsKey('run_at'), isFalse);

        final all = sessionDb.getAllScheduledTasks();
        expect(all.any((t) => t['id'] == 'task_crud_1'), isTrue);
        expect(all.first.containsKey('run_at'), isFalse);

        sessionDb.deleteScheduledTask('task_crud_1');
        expect(sessionDb.getScheduledTask('task_crud_1'), isNull);
      },
    );
  });

  group('Task 139 owner, conversation, and route columns (A1)', () {
    test('a fresh database has the seven columns with their defaults', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);

      final columns = <String, Row>{
        for (final row in stateDb.db.select('PRAGMA table_info(scheduled_tasks)'))
          row['name'] as String: row,
      };

      expect(columns['name']!['notnull'], 0);
      expect(columns['name']!['dflt_value'], isNull);
      expect(columns['owner_kind']!['notnull'], 1);
      expect(columns['owner_kind']!['dflt_value'], "'model'");
      expect(columns['conversation_mode']!['notnull'], 1);
      expect(columns['conversation_mode']!['dflt_value'], "'continuous'");
      for (final optional in <String>[
        'run_session_id',
        'workspace_id',
        'provider_instance_id',
        'model',
      ]) {
        expect(columns[optional]!['notnull'], 0, reason: optional);
        expect(columns[optional]!['dflt_value'], isNull, reason: optional);
      }

      // An INSERT that names none of the seven values takes the column
      // defaults: model-owned, one continuous conversation, no route.
      stateDb.db.execute(
        'INSERT INTO scheduled_tasks (id, task, session_id, created_at) '
        'VALUES (?, ?, ?, ?)',
        <Object?>[
          'task_defaults',
          'Defaults',
          'session_defaults',
          '2026-10-23T09:00:00.000Z',
        ],
      );
      final row = stateDb.db
          .select('SELECT * FROM scheduled_tasks WHERE id = ?', <Object?>[
            'task_defaults',
          ])
          .single;
      expect(row['owner_kind'], 'model');
      expect(row['conversation_mode'], 'continuous');
      expect(row['name'], isNull);
      expect(row['run_session_id'], isNull);
    });

    test('a pre-112 Home gains the columns and keeps every row model-owned', () {
      const legacyInstant = '2026-10-25T14:30:00.000Z';
      final db = _legacyDatabase(
        rows: <List<Object?>>[
          <Object?>[
            'task_legacy_139',
            'Legacy task',
            legacyInstant,
            'session_139',
            '2026-10-18T10:00:00.000Z',
          ],
        ],
      );
      addTearDown(db.dispose);

      AgentStateDatabase.fromConnection(db);

      final row = db.select('SELECT * FROM scheduled_tasks').single;
      expect(row['task'], 'Legacy task');
      expect(row['next_run_at'], legacyInstant);
      expect(row['owner_kind'], 'model');
      expect(row['conversation_mode'], 'continuous');
      expect(row['name'], isNull);
      expect(row['run_session_id'], isNull);
      expect(row['workspace_id'], isNull);
      expect(row['provider_instance_id'], isNull);
      expect(row['model'], isNull);
    });

    test('three consecutive migrations are no-ops for every shape', () {
      final pre112 = _legacyDatabase(
        rows: <List<Object?>>[
          <Object?>[
            'task_pre_112',
            'Pre 112',
            '2026-10-25T14:30:00.000Z',
            'session_a',
            '2026-10-18T10:00:00.000Z',
          ],
        ],
      );
      addTearDown(pre112.dispose);

      final current = AgentStateDatabase.inMemory();
      addTearDown(current.dispose);
      SessionDB.fromState(current).saveScheduledTask(
        'task_current',
        'Current shape',
        DateTime.utc(2026, 11, 1, 9),
        'session_b',
        kind: 'daily',
        atTime: '09:00',
        zone: 'Z',
        name: 'Current',
        ownerKind: 'user',
        conversationMode: 'new_each_run',
        workspaceId: 'workspace_b',
        providerInstanceId: 'provider_b',
        model: 'model_b',
      );

      for (final entry in <String, Database>{
        'pre-112': pre112,
        'current': current.db,
      }.entries) {
        AgentStateDatabase.fromConnection(entry.value);
        final schema = _schemaFingerprint(entry.value);
        final rows = _rowFingerprint(entry.value);

        // A second and a third pass, as three daemon starts on one Home run
        // the migration again.
        AgentStateDatabase.fromConnection(entry.value);
        AgentStateDatabase.migrateScheduledTasks(entry.value);

        expect(_schemaFingerprint(entry.value), schema, reason: entry.key);
        expect(_rowFingerprint(entry.value), rows, reason: entry.key);
      }

      final row = current.db.select('SELECT * FROM scheduled_tasks').single;
      expect(row['owner_kind'], 'user');
      expect(row['conversation_mode'], 'new_each_run');
      expect(row['name'], 'Current');
      expect(row['workspace_id'], 'workspace_b');
      expect(row['provider_instance_id'], 'provider_b');
      expect(row['model'], 'model_b');
    });

    test('fromRow defaults an old row and ignores blank or unknown values', () {
      final legacyRow = <String, dynamic>{
        'id': 'task_old',
        'task': 'Old task',
        'session_id': 'session_old',
        'kind': 'daily',
        'interval_minutes': null,
        'at_time': '09:00',
        'weekdays': null,
        'month_day': null,
        'zone': 'Z',
        'next_run_at': '2026-11-01T09:00:00.000Z',
        'created_at': '2026-10-01T09:00:00.000Z',
        'updated_at': '2026-10-01T09:00:00.000Z',
        'last_run_at': null,
        'last_status': null,
        'enabled': 1,
      };

      // A pre-139 row reaches the decoder without the seven columns at all
      // (read-only inspection never migrates).
      final record = ScheduledTaskRecord.fromRow(legacyRow);
      expect(record.name, isNull);
      expect(record.ownerKind, ScheduleOwnerKind.model);
      expect(record.conversationMode, ScheduleConversationMode.continuous);
      expect(record.runSessionId, isNull);
      expect(record.workspaceId, isNull);
      expect(record.providerInstanceId, isNull);
      expect(record.model, isNull);

      final blank = ScheduledTaskRecord.fromRow(<String, dynamic>{
        ...legacyRow,
        'name': '   ',
        'owner_kind': '',
        'conversation_mode': '',
        'run_session_id': '',
        'workspace_id': '  ',
        'provider_instance_id': '',
        'model': '',
      });
      expect(blank.name, isNull);
      expect(blank.ownerKind, ScheduleOwnerKind.model);
      expect(blank.conversationMode, ScheduleConversationMode.continuous);
      expect(blank.runSessionId, isNull);
      expect(blank.workspaceId, isNull);
      expect(blank.providerInstanceId, isNull);
      expect(blank.model, isNull);

      final unknown = ScheduledTaskRecord.fromRow(<String, dynamic>{
        ...legacyRow,
        'owner_kind': 'device',
        'conversation_mode': 'per_run',
      });
      expect(
        unknown.ownerKind,
        ScheduleOwnerKind.model,
        reason: 'an unknown kind keeps the most restrictive authority',
      );
      expect(unknown.conversationMode, ScheduleConversationMode.continuous);
    });

    test('the seven fields round-trip through save, read, and the row map', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = ScheduledTaskRepository(stateDb);

      // A user-owned `continuous` schedule that never ran keeps an empty
      // session id (D1): no payload may present it as an identity.
      const emptySession = '';
      final nextRunAt = DateTime.utc(2026, 11, 2, 9);
      repository.saveScheduledTask(
        'task_round_trip',
        'Summarise the open items.',
        nextRunAt,
        emptySession,
        kind: 'daily',
        atTime: '09:00',
        zone: '+03:00',
        name: 'Morning brief',
        ownerKind: 'user',
        conversationMode: 'new_each_run',
        runSessionId: 'session_run',
        workspaceId: 'workspace_uuid',
        providerInstanceId: 'provider_uuid',
        model: 'model-id',
      );

      final record = ScheduledTaskRecord.fromRow(
        repository.getScheduledTask('task_round_trip')!,
      );
      expect(record.sessionId, emptySession);
      expect(record.name, 'Morning brief');
      expect(record.ownerKind, ScheduleOwnerKind.user);
      expect(record.conversationMode, ScheduleConversationMode.newEachRun);
      expect(record.runSessionId, 'session_run');
      expect(record.workspaceId, 'workspace_uuid');
      expect(record.providerInstanceId, 'provider_uuid');
      expect(record.model, 'model-id');

      final decodedAgain = ScheduledTaskRecord.fromRow(record.toMap());
      expect(decodedAgain.name, record.name);
      expect(decodedAgain.ownerKind, record.ownerKind);
      expect(decodedAgain.conversationMode, record.conversationMode);
      expect(decodedAgain.runSessionId, record.runSessionId);
      expect(decodedAgain.workspaceId, record.workspaceId);
      expect(decodedAgain.providerInstanceId, record.providerInstanceId);
      expect(decodedAgain.model, record.model);
      expect(decodedAgain.kind, ScheduleKind.daily);
      expect(decodedAgain.nextRunAt, nextRunAt);
    });

    test('an omitted write stores the column defaults callers rely on', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = ScheduledTaskRepository(stateDb);

      repository.saveScheduledTask(
        'task_omitted',
        'Legacy caller',
        DateTime.utc(2026, 11, 3, 9),
        'session_omitted',
      );

      final record = ScheduledTaskRecord.fromRow(
        repository.getScheduledTask('task_omitted')!,
      );
      expect(record.ownerKind, ScheduleOwnerKind.model);
      expect(record.conversationMode, ScheduleConversationMode.continuous);
      expect(record.name, isNull);
      expect(record.runSessionId, isNull);
      expect(record.workspaceId, isNull);
      expect(record.providerInstanceId, isNull);
      expect(record.model, isNull);
    });
  });

  group('Task 139 settings persistence (D5)', () {
    /// A user-owned schedule with every Task 139 column set, as item 139-04
    /// will create it from the Client form.
    ScheduledTaskRepository seedUserOwned(AgentStateDatabase stateDb) {
      final repository = ScheduledTaskRepository(stateDb);
      repository.saveScheduledTask(
        'task_user',
        'Nightly report',
        DateTime.utc(2026, 11, 2, 9),
        '',
        kind: 'daily',
        atTime: '09:00',
        zone: 'Z',
        updatedAt: DateTime.utc(2026, 10, 1, 9),
        name: 'Nightly',
        ownerKind: 'user',
        conversationMode: 'new_each_run',
        runSessionId: 'session_run',
        workspaceId: 'workspace_uuid',
        providerInstanceId: 'provider_uuid',
        model: 'model-id',
      );
      return repository;
    }

    test('a scheduler re-save keeps all seven Task 139 columns', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = seedUserOwned(stateDb);

      // Every `CronScheduler` save passes the legacy parameters only, so a
      // re-save after a run must not touch the Task 139 columns at all.
      repository.saveScheduledTask(
        'task_user',
        'Nightly report',
        DateTime.utc(2026, 11, 3, 9),
        '',
        kind: 'daily',
        atTime: '09:00',
        zone: 'Z',
        lastRunAt: DateTime.utc(2026, 11, 2, 9),
        lastStatus: 'fired',
      );

      final row = repository.getScheduledTask('task_user')!;
      expect(row['owner_kind'], 'user');
      expect(row['name'], 'Nightly');
      expect(row['conversation_mode'], 'new_each_run');
      expect(row['run_session_id'], 'session_run');
      expect(row['workspace_id'], 'workspace_uuid');
      expect(row['provider_instance_id'], 'provider_uuid');
      expect(row['model'], 'model-id');

      // The recurrence and lifecycle columns still advance.
      expect(
        row['next_run_at'],
        DateTime.utc(2026, 11, 3, 9).toIso8601String(),
      );
      expect(row['last_status'], 'fired');
    });

    test('a later save cannot change owner_kind or the insert-only columns', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = seedUserOwned(stateDb);

      repository.saveScheduledTask(
        'task_user',
        'Nightly report',
        DateTime.utc(2026, 11, 4, 9),
        '',
        kind: 'daily',
        atTime: '09:00',
        zone: 'Z',
        name: 'Renamed by a save',
        ownerKind: 'model',
        conversationMode: 'continuous',
        model: 'other-model',
      );

      final row = repository.getScheduledTask('task_user')!;
      expect(
        row['owner_kind'],
        'user',
        reason: 'a model turn must never take over a user-owned schedule',
      );
      expect(row['name'], 'Nightly');
      expect(row['conversation_mode'], 'new_each_run');
      expect(row['model'], 'model-id');
    });

    test('updateScheduleSettings changes only the passed values', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = seedUserOwned(stateDb);
      final sessionDb = SessionDB.fromState(stateDb);

      expect(
        sessionDb.updateScheduleSettings('task_user', runSessionId: 'session_2'),
        isTrue,
        reason: 'the facade delegates to the repository',
      );

      final row = repository.getScheduledTask('task_user')!;
      expect(row['run_session_id'], 'session_2');
      expect(row['name'], 'Nightly');
      expect(row['conversation_mode'], 'new_each_run');
      expect(row['workspace_id'], 'workspace_uuid');
      expect(row['provider_instance_id'], 'provider_uuid');
      expect(row['model'], 'model-id');
      expect(row['owner_kind'], 'user');
      expect(
        row['updated_at'],
        isNot(DateTime.utc(2026, 10, 1, 9).toIso8601String()),
        reason: 'an update bumps updated_at',
      );
    });

    test('updateScheduleSettings clears a passed null and nothing else', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = seedUserOwned(stateDb);

      expect(
        repository.updateScheduleSettings(
          'task_user',
          name: null,
          workspaceId: null,
          model: null,
        ),
        isTrue,
      );

      final row = repository.getScheduledTask('task_user')!;
      expect(row['name'], isNull);
      expect(row['workspace_id'], isNull);
      expect(row['model'], isNull);
      expect(row['conversation_mode'], 'new_each_run');
      expect(row['run_session_id'], 'session_run');
      expect(row['provider_instance_id'], 'provider_uuid');
      expect(row['owner_kind'], 'user');
    });

    test('updateScheduleSettings never touches an unknown row or owner_kind', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final repository = seedUserOwned(stateDb);
      final before = repository.getScheduledTask('task_user')!;

      // No parameters: nothing to write, and updated_at must not move.
      expect(repository.updateScheduleSettings('task_user'), isFalse);
      final after = repository.getScheduledTask('task_user')!;
      expect(after['updated_at'], before['updated_at']);

      expect(
        repository.updateScheduleSettings('task_missing', name: 'Ghost'),
        isFalse,
      );
      expect(repository.getScheduledTask('task_missing'), isNull);
      expect(repository.getScheduledTask('task_user')!['owner_kind'], 'user');
      expect(
        () => repository.updateScheduleSettings('task_user', model: 7),
        throwsArgumentError,
      );
    });
  });
}

/// Column, index, and DDL shape of `scheduled_tasks`, used to prove repeated
/// migrations change nothing.
String _schemaFingerprint(Database db) {
  final objects = db
      .select(
        'SELECT type, name, sql FROM sqlite_master '
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
      )
      .map((row) => '${row['type']}|${row['name']}|${row['sql']}')
      .join('\n');
  final columns = db
      .select('PRAGMA table_info(scheduled_tasks)')
      .map(
        (row) =>
            '${row['name']}|${row['type']}|${row['notnull']}|'
            '${row['dflt_value']}|${row['pk']}',
      )
      .join('\n');
  final indexes = db
      .select('PRAGMA index_list(scheduled_tasks)')
      .map((row) => '${row['name']}|${row['unique']}|${row['origin']}')
      .join('\n');
  return '$objects\n$columns\n$indexes';
}

/// Every stored `scheduled_tasks` value, used to prove repeated migrations are
/// row-idempotent.
String _rowFingerprint(Database db) => db
    .select('SELECT * FROM scheduled_tasks ORDER BY id ASC')
    .map(
      (row) => Map<String, dynamic>.from(row).entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(','),
    )
    .join('\n');
