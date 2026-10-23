import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// The scheduling table as shipped before Task 112, which is also a Home that
/// predates `scheduled_task_runs`.
Database _pre139Database() {
  final db = sqlite3.openInMemory();
  db.execute('''
    CREATE TABLE scheduled_tasks (
      id TEXT PRIMARY KEY,
      task TEXT NOT NULL,
      run_at TEXT NOT NULL,
      session_id TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
  ''');
  db.execute(
    'INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at) '
    'VALUES (?, ?, ?, ?, ?)',
    <Object?>[
      'task_legacy',
      'Legacy task',
      '2026-10-25T14:30:00.000Z',
      'session_legacy',
      '2026-10-18T10:00:00.000Z',
    ],
  );
  return db;
}

/// Structural shape of both scheduling tables, used to prove that repeated
/// opens change nothing.
String _schemaFingerprint(Database db) {
  final objects = db
      .select(
        'SELECT type, name, sql FROM sqlite_master '
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
      )
      .map((row) => '${row['type']}|${row['name']}|${row['sql']}')
      .join('\n');
  final runsColumns = db
      .select('PRAGMA table_info(scheduled_task_runs)')
      .map(
        (row) =>
            '${row['name']}|${row['type']}|${row['notnull']}|'
            '${row['dflt_value']}|${row['pk']}',
      )
      .join('\n');
  final runsIndexes = db
      .select('PRAGMA index_list(scheduled_task_runs)')
      .map((row) => '${row['name']}|${row['unique']}|${row['origin']}')
      .join('\n');
  return '$objects\n$runsColumns\n$runsIndexes';
}

void main() {
  group('scheduled_task_runs schema (A3)', () {
    test('a fresh database has the documented columns in order', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);

      final columns = state.db
          .select('PRAGMA table_info(scheduled_task_runs)')
          .map((row) => row['name'] as String)
          .toList();
      expect(columns, <String>[
        'id',
        'schedule_id',
        'run_at',
        'status',
        'trigger',
        'duration_ms',
        'error',
        'session_id',
        'message_id',
        'created_at',
      ]);

      final info = <String, Row>{
        for (final row in state.db.select('PRAGMA table_info(scheduled_task_runs)'))
          row['name'] as String: row,
      };
      expect(info['id']!['pk'], 1);
      for (final required in <String>[
        'schedule_id',
        'run_at',
        'status',
        'trigger',
        'created_at',
      ]) {
        expect(info[required]!['notnull'], 1, reason: required);
      }
      for (final optional in <String>[
        'duration_ms',
        'error',
        'session_id',
        'message_id',
      ]) {
        expect(info[optional]!['notnull'], 0, reason: optional);
      }
      expect(info['duration_ms']!['type'], 'INTEGER');
      expect(info['run_at']!['type'], 'TEXT');
    });

    test('the schedule and run-time index exists', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);

      final indexes = state.db
          .select('PRAGMA index_list(scheduled_task_runs)')
          .map((row) => row['name'] as String)
          .toList();
      expect(indexes, contains('idx_scheduled_task_runs_schedule_run_at'));

      final columns = state.db
          .select('PRAGMA index_info(idx_scheduled_task_runs_schedule_run_at)')
          .map((row) => row['name'] as String)
          .toList();
      expect(columns, <String>['schedule_id', 'run_at']);
    });

    test('a pre-139 Home gains the table and three opens are no-ops', () {
      final db = _pre139Database();
      addTearDown(db.dispose);

      AgentStateDatabase.fromConnection(db);
      expect(
        db.select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' "
          "AND name = 'scheduled_task_runs'",
        ),
        isNotEmpty,
      );
      final schema = _schemaFingerprint(db);

      AgentStateDatabase.fromConnection(db);
      AgentStateDatabase.fromConnection(db);

      expect(_schemaFingerprint(db), schema);
    });
  });

  group('ScheduledTaskRunRepository', () {
    late AgentStateDatabase state;
    late ScheduledTaskRunRepository runs;

    setUp(() {
      state = AgentStateDatabase.inMemory();
      runs = ScheduledTaskRunRepository(state);
    });

    tearDown(() => state.dispose());

    test('startRun writes the running row every dispatch needs first', () {
      final runAt = DateTime.utc(2026, 10, 23, 9);
      final id = runs.startRun(
        id: 'run_1',
        scheduleId: 'task_1',
        runAt: runAt,
        trigger: ScheduledTaskRunTrigger.scheduled,
      );
      expect(id, 'run_1');

      final run = runs.getRun('run_1')!;
      expect(run.scheduleId, 'task_1');
      expect(run.runAt, runAt);
      expect(run.status, ScheduledTaskRunStatus.running);
      expect(run.trigger, ScheduledTaskRunTrigger.scheduled);
      expect(run.durationMs, isNull);
      expect(run.error, isNull);
      expect(run.sessionId, isNull);
      expect(run.messageId, isNull);
      expect(run.hasPosition, isFalse);
      expect(run.createdAt.isUtc, isTrue);
    });

    test('a minted run identity is a run_ microsecond timestamp', () {
      final id = runs.startRun(
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.manual,
      );
      expect(id, startsWith('run_'));
      expect(int.tryParse(id.substring(4)), isNotNull);
    });

    test('attachMessage records the run position and both identities', () {
      runs.startRun(
        id: 'run_anchor',
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      expect(
        runs.attachMessage(
          'run_anchor',
          sessionId: 'session_run',
          messageId: 'message_run',
        ),
        isTrue,
      );

      final run = runs.getRun('run_anchor')!;
      expect(run.sessionId, 'session_run');
      expect(run.messageId, 'message_run');
      expect(run.hasPosition, isTrue);
      expect(
        runs.attachMessage(
          'run_missing',
          sessionId: 'session_run',
          messageId: 'message_run',
        ),
        isFalse,
      );
    });

    test('completeRun reaches one terminal state and never rewrites it', () {
      runs.startRun(
        id: 'run_terminal',
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      expect(
        runs.completeRun(
          'run_terminal',
          status: ScheduledTaskRunStatus.succeeded,
          durationMs: 1200,
        ),
        isTrue,
      );
      var run = runs.getRun('run_terminal')!;
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.durationMs, 1200);
      expect(run.error, isNull);

      // A second observation of the same run changes nothing.
      expect(
        runs.completeRun(
          'run_terminal',
          status: ScheduledTaskRunStatus.failed,
          durationMs: 9999,
          error: 'late observation',
        ),
        isFalse,
      );
      run = runs.getRun('run_terminal')!;
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.durationMs, 1200);
      expect(run.error, isNull);

      expect(
        () => runs.completeRun(
          'run_terminal',
          status: ScheduledTaskRunStatus.running,
        ),
        throwsArgumentError,
      );
    });

    test('a failed run keeps its bounded error text', () {
      runs.startRun(
        id: 'run_failed',
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.manual,
      );
      runs.completeRun(
        'run_failed',
        status: ScheduledTaskRunStatus.failed,
        durationMs: 40,
        error: 'provider rejected the request',
      );

      final run = runs.getRun('run_failed')!;
      expect(run.status, ScheduledTaskRunStatus.failed);
      expect(run.error, 'provider rejected the request');
      expect(run.trigger, ScheduledTaskRunTrigger.manual);
    });

    test('a skipped occurrence is terminal and never carries a duration', () {
      runs.startRun(
        id: 'run_skipped',
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.recovery,
      );
      runs.completeRun('run_skipped', status: ScheduledTaskRunStatus.skipped);

      final run = runs.getRun('run_skipped')!;
      expect(run.status, ScheduledTaskRunStatus.skipped);
      expect(run.durationMs, isNull);
      expect(ScheduledTaskRunStatus.skipped.isTerminal, isTrue);
      expect(ScheduledTaskRunStatus.running.isTerminal, isFalse);
    });

    test('listRuns pages newest first with a keyset cursor', () {
      final base = DateTime.utc(2026, 10, 23, 9);
      for (var index = 0; index < 5; index++) {
        runs.startRun(
          id: 'run_$index',
          scheduleId: 'task_paged',
          runAt: base.add(Duration(minutes: index)),
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }
      runs.startRun(
        id: 'run_other',
        scheduleId: 'task_other',
        runAt: base.add(const Duration(hours: 1)),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      final firstPage = runs.listRuns('task_paged', limit: 2);
      expect(firstPage.runs.map((run) => run.id), <String>[
        'run_4',
        'run_3',
      ]);
      expect(firstPage.hasMore, isTrue);

      final last = firstPage.runs.last;
      final secondPage = runs.listRuns(
        'task_paged',
        limit: 2,
        before: last.runAt,
        beforeId: last.id,
      );
      expect(secondPage.runs.map((run) => run.id), <String>[
        'run_2',
        'run_1',
      ]);
      expect(secondPage.hasMore, isTrue);

      final tail = secondPage.runs.last;
      final thirdPage = runs.listRuns(
        'task_paged',
        limit: 2,
        before: tail.runAt,
        beforeId: tail.id,
      );
      expect(thirdPage.runs.map((run) => run.id), <String>['run_0']);
      expect(thirdPage.hasMore, isFalse);

      // A second schedule never leaks into the page.
      expect(
        runs.listRuns('task_paged').runs.map((run) => run.id),
        isNot(contains('run_other')),
      );
    });

    test('listRuns orders ties on identical instants by descending id', () {
      final instant = DateTime.utc(2026, 10, 23, 9);
      for (final id in <String>['run_a', 'run_c', 'run_b']) {
        runs.startRun(
          id: id,
          scheduleId: 'task_tied',
          runAt: instant,
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }

      expect(
        runs.listRuns('task_tied').runs.map((run) => run.id),
        <String>['run_c', 'run_b', 'run_a'],
      );
    });

    test('listing never prunes: retention is a write-side policy', () {
      final now = DateTime.utc(2026, 10, 23, 9);
      for (var index = 0; index < 205; index++) {
        runs.startRun(
          id: 'run_$index',
          scheduleId: 'task_many',
          runAt: now.subtract(Duration(minutes: index)),
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }

      runs.listRuns('task_many', limit: 200);
      expect(runs.countRuns('task_many'), 205);
    });

    test('prune keeps the newest 200 rows per schedule', () {
      final now = DateTime.utc(2026, 10, 23, 9);
      for (var index = 0; index < 205; index++) {
        runs.startRun(
          id: 'run_$index',
          scheduleId: 'task_many',
          runAt: now.subtract(Duration(minutes: index)),
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }

      expect(runs.pruneRetainedRuns('task_many', now: now), 5);
      expect(
        runs.countRuns('task_many'),
        ScheduledTaskRunRetention.maxRunsPerSchedule,
      );
      expect(runs.getRun('run_200'), isNull, reason: 'oldest rows go first');
      expect(runs.getRun('run_199'), isNotNull);
    });

    test('prune drops rows older than 90 days even inside the cap', () {
      final now = DateTime.utc(2026, 10, 23, 9);
      runs.startRun(
        id: 'run_stale',
        scheduleId: 'task_aged',
        runAt: now.subtract(const Duration(days: 91)),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );
      for (var index = 0; index < 3; index++) {
        runs.startRun(
          id: 'run_fresh_$index',
          scheduleId: 'task_aged',
          runAt: now.subtract(Duration(minutes: index)),
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }

      expect(runs.pruneRetainedRuns('task_aged', now: now), 1);
      expect(runs.getRun('run_stale'), isNull);
      expect(runs.countRuns('task_aged'), 3);
    });

    test('prune never touches another schedule', () {
      final now = DateTime.utc(2026, 10, 23, 9);
      runs.startRun(
        id: 'run_keep',
        scheduleId: 'task_keep',
        runAt: now.subtract(const Duration(days: 200)),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );
      runs.startRun(
        id: 'run_prune',
        scheduleId: 'task_prune',
        runAt: now.subtract(const Duration(days: 200)),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      expect(runs.pruneRetainedRuns('task_prune', now: now), 1);
      expect(runs.getRun('run_prune'), isNull);
      expect(runs.getRun('run_keep'), isNotNull);
    });

    test('deleteRunsForSchedule removes one schedule history only', () {
      for (final id in <String>['run_a', 'run_b']) {
        runs.startRun(
          id: id,
          scheduleId: 'task_deleted',
          runAt: DateTime.utc(2026, 10, 23, 9),
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }
      runs.startRun(
        id: 'run_kept',
        scheduleId: 'task_kept',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      expect(runs.deleteRunsForSchedule('task_deleted'), 2);
      expect(runs.countRuns('task_deleted'), 0);
      expect(runs.countRuns('task_kept'), 1);
      expect(runs.getRun('run_kept'), isNotNull);
    });

    test('unknown stored values fail closed and keep their wire names', () {
      state.db.execute(
        'INSERT INTO scheduled_task_runs '
        '(id, schedule_id, run_at, status, trigger, created_at) '
        "VALUES ('run_unknown', 'task_1', '2026-10-23T09:00:00.000Z', "
        "'interrupted', 'shadow', '2026-10-23T09:00:00.000Z')",
      );

      final run = runs.getRun('run_unknown')!;
      expect(
        run.status,
        ScheduledTaskRunStatus.failed,
        reason: 'an unknown outcome is never presented as in-flight',
      );
      expect(run.trigger, ScheduledTaskRunTrigger.scheduled);
      expect(ScheduledTaskRunStatus.succeeded.wireName, 'succeeded');
      expect(ScheduledTaskRunTrigger.manual.wireName, 'manual');
    });

    test('the run row carries no conversation title or content', () {
      runs.startRun(
        id: 'run_projection',
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 23, 9),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );
      final run = runs.getRun('run_projection')!;

      expect(
        run.toMap().keys,
        containsAll(<String>[
          'id',
          'schedule_id',
          'run_at',
          'status',
          'trigger',
          'duration_ms',
          'error',
          'session_id',
          'message_id',
          'created_at',
        ]),
      );
      expect(run.toMap().keys, hasLength(10));
    });
  });
}
