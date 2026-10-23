import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/schedule_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import 'support/schedule_protocol_harness.dart';

/// A scheduler that fails with an unclassified error, so the handler's
/// `internal_error` path is reachable without corrupting a real row.
class _ThrowingScheduler extends CronScheduler {
  _ThrowingScheduler({super.sessionManager});

  @override
  ScheduledTaskRecord pauseSchedule(String id, ScheduleCaller caller) {
    throw StateError('scheduler exploded with a private detail');
  }
}

void main() {
  late ScheduleProtocolHarness harness;

  setUp(() async {
    harness = await ScheduleProtocolHarness.start();
  });

  tearDown(() async {
    await harness.dispose();
  });

  Map<String, dynamic> createPayload({
    String task = 'Summarise the open items.',
    String kind = 'daily',
    String time = '09:00',
    String zone = '+03:00',
    Map<String, dynamic> extra = const {},
  }) => {
    'task': task,
    'kind': kind,
    'time': time,
    'zone': zone,
    ...extra,
  };

  group('schedule.create (Success Path and Owner Kind)', () {
    test('creates a user-owned schedule with no conversation', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(
            extra: {
              'name': 'Morning brief',
              'conversation_mode': 'continuous',
              'workspace_id': 'ws_1',
              'provider_instance_id': 'inst_1',
              'model': 'gpt-5',
            },
          ),
        ),
      );

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.scheduleCreated);
      expect(envelope['request_id'], 'req-1');

      final schedule = harness.payloadOf(envelope)['schedule'] as Map;
      expect(schedule['owner_kind'], 'user');
      expect(schedule['owner_session_id'], isNull);
      expect(schedule['owner_session_title'], isNull);
      expect(schedule['conversation_mode'], 'continuous');
      expect(schedule['workspace_id'], 'ws_1');
      expect(schedule['provider_instance_id'], 'inst_1');
      expect(schedule['model'], 'gpt-5');
      expect(schedule['name'], 'Morning brief');
      expect(schedule['task'], 'Summarise the open items.');
      expect(schedule['enabled'], isTrue);
      expect(schedule['kind'], 'daily');
      expect(schedule['at_time'], '09:00');
      expect(schedule['interval_minutes'], isNull);
      expect(schedule['weekdays'], isNull);
      expect(schedule['month_day'], isNull);
      expect(schedule['consecutive_failures'], 0);
      expect(schedule['zone'], '+03:00');
      expect(schedule['next_run_at'], endsWith('+03:00'));
      expect(
        DateTime.parse(schedule['next_run_at'] as String).isAfter(
          DateTime.now().toUtc(),
        ),
        isTrue,
      );

      expect(harness.storedScheduleCount, 1);
      expect(harness.broadcasts, hasLength(1));
      expect(harness.broadcasts.single.type, CanonicalEventTypes.scheduleChanged);
      expect(harness.broadcasts.single.payload, {
        'schedule_id': schedule['id'],
        'change': 'created',
      });
    });

    test('defaults to continuous mode and no route when omitted', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, {
          'task': 'Interval task',
          'kind': 'interval',
          'interval_minutes': 30,
        }),
      );

      final schedule = harness.payloadOf(envelope)['schedule'] as Map;
      expect(schedule['conversation_mode'], 'continuous');
      expect(schedule['workspace_id'], isNull);
      expect(schedule['provider_instance_id'], isNull);
      expect(schedule['model'], isNull);
      expect(schedule['name'], isNull);
      expect(schedule['interval_minutes'], 30);
      expect(schedule['zone'], 'local');
    });

    test('a forged owner_kind is an unknown field and creates nothing', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(extra: {'owner_kind': 'model'}),
        ),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(
        harness.payloadOf(envelope)['message'],
        contains('owner_kind'),
      );
      expect(harness.storedScheduleCount, 0);
      expect(harness.broadcasts, isEmpty);
    });

    test('a client-chosen id is an unknown field, not a silent override',
        () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(extra: {'id': 'task_forged'}),
        ),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.storedScheduleCount, 0);
    });

    test('an unknown field rejects the whole request', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(extra: {'owner_session_id': 'session_x'}),
        ),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.storedScheduleCount, 0);
    });

    test('a wrong recurrence type is invalid_request, not a definition error',
        () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, {
          'task': 'Bad interval',
          'kind': 'interval',
          'interval_minutes': '30',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.storedScheduleCount, 0);
    });

    test('a rejected definition is invalid_schedule', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, {
          'task': 'Weekly without weekdays',
          'kind': 'weekly',
          'time': '09:00',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_schedule');
      expect(harness.storedScheduleCount, 0);
    });

    test('an invalid conversation_mode is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(extra: {'conversation_mode': 'sometimes'}),
        ),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.storedScheduleCount, 0);
    });

    test('a missing task is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, {
          'kind': 'daily',
          'time': '09:00',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.storedScheduleCount, 0);
    });

    test('an unverified transport is permission_denied and mutates nothing',
        () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(),
          authority: CommandAuthority.unverified,
        ),
      );

      expect(harness.codeOf(envelope), 'permission_denied');
      expect(harness.storedScheduleCount, 0);
      expect(harness.broadcasts, isEmpty);
    });
  });

  group('schedule.update', () {
    late String scheduleId;

    setUp(() async {
      final created = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleCreate,
          createPayload(extra: {'name': 'Original'}),
        ),
      );
      scheduleId =
          (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
      harness.broadcasts.clear();
    });

    test('changes the task and answers the updated row', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {
          'id': scheduleId,
          'task': 'New self-contained task.',
        }),
      );

      expect(envelope['event'], CanonicalEventTypes.scheduleUpdated);
      final schedule = harness.payloadOf(envelope)['schedule'] as Map;
      expect(schedule['task'], 'New self-contained task.');
      expect(schedule['name'], 'Original');
      expect(harness.broadcasts.single.payload['change'], 'updated');
    });

    test('merges a partial recurrence instead of re-inferring the shape',
        () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {
          'id': scheduleId,
          'time': '21:15',
        }),
      );

      final schedule = harness.payloadOf(envelope)['schedule'] as Map;
      expect(schedule['kind'], 'daily');
      expect(schedule['at_time'], '21:15');
    });

    test('clears name with an explicit null', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {
          'id': scheduleId,
          'name': null,
        }),
      );

      expect((harness.payloadOf(envelope)['schedule'] as Map)['name'], isNull);
    });

    test('an unknown id is schedule_not_found', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {
          'id': 'task_missing',
          'task': 'Nope',
        }),
      );

      expect(harness.codeOf(envelope), 'schedule_not_found');
    });

    test('an update with nothing to change is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {'id': scheduleId}),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.broadcasts, isEmpty);
    });

    test('a missing id is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {'task': 'x'}),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
    });

    test('an unknown field is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleUpdate, {
          'id': scheduleId,
          'owner_kind': 'user',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.broadcasts, isEmpty);
    });
  });

  group('schedule.pause and schedule.resume', () {
    late String scheduleId;

    setUp(() async {
      final created = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, createPayload()),
      );
      scheduleId =
          (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
      harness.broadcasts.clear();
    });

    test('pause disables the row and keeps its next instant', () async {
      final before = harness.scheduler.getSchedule(scheduleId)!;

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.schedulePause, {'id': scheduleId}),
      );

      expect(envelope['event'], CanonicalEventTypes.scheduleUpdated);
      final schedule = harness.payloadOf(envelope)['schedule'] as Map;
      expect(schedule['enabled'], isFalse);
      expect(schedule['next_run_at'], ScheduleZone.parse(
        before.zone,
      ).formatInstant(before.nextRunAt));
      expect(harness.scheduler.getSchedule(scheduleId)!.enabled, isFalse);
      expect(harness.broadcasts.single.payload['change'], 'paused');
    });

    test('resume enables the row and recomputes a future instant', () async {
      await harness.send(
        harness.event(CanonicalEventTypes.schedulePause, {'id': scheduleId}),
      );
      harness.broadcasts.clear();

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleResume, {'id': scheduleId}),
      );

      final schedule = harness.payloadOf(envelope)['schedule'] as Map;
      expect(schedule['enabled'], isTrue);
      final record = harness.scheduler.getSchedule(scheduleId)!;
      expect(record.enabled, isTrue);
      expect(record.nextRunAt.isAfter(DateTime.now().toUtc()), isTrue);
      expect(harness.broadcasts.single.payload['change'], 'resumed');
    });

    test('resuming an expired once schedule is schedule_expired', () async {
      final now = DateTime.now().toUtc();
      harness.sessionManager.db.saveScheduledTask(
        'task_expired',
        'Expired one-shot',
        now.subtract(const Duration(minutes: 5)),
        '',
        kind: ScheduleKind.once.name,
        zone: 'Z',
        updatedAt: now,
        ownerKind: ScheduleOwnerKind.user.wireName,
        enabled: false,
      );

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleResume, {'id': 'task_expired'}),
      );

      expect(harness.codeOf(envelope), 'schedule_expired');
      expect(harness.scheduler.getSchedule('task_expired')!.enabled, isFalse);
    });

    test('an unknown id is schedule_not_found', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.schedulePause, {'id': 'task_missing'}),
      );

      expect(harness.codeOf(envelope), 'schedule_not_found');
    });
  });

  group('schedule.run_now', () {
    late String scheduleId;

    setUp(() async {
      final created = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, createPayload()),
      );
      scheduleId =
          (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
      harness.broadcasts.clear();
    });

    test('accepts a manual run and records trigger=manual', () async {
      final before = harness.scheduler.getSchedule(scheduleId)!;

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRunNow, {'id': scheduleId}),
      );

      expect(envelope['event'], CanonicalEventTypes.scheduleRunAccepted);
      final payload = harness.payloadOf(envelope);
      final runId = payload['run_id'] as String;
      expect(payload['session_id'], isNotEmpty);
      expect(payload['accepted_at'], isNotEmpty);

      final run = harness.sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.status, ScheduledTaskRunStatus.running);
      expect(run.trigger, ScheduledTaskRunTrigger.manual);
      expect(run.scheduleId, scheduleId);

      final after = harness.scheduler.getSchedule(scheduleId)!;
      expect(after.nextRunAt, before.nextRunAt);
      expect(after.lastRunAt, before.lastRunAt);
      expect(after.lastStatus, before.lastStatus);
      expect(after.enabled, isTrue);
      expect(harness.broadcasts.single.payload['change'], 'run_now');
    });

    test('dispatches from a paused schedule and leaves it paused', () async {
      await harness.send(
        harness.event(CanonicalEventTypes.schedulePause, {'id': scheduleId}),
      );
      final paused = harness.scheduler.getSchedule(scheduleId)!;

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRunNow, {'id': scheduleId}),
      );

      expect(harness.codeOf(envelope), isNull);
      final after = harness.scheduler.getSchedule(scheduleId)!;
      expect(after.enabled, isFalse);
      expect(after.nextRunAt, paused.nextRunAt);
    });

    test('an orphaned model-owned row is schedule_orphaned', () async {
      harness.seedModelSchedule(id: 'task_orphan', sessionId: 'session_gone');

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRunNow, {'id': 'task_orphan'}),
      );

      expect(harness.codeOf(envelope), 'schedule_orphaned');
      expect(
        harness.sessionManager.db.scheduledTaskRuns.countRuns('task_orphan'),
        0,
      );
    });

    test('an unverified transport is permission_denied', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleRunNow,
          {'id': scheduleId},
          authority: CommandAuthority.unverified,
        ),
      );

      expect(harness.codeOf(envelope), 'permission_denied');
      expect(
        harness.sessionManager.db.scheduledTaskRuns.countRuns(scheduleId),
        0,
      );
    });
  });

  group('schedule.delete', () {
    late String scheduleId;
    late String runSessionId;

    setUp(() async {
      final created = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, createPayload()),
      );
      scheduleId =
          (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
      await harness.send(
        harness.event(CanonicalEventTypes.scheduleRunNow, {'id': scheduleId}),
      );
      runSessionId = harness.scheduler.getSchedule(scheduleId)!.runSessionId!;
      harness.sessionManager.updateSessionTitle(runSessionId, 'Run history');
      harness.broadcasts.clear();
    });

    test('requires confirm and mutates nothing without it', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleDelete, {'id': scheduleId}),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.scheduler.getSchedule(scheduleId), isNotNull);
      expect(harness.broadcasts, isEmpty);
    });

    test('rejects a non-boolean confirm', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleDelete, {
          'id': scheduleId,
          'confirm': 'true',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.scheduler.getSchedule(scheduleId), isNotNull);
    });

    test('deletes the schedule and its runs, keeping the conversation', () async {
      expect(
        harness.sessionManager.db.scheduledTaskRuns.countRuns(scheduleId),
        1,
      );

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleDelete, {
          'id': scheduleId,
          'confirm': true,
        }),
      );

      expect(envelope['event'], CanonicalEventTypes.scheduleDeleted);
      expect(harness.payloadOf(envelope), {
        'request_id': 'req-1',
        'id': scheduleId,
        'deleted': true,
      });
      expect(harness.scheduler.getSchedule(scheduleId), isNull);
      expect(
        harness.sessionManager.db.scheduledTaskRuns.countRuns(scheduleId),
        0,
      );
      final conversation = harness.sessionManager.getSessionRecord(
        runSessionId,
      );
      expect(conversation, isNotNull);
      expect(conversation!.title, 'Run history');
      expect(harness.broadcasts.single.payload, {
        'schedule_id': scheduleId,
        'change': 'deleted',
      });
    });

    test('an unknown id is schedule_not_found', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleDelete, {
          'id': 'task_missing',
          'confirm': true,
        }),
      );

      expect(harness.codeOf(envelope), 'schedule_not_found');
    });
  });

  group('Error Envelope Shape', () {
    test('an error envelope keeps the documented shape', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.schedulePause, {'id': 'task_any'}),
      );

      expect(envelope['type'], 'event');
      expect(envelope['event'], 'error');
      expect(envelope['request_id'], 'req-1');
      final payload = harness.payloadOf(envelope);
      expect(payload.keys.toSet(), {'request_id', 'code', 'message'});
      expect(payload['code'], 'schedule_not_found');
      expect(payload['message'], isNotEmpty);
    });

    test('a non-string request_id is invalid_request without correlation',
        () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.schedulePause,
          {'id': 'task_any'},
          requestId: null,
        )..payload['request_id'] = 42,
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(harness.payloadOf(envelope)['request_id'], isNull);
    });

    test('an unclassified scheduler failure is a stable internal_error',
        () async {
      final throwing = ScheduleCommandHandler(
        scheduler: _ThrowingScheduler(sessionManager: harness.sessionManager),
        sessionManager: harness.sessionManager,
        bridge: harness.bridge,
      );

      final envelope = await throwing.buildPauseEnvelope(
        harness.event(CanonicalEventTypes.schedulePause, {'id': 'task_any'}),
      );

      expect(harness.codeOf(envelope), 'internal_error');
      expect(
        harness.payloadOf(envelope)['message'],
        ScheduleCommandHandler.internalErrorMessage,
      );
      expect(
        harness.payloadOf(envelope)['message'],
        isNot(contains('exploded')),
      );
    });
  });

  group('Dispatch', () {
    test('an event type outside the family emits nothing', () async {
      var emitted = false;
      await harness.commands.handle(
        harness.event(CanonicalEventTypes.scheduleList, {}),
        (envelope) async => emitted = true,
      );

      expect(emitted, isFalse);
    });
  });

  group('Logging', () {
    test('never logs a task text or a payload map', () async {
      const canary = 'canary-task-text-4f1c2a9b';
      final logged = <String>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(
        (record) => logged.add(record.message),
      );
      try {
        final created = await harness.send(
          harness.event(CanonicalEventTypes.scheduleCreate, {
            'task': canary,
            'kind': 'daily',
            'time': '09:00',
          }),
        );
        final scheduleId =
            (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
        await harness.send(
          harness.event(CanonicalEventTypes.scheduleUpdate, {
            'id': scheduleId,
            'task': '$canary-updated',
          }),
        );
        await harness.send(
          harness.event(CanonicalEventTypes.schedulePause, {'id': scheduleId}),
        );
        await harness.send(
          harness.event(CanonicalEventTypes.scheduleDelete, {
            'id': scheduleId,
            'confirm': true,
          }),
        );
        await Future<void>.delayed(Duration.zero);
      } finally {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      }

      expect(logged, isNotEmpty);
      expect(logged.where((line) => line.contains(canary)), isEmpty);
      expect(
        logged.where((line) => line.contains(CommandAuthority.payloadKey)),
        isEmpty,
      );
      // The useful diagnostics are present: ids and codes.
      expect(logged.where((line) => line.contains('schedule_id=')), isNotEmpty);
    });
  });
}
