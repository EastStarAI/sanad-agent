import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/models/session_history_page.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/schedule_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/support/schedule_projection.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import 'support/schedule_protocol_harness.dart';

void main() {
  late ScheduleProtocolHarness harness;

  setUp(() async {
    harness = await ScheduleProtocolHarness.start();
  });

  tearDown(() async {
    await harness.dispose();
  });

  Future<Map<String, dynamic>> createSchedule({
    Map<String, dynamic> payload = const {
      'task': 'Summarise the open items.',
      'kind': 'daily',
      'time': '09:00',
      'zone': '+03:00',
    },
  }) async {
    final envelope = await harness.send(
      harness.event(CanonicalEventTypes.scheduleCreate, payload),
    );
    return harness.payloadOf(envelope)['schedule'] as Map<String, dynamic>;
  }

  group('schedule.list', () {
    test('answers an empty device', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {}),
      );

      expect(envelope['event'], CanonicalEventTypes.scheduleListResult);
      final payload = harness.payloadOf(envelope);
      expect(payload['schedules'], isEmpty);
      expect(payload['truncated'], isFalse);
      expect(payload['request_id'], 'req-1');
    });

    test('projects exactly the documented fields', () async {
      await createSchedule(
        payload: {
          'name': 'Morning brief',
          'task': 'Summarise the open items.',
          'kind': 'daily',
          'time': '09:00',
          'zone': '+03:00',
          'conversation_mode': 'continuous',
          'workspace_id': 'ws_1',
          'provider_instance_id': 'inst_1',
          'model': 'gpt-5',
        },
      );

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {}),
      );
      final schedules = harness.payloadOf(envelope)['schedules'] as List;
      final schedule = schedules.single as Map<String, dynamic>;

      expect(schedule.keys.toSet(), {
        'id',
        'name',
        'task',
        'kind',
        'interval_minutes',
        'at_time',
        'weekdays',
        'month_day',
        'zone',
        'next_run_at',
        'enabled',
        'owner_kind',
        'owner_session_id',
        'owner_session_title',
        'conversation_mode',
        'workspace_id',
        'provider_instance_id',
        'model',
        'last_run_at',
        'last_status',
        'consecutive_failures',
        'created_at',
        'updated_at',
      });
      // The Agent's English recurrence sentence never reaches the wire.
      expect(
        schedule.values
            .whereType<String>()
            .any((value) => value.contains('daily at')),
        isFalse,
      );
    });

    test('orders by next instant then id', () async {
      final now = DateTime.now().toUtc();
      for (final (id, offsetMinutes) in [
        ('task_c', 30),
        ('task_b', 10),
        ('task_a', 20),
      ]) {
        harness.sessionManager.db.saveScheduledTask(
          id,
          'Task $id',
          now.add(Duration(minutes: offsetMinutes)),
          '',
          kind: ScheduleKind.daily.name,
          atTime: '09:00',
          zone: 'Z',
          updatedAt: now,
          ownerKind: ScheduleOwnerKind.user.wireName,
        );
      }

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {}),
      );
      final ids = [
        for (final row in harness.payloadOf(envelope)['schedules'] as List)
          (row as Map)['id'],
      ];
      expect(ids, ['task_b', 'task_a', 'task_c']);
    });

    test('truncates above the bounded list size', () async {
      final now = DateTime.now().toUtc();
      for (var index = 0; index <= ScheduleWireLimits.maxListedSchedules; index++) {
        harness.sessionManager.db.saveScheduledTask(
          'task_$index',
          'Task $index',
          now.add(Duration(minutes: index)),
          '',
          kind: ScheduleKind.daily.name,
          atTime: '09:00',
          zone: 'Z',
          updatedAt: now,
          ownerKind: ScheduleOwnerKind.user.wireName,
        );
      }

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {}),
      );
      final payload = harness.payloadOf(envelope);
      expect(payload['truncated'], isTrue);
      expect(
        (payload['schedules'] as List),
        hasLength(ScheduleWireLimits.maxListedSchedules),
      );
    });

    test('carries the owning conversation title only, never a label', () async {
      final session = harness.sessionManager.createSession('test-model');
      harness.sessionManager.updateSessionTitle(
        session.sessionId,
        'Morning brief runs',
      );
      harness.seedModelSchedule(
        id: 'task_model',
        sessionId: session.sessionId,
        name: 'Morning brief',
      );
      await createSchedule();

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {}),
      );
      final schedules = [
        for (final row in harness.payloadOf(envelope)['schedules'] as List)
          row as Map<String, dynamic>,
      ];
      final modelRow = schedules.firstWhere((row) => row['id'] == 'task_model');
      expect(modelRow['owner_kind'], 'model');
      expect(modelRow['owner_session_id'], session.sessionId);
      expect(modelRow['owner_session_title'], 'Morning brief runs');

      final userRow = schedules.firstWhere((row) => row['id'] != 'task_model');
      expect(userRow['owner_kind'], 'user');
      expect(userRow['owner_session_id'], isNull);
      expect(userRow['owner_session_title'], isNull);
    });

    test('counts consecutive failures of the newest terminal runs', () async {
      final schedule = await createSchedule();
      final scheduleId = schedule['id'] as String;
      harness.seedRun(
        scheduleId: scheduleId,
        status: ScheduledTaskRunStatus.failed,
        error: 'first failure',
      );
      harness.seedRun(
        scheduleId: scheduleId,
        status: ScheduledTaskRunStatus.failed,
        error: 'second failure',
      );

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {}),
      );
      final row =
          (harness.payloadOf(envelope)['schedules'] as List).single as Map;
      expect(row['consecutive_failures'], 2);
    });

    test('an unverified transport is permission_denied', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleList,
          {},
          authority: CommandAuthority.unverified,
        ),
      );

      expect(harness.codeOf(envelope), 'permission_denied');
    });

    test('an unknown field is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleList, {'limit': 10}),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
    });
  });

  group('schedule.preview', () {
    test('answers the next instant of a valid definition', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.schedulePreview, {
          'kind': 'daily',
          'time': '09:00',
          'zone': '+03:00',
        }),
      );

      expect(envelope['event'], CanonicalEventTypes.schedulePreviewResult);
      final payload = harness.payloadOf(envelope);
      expect(payload['valid'], isTrue);
      expect(payload['zone'], '+03:00');
      expect(payload['next_run_at'], endsWith('+03:00'));
      expect(
        DateTime.parse(payload['next_run_at'] as String).isAfter(
          DateTime.now().toUtc(),
        ),
        isTrue,
      );
      expect(payload.containsKey('error_code'), isFalse);
    });

    test('answers valid:false with the error code, not a transport error',
        () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.schedulePreview, {
          'kind': 'weekly',
          'time': '09:00',
        }),
      );

      expect(envelope['event'], CanonicalEventTypes.schedulePreviewResult);
      final payload = harness.payloadOf(envelope);
      expect(payload['valid'], isFalse);
      expect(payload['error_code'], 'invalid_schedule');
      expect(payload.containsKey('next_run_at'), isFalse);
    });

    test('mutates nothing', () async {
      await harness.send(
        harness.event(CanonicalEventTypes.schedulePreview, {
          'kind': 'daily',
          'time': '09:00',
        }),
      );

      expect(harness.storedScheduleCount, 0);
    });

    test('an unknown field is invalid_request', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.schedulePreview, {
          'kind': 'daily',
          'time': '09:00',
          'task': 'x',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
    });

    test('an unverified transport is permission_denied', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.schedulePreview,
          {'kind': 'daily', 'time': '09:00'},
          authority: CommandAuthority.unverified,
        ),
      );

      expect(harness.codeOf(envelope), 'permission_denied');
    });
  });

  group('schedule.runs', () {
    late String scheduleId;

    setUp(() async {
      final schedule = await createSchedule();
      scheduleId = schedule['id'] as String;
    });

    Future<Map<String, dynamic>> listRuns({
      String? id,
      int? limit,
      String? cursor,
    }) async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': id ?? scheduleId,
          'limit': ?limit,
          'cursor': ?cursor,
        }),
      );
      return harness.payloadOf(envelope);
    }

    test('pages newest-first with a bounded limit', () async {
      final base = DateTime.utc(2026, 10, 20, 9);
      for (var index = 0; index < 5; index++) {
        harness.seedRun(
          scheduleId: scheduleId,
          status: ScheduledTaskRunStatus.succeeded,
          runAt: base.add(Duration(minutes: index)),
        );
      }

      final first = await listRuns(limit: 2);
      final firstRuns = first['runs'] as List;
      expect(firstRuns, hasLength(2));
      expect(first['has_more'], isTrue);
      expect(first['next_cursor'], isNotEmpty);
      expect(
        DateTime.parse((firstRuns.first as Map)['run_at'] as String),
        base.add(const Duration(minutes: 4)),
      );

      final second = await listRuns(
        limit: 2,
        cursor: first['next_cursor'] as String,
      );
      final secondRuns = second['runs'] as List;
      expect(secondRuns, hasLength(2));
      expect(
        DateTime.parse((secondRuns.first as Map)['run_at'] as String),
        base.add(const Duration(minutes: 2)),
      );

      final third = await listRuns(
        limit: 2,
        cursor: second['next_cursor'] as String,
      );
      expect((third['runs'] as List), hasLength(1));
      expect(third['has_more'], isFalse);
      expect(third.containsKey('next_cursor'), isFalse);
    });

    test('rejects a cursor minted for another schedule', () async {
      final other = await createSchedule();
      final otherId = other['id'] as String;
      for (var index = 0; index < 3; index++) {
        harness.seedRun(
          scheduleId: otherId,
          status: ScheduledTaskRunStatus.succeeded,
          runAt: DateTime.utc(2026, 10, 20, 9 + index),
        );
      }
      final otherPage = await listRuns(id: otherId, limit: 1);
      final cursor = otherPage['next_cursor'] as String;

      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': scheduleId,
          'cursor': cursor,
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
      expect(
        harness.payloadOf(envelope)['message'],
        contains('another schedule'),
      );
    });

    test('rejects a malformed cursor', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': scheduleId,
          'cursor': 'not-a-cursor',
        }),
      );

      expect(harness.codeOf(envelope), 'invalid_request');
    });

    test('rejects an out-of-range limit', () async {
      final zero = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': scheduleId,
          'limit': 0,
        }),
      );
      expect(harness.codeOf(zero), 'invalid_request');

      final tooLarge = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': scheduleId,
          'limit': ScheduleWireLimits.maxRunsPageSize + 1,
        }),
      );
      expect(harness.codeOf(tooLarge), 'invalid_request');

      final wrongType = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': scheduleId,
          'limit': '10',
        }),
      );
      expect(harness.codeOf(wrongType), 'invalid_request');
    });

    test('an unknown schedule is schedule_not_found', () async {
      final envelope = await harness.send(
        harness.event(CanonicalEventTypes.scheduleRuns, {
          'schedule_id': 'task_missing',
        }),
      );

      expect(harness.codeOf(envelope), 'schedule_not_found');
    });

    test('projects exactly the documented run fields', () async {
      final session = harness.sessionManager.createSession('test-model');
      harness.seedRun(
        scheduleId: scheduleId,
        status: ScheduledTaskRunStatus.failed,
        trigger: ScheduledTaskRunTrigger.manual,
        sessionId: session.sessionId,
        messageId: 'message_1',
        error: 'Rate limit exceeded',
      );

      final payload = await listRuns();
      final run = (payload['runs'] as List).single as Map<String, dynamic>;

      expect(run.keys.toSet(), {
        'id',
        'run_at',
        'status',
        'trigger',
        'duration_ms',
        'error',
        'session_id',
        'message_id',
        'has_position',
        'anchor_event_id',
      });
      expect(run['status'], 'failed');
      expect(run['trigger'], 'manual');
      expect(run['error'], 'Rate limit exceeded');
      expect(run['session_id'], session.sessionId);
      expect(run['message_id'], 'message_1');
      expect(run['has_position'], isTrue);
      // The stored message identity no longer resolves to an active history
      // row, so there is no anchor to open; the run row is never rewritten to
      // invent one.
      expect(run['anchor_event_id'], isNull);
      expect(run['duration_ms'], isNotNull);
      // No conversation title, message text, or command output is projected.
      expect(run.containsKey('session_title'), isFalse);
      expect(run.containsKey('task'), isFalse);
    });

    test('has_position is false before the user message commits', () async {
      harness.seedRun(
        scheduleId: scheduleId,
        status: ScheduledTaskRunStatus.running,
      );

      final payload = await listRuns();
      final run = (payload['runs'] as List).single as Map;
      expect(run['session_id'], isNull);
      expect(run['message_id'], isNull);
      expect(run['has_position'], isFalse);
      expect(run['anchor_event_id'], isNull);
      expect(run['duration_ms'], isNull);
    });

    test('anchor_event_id is the canonical history anchor of the run user message', () async {
      final session = harness.sessionManager.createSession('test-model');
      harness.sessionManager.db.replaceMessages(session.sessionId, [
        Message(role: MessageRole.user, content: 'Reply with exactly OK.'),
      ]);
      final persisted = harness.sessionManager.db.getPersistedMessages(
        session.sessionId,
      );
      expect(persisted, hasLength(1));
      final messageRowId = persisted.single.rowId;
      final messageId = MessageHistoryIdentity.read(
        persisted.single.message,
      ).messageId;
      expect(messageId, isNotEmpty);

      harness.seedRun(
        scheduleId: scheduleId,
        status: ScheduledTaskRunStatus.succeeded,
        sessionId: session.sessionId,
        messageId: messageId,
      );

      final payload = await listRuns();
      final run = (payload['runs'] as List).single as Map<String, dynamic>;

      expect(run['has_position'], isTrue);
      expect(run['message_id'], messageId);
      // The anchor addresses the durable history row, never the message
      // identity stored on the run row (S20).
      expect(
        run['anchor_event_id'],
        'history:${session.sessionId}:$messageRowId:user_message:0',
      );

      // ...and it is exactly the shape the history anchor admits, so the
      // anchored load resolves back to the same row.
      final request = SessionHistoryRequest(
        anchorEventId: run['anchor_event_id'] as String,
      );
      expect(request.anchorRowIdForSession(session.sessionId), messageRowId);
    });

    test('an unverified transport is permission_denied', () async {
      final envelope = await harness.send(
        harness.event(
          CanonicalEventTypes.scheduleRuns,
          {'schedule_id': scheduleId},
          authority: CommandAuthority.unverified,
        ),
      );

      expect(harness.codeOf(envelope), 'permission_denied');
    });
  });

  group('ScheduleRunsCursor', () {
    test('round-trips the schedule, instant, and run identity', () {
      final cursor = ScheduleRunsCursor(
        scheduleId: 'task_1',
        runAt: DateTime.utc(2026, 10, 20, 9, 30),
        runId: 'run_1',
      );

      final decoded = ScheduleRunsCursor.decode(
        cursor.encode(),
        scheduleId: 'task_1',
      );
      expect(decoded.scheduleId, 'task_1');
      expect(decoded.runAt, DateTime.utc(2026, 10, 20, 9, 30));
      expect(decoded.runId, 'run_1');
    });

    test('rejects an empty cursor', () {
      expect(
        () => ScheduleRunsCursor.decode('  ', scheduleId: 'task_1'),
        throwsA(isA<ScheduleRunsCursorException>()),
      );
    });
  });
}
