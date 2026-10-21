import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('Scheduled Tasks Database Storage and Migration (Gate A2, Decision D8)', () {
    test('fresh database contains all D8 columns', () {
      final stateDb = AgentStateDatabase.inMemory();
      addTearDown(stateDb.dispose);
      final db = stateDb.db;

      final columns = db
          .select('PRAGMA table_info(scheduled_tasks)')
          .map((row) => row['name']?.toString())
          .toSet();

      final expectedColumns = {
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
        'created_at',
        'updated_at',
        'last_run_at',
        'last_status',
        'enabled',
      };

      for (final col in expectedColumns) {
        expect(
          columns.contains(col),
          isTrue,
          reason: 'Column "$col" should exist in fresh scheduled_tasks table',
        );
      }
      expect(
        columns.contains('run_at'),
        isFalse,
        reason: 'Legacy column run_at should not exist in fresh table',
      );
    });

    test('old-shape database migrates to D8 schema preserving instant and setting defaults', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);

      // Create legacy table
      db.execute('''
        CREATE TABLE scheduled_tasks (
          id TEXT PRIMARY KEY,
          task TEXT NOT NULL,
          run_at TEXT NOT NULL,
          session_id TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
      ''');

      const legacyInstant = '2026-10-25T14:30:00.000Z';
      const legacyCreated = '2026-10-18T10:00:00.000Z';

      // Insert pre-existing row
      db.execute('''
        INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at)
        VALUES ('task_old_1', 'Legacy Task', '$legacyInstant', 'session_123', '$legacyCreated');
      ''');

      // Run migration
      AgentStateDatabase.migrateScheduledTasks(db);

      final columns = db
          .select('PRAGMA table_info(scheduled_tasks)')
          .map((row) => row['name']?.toString())
          .toSet();

      expect(columns.contains('next_run_at'), isTrue);
      expect(columns.contains('run_at'), isFalse);
      expect(columns.contains('kind'), isTrue);
      expect(columns.contains('zone'), isTrue);
      expect(columns.contains('enabled'), isTrue);
      expect(columns.contains('updated_at'), isTrue);

      final rows = db.select('SELECT * FROM scheduled_tasks WHERE id = ?', ['task_old_1']);
      expect(rows, hasLength(1));
      final row = rows.first;

      expect(row['id'], 'task_old_1');
      expect(row['task'], 'Legacy Task');
      expect(row['session_id'], 'session_123');
      expect(row['next_run_at'], legacyInstant);
      expect(row['kind'], 'once');
      expect(row['zone'], 'local');
      expect(row['enabled'], 1);
      expect(row['created_at'], legacyCreated);
      expect(row['updated_at'], legacyCreated);
    });

    test('second migration run is an idempotent no-op', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);

      // Create legacy table and row
      db.execute('''
        CREATE TABLE scheduled_tasks (
          id TEXT PRIMARY KEY,
          task TEXT NOT NULL,
          run_at TEXT NOT NULL,
          session_id TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
      ''');
      db.execute('''
        INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at)
        VALUES ('task_old_2', 'Legacy Task 2', '2026-10-30T10:00:00.000Z', 'session_abc', '2026-10-18T10:00:00.000Z');
      ''');

      // First run
      AgentStateDatabase.migrateScheduledTasks(db);

      // Second run
      expect(() => AgentStateDatabase.migrateScheduledTasks(db), returnsNormally);

      final rows = db.select('SELECT * FROM scheduled_tasks WHERE id = ?', ['task_old_2']);
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row['next_run_at'], '2026-10-30T10:00:00.000Z');
      expect(row['kind'], 'once');
      expect(row['zone'], 'local');
      expect(row['enabled'], 1);
    });

    test('SessionDB CRUD operations work with D8 columns', () {
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
    });
  });
}
