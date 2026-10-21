import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
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
}
