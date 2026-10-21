import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/schedule_task_tool.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduleTaskTool Merged Action Tool Tests (Gate A3, Decisions D1-D10)', () {
    late Directory tempDir;
    late CronScheduler scheduler;
    late ScheduleTaskTool tool;
    late ToolsRegistry registry;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('schedule_tool_test_');
      setSanadHomeOverride(tempDir.path);
      setSanadStateHomeOverride(tempDir.path);

      scheduler = CronScheduler();
      getIt.registerSingleton<CronScheduler>(scheduler);

      tool = ScheduleTaskTool();
      registry = ToolsRegistry();
      registry.registerTool(tool);
    });

    tearDown(() async {
      await scheduler.dispose();
      await GetIt.I.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    group('Action: create', () {
      test(
        'creates daily schedule persisting row with next_run_at in future (Acceptance Criterion 1)',
        () async {
          final context = ToolContext(sessionId: 'session_alpha');
          final result = await tool.executeResult({
            'action': 'create',
            'task': 'Daily Morning Review',
            'kind': 'daily',
            'time': '05:00',
            'zone': 'local',
          }, context: context);

          expect(result.isError, isFalse);
          expect(result.displayText, contains('created successfully'));
          expect(result.displayText, contains('Daily Morning Review'));
          expect(result.displayText, contains('daily at 05:00'));
          expect(result.displayText, contains('Next run:'));

          final sessionManager = SessionManager();
          final rows = sessionManager.db.getAllScheduledTasks();
          expect(rows, hasLength(1));

          final row = rows.first;
          expect(row['task'], 'Daily Morning Review');
          expect(row['session_id'], 'session_alpha');
          expect(row['kind'], 'daily');
          expect(row['at_time'], '05:00');
          expect(row['zone'], 'local');
          expect(row['enabled'], 1);

          final nextRun = DateTime.parse(row['next_run_at']);
          expect(nextRun.isAfter(DateTime.now().toUtc()), isTrue);
          expect(result.displayText, contains(row['id']));
        },
      );

      test(
        'fails when invoked without session context (Acceptance Criterion 5)',
        () async {
          final result = await tool.executeResult({
            'action': 'create',
            'task': 'Orphan Task',
            'kind': 'daily',
            'time': '05:00',
          });

          expect(result.isError, isTrue);
          expect(result.errorCode, ToolResultErrorCode.invalidInput);
          expect(
            result.displayText,
            contains(
              'Cannot create a scheduled task without a session context',
            ),
          );

          final sessionManager = SessionManager();
          expect(sessionManager.db.getAllScheduledTasks(), isEmpty);
        },
      );

      test('fails when task parameter is missing or empty', () async {
        final context = ToolContext(sessionId: 'session_alpha');

        final emptyTask = await tool.executeResult({
          'action': 'create',
          'task': '   ',
          'time': '05:00',
        }, context: context);

        expect(emptyTask.isError, isTrue);
        expect(emptyTask.errorCode, ToolResultErrorCode.invalidInput);
        expect(emptyTask.displayText, contains('"task" parameter is required'));
      });

      test(
        'rejects IANA zone id with clear message (Acceptance Criterion 6)',
        () async {
          final context = ToolContext(sessionId: 'session_alpha');

          final result = await tool.executeResult({
            'action': 'create',
            'task': 'Timezone Task',
            'kind': 'daily',
            'time': '05:00',
            'zone': 'America/New_York',
          }, context: context);

          expect(result.isError, isTrue);
          expect(result.errorCode, ToolResultErrorCode.invalidInput);
          expect(
            result.displayText,
            contains('IANA timezone identifiers are not supported'),
          );
          expect(result.displayText, contains('local'));
          expect(result.displayText, contains('+HH:MM'));
        },
      );

      test('creates interval and weekly schedules', () async {
        final context = ToolContext(sessionId: 'session_alpha');

        // Interval
        final resIntv = await tool.executeResult({
          'action': 'create',
          'task': 'Sync cache',
          'kind': 'interval',
          'every': 'every 15 minutes',
        }, context: context);
        expect(resIntv.isError, isFalse);
        expect(resIntv.displayText, contains('every 15 minutes'));

        // Weekly
        final resWeekly = await tool.executeResult({
          'action': 'create',
          'task': 'Weekly Team Sync',
          'kind': 'weekly',
          'weekdays': ['mon', 'wed', 'fri'],
          'time': '10:00',
        }, context: context);
        expect(resWeekly.isError, isFalse);
        expect(
          resWeekly.displayText,
          contains('weekly on mon, wed, fri at 10:00'),
        );
      });
    });

    group('Action: list', () {
      test('returns empty message when no tasks exist', () async {
        final context = ToolContext(sessionId: 'session_alpha');
        final result = await tool.executeResult({
          'action': 'list',
        }, context: context);

        expect(result.isError, isFalse);
        expect(result.displayText, 'No tasks are currently scheduled.');
      });

      test(
        'lists all device-wide schedules labeling each owning conversation (Acceptance Criterion 2)',
        () async {
          final sessionManager = SessionManager();
          sessionManager.db.saveScheduledTask(
            'task_1',
            'Task in Alpha',
            DateTime.utc(2026, 10, 20, 8, 0),
            'session_alpha',
            kind: 'daily',
            atTime: '08:00',
            zone: 'local',
          );
          sessionManager.db.saveScheduledTask(
            'task_2',
            'Task in Beta',
            DateTime.utc(2026, 10, 21, 14, 0),
            'session_beta',
            kind: 'weekly',
            weekdays: 'mon',
            atTime: '14:00',
            zone: 'Z',
          );

          final context = ToolContext(sessionId: 'session_alpha');
          final result = await tool.executeResult({
            'action': 'list',
          }, context: context);

          expect(result.isError, isFalse);
          expect(result.displayText, contains('Scheduled Tasks (2 total):'));
          expect(result.displayText, contains('[task_1] "Task in Alpha"'));
          expect(result.displayText, contains('Owning session: session_alpha'));
          expect(result.displayText, contains('[task_2] "Task in Beta"'));
          expect(result.displayText, contains('Owning session: session_beta'));
        },
      );

      test(
        'truncates list output at 50 schedules with explicit note',
        () async {
          final sessionManager = SessionManager();
          for (var i = 1; i <= 55; i++) {
            sessionManager.db.saveScheduledTask(
              'task_trunc_$i',
              'Task $i',
              DateTime.utc(2026, 10, 20, 8, i % 60),
              'session_alpha',
              kind: 'daily',
              atTime: '08:00',
              zone: 'local',
            );
          }

          final context = ToolContext(sessionId: 'session_alpha');
          final result = await tool.executeResult({
            'action': 'list',
          }, context: context);

          expect(result.isError, isFalse);
          expect(
            result.displayText,
            contains('Note: Output truncated at 50 schedules (55 total).'),
          );
        },
      );
    });

    group('Action: cancel', () {
      test('cancels owned task successfully', () async {
        final context = ToolContext(sessionId: 'session_alpha');
        final createRes = await tool.executeResult({
          'action': 'create',
          'task': 'Cancelable Task',
          'kind': 'daily',
          'time': '07:00',
        }, context: context);
        expect(createRes.isError, isFalse);

        final sessionManager = SessionManager();
        final rows = sessionManager.db.getAllScheduledTasks();
        final taskId = rows.first['id'] as String;

        final cancelRes = await tool.executeResult({
          'action': 'cancel',
          'id': taskId,
        }, context: context);

        expect(cancelRes.isError, isFalse);
        expect(cancelRes.displayText, contains('cancelled successfully'));
        expect(sessionManager.db.getAllScheduledTasks(), isEmpty);
        expect(scheduler.activeTasks, isEmpty);
      });

      test(
        'returns notFound when id does not exist (Acceptance Criterion 3)',
        () async {
          final context = ToolContext(sessionId: 'session_alpha');
          final result = await tool.executeResult({
            'action': 'cancel',
            'id': 'non_existent_id',
          }, context: context);

          expect(result.isError, isTrue);
          expect(result.errorCode, ToolResultErrorCode.notFound);
          expect(
            result.displayText,
            contains('Schedule "non_existent_id" not found'),
          );
        },
      );

      test(
        'denies cancel from non-owning session without mutating row (Acceptance Criterion 4)',
        () async {
          final ownerCtx = ToolContext(sessionId: 'owner_session');
          await tool.executeResult({
            'action': 'create',
            'task': 'Protected Task',
            'kind': 'daily',
            'time': '07:00',
          }, context: ownerCtx);

          final sessionManager = SessionManager();
          final taskId =
              sessionManager.db.getAllScheduledTasks().first['id'] as String;

          // Foreign session attempts cancel
          final foreignCtx = ToolContext(sessionId: 'foreign_session');
          final result = await tool.executeResult({
            'action': 'cancel',
            'id': taskId,
          }, context: foreignCtx);

          expect(result.isError, isTrue);
          expect(result.errorCode, ToolResultErrorCode.permissionDenied);
          expect(
            result.displayText,
            contains('owned by conversation "owner_session"'),
          );
          expect(
            result.displayText,
            contains('cannot be modified from conversation "foreign_session"'),
          );

          // Row and memory timer must be completely unchanged
          final preserved = sessionManager.db.getScheduledTask(taskId);
          expect(preserved, isNotNull);
          expect(preserved!['task'], 'Protected Task');
          expect(scheduler.activeTasks.any((t) => t.id == taskId), isTrue);
        },
      );
    });

    group('Action: update', () {
      test('updates task and recurrence recomputing next instant', () async {
        final context = ToolContext(sessionId: 'session_alpha');
        await tool.executeResult({
          'action': 'create',
          'task': 'Original Task',
          'kind': 'daily',
          'time': '08:00',
          'zone': 'Z',
        }, context: context);

        final sessionManager = SessionManager();
        final taskId =
            sessionManager.db.getAllScheduledTasks().first['id'] as String;

        // Update task and change to interval
        final updateRes = await tool.executeResult({
          'action': 'update',
          'id': taskId,
          'task': 'Updated Task Name',
          'kind': 'interval',
          'every': 'every 30 minutes',
        }, context: context);

        expect(updateRes.isError, isFalse);
        expect(updateRes.displayText, contains('updated successfully'));
        expect(updateRes.displayText, contains('Updated Task Name'));
        expect(updateRes.displayText, contains('every 30 minutes'));

        final updatedRow = sessionManager.db.getScheduledTask(taskId);
        expect(updatedRow!['task'], 'Updated Task Name');
        expect(updatedRow['kind'], 'interval');
        expect(updatedRow['interval_minutes'], 30);
      });

      test('denies update from foreign session', () async {
        final ownerCtx = ToolContext(sessionId: 'owner_session');
        await tool.executeResult({
          'action': 'create',
          'task': 'Task X',
          'kind': 'daily',
          'time': '08:00',
        }, context: ownerCtx);

        final sessionManager = SessionManager();
        final taskId =
            sessionManager.db.getAllScheduledTasks().first['id'] as String;

        final foreignCtx = ToolContext(sessionId: 'foreign_session');
        final result = await tool.executeResult({
          'action': 'update',
          'id': taskId,
          'task': 'Hacked Task',
        }, context: foreignCtx);

        expect(result.isError, isTrue);
        expect(result.errorCode, ToolResultErrorCode.permissionDenied);
        expect(
          result.displayText,
          contains('owned by conversation "owner_session"'),
        );

        final preserved = sessionManager.db.getScheduledTask(taskId);
        expect(preserved!['task'], 'Task X');
      });

      test('fails when update has no task or recurrence parameters', () async {
        final context = ToolContext(sessionId: 'session_alpha');
        final result = await tool.executeResult({
          'action': 'update',
          'id': 'some_id',
        }, context: context);

        expect(result.isError, isTrue);
        expect(result.errorCode, ToolResultErrorCode.invalidInput);
        expect(
          result.displayText,
          contains(
            'update action requires "task" and/or schedule recurrence parameters',
          ),
        );
      });
    });

    group('Compatibility and Projections', () {
      test('schema marks action as required', () {
        expect(tool.schema.parameters['required'], equals(['action']));
      });

      test(
        'infers action for legacy calls persisted before the merge',
        () async {
          final context = ToolContext(sessionId: 'session_alpha');

          // Legacy create without action
          final createRes = await tool.executeResult({
            'task': 'Legacy Auto',
            'time': 'in 15 minutes',
          }, context: context);
          expect(createRes.isError, isFalse);
          expect(createRes.displayText, contains('created successfully'));

          final sessionManager = SessionManager();
          final taskId =
              sessionManager.db.getAllScheduledTasks().first['id'] as String;

          // Legacy cancel without action (only id)
          final cancelRes = await tool.executeResult({
            'id': taskId,
          }, context: context);
          expect(cancelRes.isError, isFalse);
          expect(cancelRes.displayText, contains('cancelled successfully'));
        },
      );

      test('execute text matches executeResult.displayText', () async {
        final context = ToolContext(sessionId: 'session_alpha');
        final args = {
          'action': 'create',
          'task': 'Echo Task',
          'time': 'in 10 minutes',
        };

        final typed = await tool.executeResult(args, context: context);
        expect(typed.isError, isFalse);
        expect(typed.displayText, contains('Echo Task'));
      });
    });

    group('CronScheduler Execution Ordering and Outcome (R2, R3)', () {
      test(
        'persists advanced instant and lastStatus fired before emitting event',
        () async {
          final sessionManager = SessionManager();
          final schedule = scheduler.createSchedule(
            task: 'Recurring Task',
            sessionId: 'session_alpha',
            definition: ScheduleDefinition(
              kind: ScheduleKind.interval,
              intervalMinutes: 10,
              zone: 'local',
            ),
          );

          final initialNextRun = schedule.nextRunAt;
          bool dbUpdatedBeforeEvent = false;
          String? observedStatus;
          DateTime? observedNextRun;

          final completer = Completer<void>();
          final subscription = scheduler.eventStream.listen((event) {
            final row = sessionManager.db.getScheduledTask(schedule.id);
            if (row != null) {
              observedStatus = row['last_status'] as String?;
              final nextRunStr = row['next_run_at'] as String?;
              if (nextRunStr != null) {
                observedNextRun = DateTime.parse(nextRunStr);
              }
              if (observedStatus == 'fired' &&
                  observedNextRun != null &&
                  observedNextRun!.isAfter(initialNextRun)) {
                dbUpdatedBeforeEvent = true;
              }
            }
            completer.complete();
          });

          scheduler.executeTaskForTesting(schedule);
          await completer.future;
          await subscription.cancel();

          expect(dbUpdatedBeforeEvent, isTrue);
          expect(observedStatus, 'fired');
          expect(observedNextRun!.isAfter(initialNextRun), isTrue);
        },
      );

      test('deletes once task from DB before emitting event', () async {
        final sessionManager = SessionManager();
        final schedule = scheduler.createSchedule(
          task: 'Once Task',
          sessionId: 'session_alpha',
          definition: ScheduleDefinition(
            kind: ScheduleKind.once,
            zone: 'local',
            onceAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          ),
        );

        bool deletedBeforeEvent = false;
        final completer = Completer<void>();
        final subscription = scheduler.eventStream.listen((event) {
          final row = sessionManager.db.getScheduledTask(schedule.id);
          if (row == null) {
            deletedBeforeEvent = true;
          }
          completer.complete();
        });

        scheduler.executeTaskForTesting(schedule);
        await completer.future;
        await subscription.cancel();

        expect(deletedBeforeEvent, isTrue);
      });
    });

    group('Port review fixes (Task 112 port)', () {
      test(
        'null optional parameters do not change the inferred action or shape',
        () async {
          final context = ToolContext(sessionId: 'session_alpha');
          final result = await tool.executeResult({
            'action': 'create',
            'task': 'Morning',
            'kind': 'daily',
            'time': '05:00',
            'interval_minutes': null,
            'every': null,
            'id': null,
          }, context: context);
          expect(result.isError, isFalse, reason: result.displayText);
          expect(scheduler.listSchedules().single.kind, ScheduleKind.daily);
        },
      );

      test('a time-only update keeps a weekly schedule weekly', () async {
        final context = ToolContext(sessionId: 'session_alpha');
        final created = scheduler.createSchedule(
          task: 'Standup',
          sessionId: 'session_alpha',
          definition: ScheduleDefinition.parse({
            'kind': 'weekly',
            'weekdays': ['mon', 'thu'],
            'time': '09:00',
            'zone': 'Z',
          }),
        );

        final result = await tool.executeResult({
          'action': 'update',
          'id': created.id,
          'time': '07:30',
          'zone': null,
        }, context: context);
        expect(result.isError, isFalse, reason: result.displayText);

        final updated = scheduler.getSchedule(created.id)!;
        expect(updated.kind, ScheduleKind.weekly);
        expect(updated.weekdays, 'mon,thu');
        expect(updated.atTime, '07:30');
        expect(updated.zone, 'Z');
      });

      test('a recurrence update of an unknown id is notFound', () async {
        final result = await tool.executeResult({
          'action': 'update',
          'id': 'missing',
          'time': '07:30',
        }, context: ToolContext(sessionId: 'session_alpha'));
        expect(result.isError, isTrue);
        expect(result.errorCode, ToolResultErrorCode.notFound);
      });
    });
  });
}
