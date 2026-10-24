import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';

/// Records the wire shape and returns a scripted response or throwable.
class _RecordingCommands implements DeviceCommandClient {
  final requests = <Map<String, Object?>>[];
  final broadcasts = StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> response = const {};
  Object? error;

  List<String> get commands => [for (final request in requests) request['command']! as String];

  /// The payload of the single recorded request, without the recording keys.
  Map<String, Object?> get payload {
    final only = Map<String, Object?>.from(requests.last);
    return only
      ..remove('command')
      ..remove('expected');
  }

  @override
  Stream<Map<String, dynamic>> events(DeviceConfig device) => broadcasts.stream;

  @override
  Future<Map<String, dynamic>> request({
    required DeviceConfig device,
    required String command,
    required String expectedEvent,
    Set<String>? acceptedEvents,
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 10),
    bool Function(Map<String, dynamic> payload)? payloadMatches,
  }) async {
    requests.add({'command': command, 'expected': expectedEvent, ...payload});
    final thrown = error;
    if (thrown != null) throw thrown;
    return response;
  }
}

void main() {
  final device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true);

  Map<String, dynamic> rowJson({String id = 'task_1', Object? extra}) => {
    'id': id,
    'name': 'Morning brief',
    'task': 'Summarise the open items in this workspace.',
    'kind': 'daily',
    'interval_minutes': null,
    'at_time': '09:00',
    'weekdays': null,
    'month_day': null,
    'zone': '+03:00',
    'next_run_at': '2026-10-24T09:00:00+03:00',
    'enabled': true,
    'owner_kind': 'user',
    'owner_session_id': '8f14e45f-ea0a-4c1a-9c1f-0d1c9b3e1234',
    'owner_session_title': 'Morning brief runs',
    'conversation_mode': 'continuous',
    'workspace_id': 'ws_1',
    'provider_instance_id': 'inst_1',
    'model': 'gpt-5',
    'last_run_at': '2026-10-23T09:00:04Z',
    'last_status': 'fired',
    'consecutive_failures': 0,
    'created_at': '2026-10-23T08:12:00.000Z',
    'updated_at': '2026-10-23T08:12:00.000Z',
    if (extra is Map) ...extra,
  };

  group('SchedulesClient.list', () {
    test('sends schedule.list with no payload fields and projects every row field', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedules': [rowJson()],
          'truncated': false,
        };

      final snapshot = await SchedulesClient(commands).list(device);

      expect(commands.requests.single, {
        'command': 'schedule.list',
        'expected': 'schedule.list_result',
      });
      expect(snapshot.truncated, isFalse);
      final schedule = snapshot.schedules.single;
      expect(schedule.id, 'task_1');
      expect(schedule.name, 'Morning brief');
      expect(schedule.task, 'Summarise the open items in this workspace.');
      expect(schedule.kind, ScheduleKind.daily);
      expect(schedule.atTime, '09:00');
      expect(schedule.intervalMinutes, isNull);
      expect(schedule.weekdays, isEmpty);
      expect(schedule.monthDay, isNull);
      expect(schedule.zone, '+03:00');
      expect(schedule.nextRunAt, DateTime.utc(2026, 10, 24, 6, 0));
      expect(schedule.enabled, isTrue);
      expect(schedule.ownerKind, ScheduleOwnerKind.user);
      expect(schedule.ownerSessionId, '8f14e45f-ea0a-4c1a-9c1f-0d1c9b3e1234');
      expect(schedule.ownerSessionTitle, 'Morning brief runs');
      expect(schedule.conversationMode, ScheduleConversationMode.continuous);
      expect(schedule.workspaceId, 'ws_1');
      expect(schedule.providerInstanceId, 'inst_1');
      expect(schedule.model, 'gpt-5');
      expect(schedule.lastRunAt, DateTime.utc(2026, 10, 23, 9, 0, 4));
      expect(schedule.lastOutcome, ScheduleLastOutcome.fired);
      expect(schedule.consecutiveFailures, 0);
      expect(schedule.createdAt, DateTime.utc(2026, 10, 23, 8, 12));
      expect(schedule.updatedAt, DateTime.utc(2026, 10, 23, 8, 12));
    });

    test('ignores unknown additive fields and tolerates a malformed row', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedules': [
            rowJson(
              extra: {
                'future_field': 'ignored',
                'weekdays': ['mon', 'funday', 'wed'],
                'last_status': 'teleported',
              },
            ),
            {'kind': 'monthly', 'enabled': 'yes'},
          ],
          'truncated': true,
          'future_envelope_field': 42,
        };

      final snapshot = await SchedulesClient(commands).list(device);

      expect(snapshot.truncated, isTrue);
      expect(snapshot.schedules.first.weekdays, [ScheduleWeekday.mon, ScheduleWeekday.wed]);
      expect(snapshot.schedules.first.lastOutcome, ScheduleLastOutcome.unknown);
      final malformed = snapshot.schedules.last;
      expect(malformed.id, '');
      expect(malformed.kind, ScheduleKind.monthly);
      expect(malformed.enabled, isFalse);
      expect(malformed.ownerKind, ScheduleOwnerKind.unknown);
    });
  });

  group('SchedulesClient.preview', () {
    test('sends only the definition fields of the candidate', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'valid': true,
          'next_run_at': '2026-10-24T09:00:00+03:00',
          'zone': '+03:00',
        };

      final preview = await SchedulesClient(commands).preview(
        device,
        const ScheduleDefinitionInput(
          kind: ScheduleKind.weekly,
          zone: '+03:00',
          atTime: '09:00',
          weekdays: [ScheduleWeekday.mon, ScheduleWeekday.fri],
        ),
      );

      expect(commands.requests.single, {
        'command': 'schedule.preview',
        'expected': 'schedule.preview_result',
        'kind': 'weekly',
        'zone': '+03:00',
        'time': '09:00',
        'weekdays': ['mon', 'fri'],
      });
      expect(preview.valid, isTrue);
      expect(preview.nextRunAt, DateTime.utc(2026, 10, 24, 6, 0));
      expect(preview.zone, '+03:00');
      expect(preview.errorCode, isNull);
    });

    test('an invalid definition is a successful answer, not an exception', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'valid': false,
          'error_code': 'invalid_schedule',
        };

      final preview = await SchedulesClient(commands).preview(
        device,
        const ScheduleDefinitionInput(kind: ScheduleKind.daily),
      );

      expect(preview.valid, isFalse);
      expect(preview.errorCode, ScheduleErrorCode.invalidSchedule);
    });
  });

  group('SchedulesClient.create', () {
    test('sends the documented create payload and never owner_kind', () async {
      final commands = _RecordingCommands()..response = {'request_id': 'req-1', 'schedule': rowJson()};

      final created = await SchedulesClient(commands).create(
        device,
        const ScheduleDraft(
          task: 'Summarise the open items in this workspace.',
          name: 'Morning brief',
          definition: ScheduleDefinitionInput(kind: ScheduleKind.daily, zone: '+03:00', atTime: '09:00'),
          conversationMode: ScheduleConversationMode.continuous,
          workspaceId: 'ws_1',
          providerInstanceId: 'inst_1',
          model: 'gpt-5',
        ),
      );

      expect(commands.requests.single, {
        'command': 'schedule.create',
        'expected': 'schedule.created',
        'task': 'Summarise the open items in this workspace.',
        'name': 'Morning brief',
        'kind': 'daily',
        'zone': '+03:00',
        'time': '09:00',
        'conversation_mode': 'continuous',
        'workspace_id': 'ws_1',
        'provider_instance_id': 'inst_1',
        'model': 'gpt-5',
      });
      expect(commands.requests.single.containsKey('owner_kind'), isFalse);
      expect(created.id, 'task_1');
      expect(created.kind, ScheduleKind.daily);
    });

    test('omits a blank name and an unset conversation route', () async {
      final commands = _RecordingCommands()..response = {'request_id': 'req-1', 'schedule': rowJson()};

      await SchedulesClient(commands).create(
        device,
        const ScheduleDraft(
          task: 'Ping me about the deploy.',
          name: '   ',
          definition: ScheduleDefinitionInput(kind: ScheduleKind.interval, intervalMinutes: 30),
        ),
      );

      expect(commands.payload, {
        'task': 'Ping me about the deploy.',
        'kind': 'interval',
        'interval_minutes': 30,
      });
    });

    test('a missing schedule object is a typed protocol violation', () async {
      final commands = _RecordingCommands()..response = const {'request_id': 'req-1'};

      await expectLater(
        SchedulesClient(commands).create(device, const ScheduleDraft(task: 'x', definition: ScheduleDefinitionInput(kind: ScheduleKind.daily))),
        throwsA(
          isA<ScheduleException>()
              .having((error) => error.code, 'code', ScheduleErrorCode.unknown)
              .having((error) => error.wireCode, 'wireCode', 'schedule_absent'),
        ),
      );
    });
  });

  group('SchedulesClient.update', () {
    test('sends merge semantics: absent keeps, null clears, definition replaces', () async {
      final commands = _RecordingCommands()..response = {'request_id': 'req-1', 'schedule': rowJson()};

      await SchedulesClient(commands).update(
        device,
        const ScheduleUpdate(
          id: 'task_1',
          name: ScheduleSetting.set(null),
          model: ScheduleSetting.set('gpt-5-mini'),
          definition: ScheduleDefinitionInput(kind: ScheduleKind.monthly, atTime: '07:30', monthDay: 1),
        ),
      );

      expect(commands.payload, {
        'id': 'task_1',
        'name': null,
        'model': 'gpt-5-mini',
        'kind': 'monthly',
        'time': '07:30',
        'day_of_month': 1,
      });
      expect(commands.requests.single.containsKey('workspace_id'), isFalse);
      expect(commands.requests.single.containsKey('owner_kind'), isFalse);
    });
  });

  group('SchedulesClient.pause, resume, runNow', () {
    test('pause sends only the id and reads the updated row', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedule': rowJson(extra: {'enabled': false}),
        };

      final paused = await SchedulesClient(commands).pause(device, 'task_1');

      expect(commands.requests.single, {
        'command': 'schedule.pause',
        'expected': 'schedule.updated',
        'id': 'task_1',
      });
      expect(paused.enabled, isFalse);
      expect(paused.isPaused, isTrue);
    });

    test('resume expects the same updated event and maps an expired refusal', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedule': rowJson(extra: {'enabled': true}),
        };

      final resumed = await SchedulesClient(commands).resume(device, 'task_1');

      expect(commands.requests.single, {
        'command': 'schedule.resume',
        'expected': 'schedule.updated',
        'id': 'task_1',
      });
      expect(resumed.enabled, isTrue);

      commands.error = DeviceCommandException('Resume of an expired schedule.', code: 'schedule_expired');
      await expectLater(
        SchedulesClient(commands).resume(device, 'task_1'),
        throwsA(isA<ScheduleException>().having((error) => error.code, 'code', ScheduleErrorCode.scheduleExpired)),
      );
    });

    test('runNow reads the acceptance without inventing an outcome', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'run_id': 'run_7',
          'session_id': 'sess_2',
          'accepted_at': '2026-10-23T09:00:00.000Z',
        };

      final acceptance = await SchedulesClient(commands).runNow(device, 'task_1');

      expect(commands.requests.single, {
        'command': 'schedule.run_now',
        'expected': 'schedule.run_accepted',
        'id': 'task_1',
      });
      expect(acceptance.scheduleId, 'task_1');
      expect(acceptance.runId, 'run_7');
      expect(acceptance.sessionId, 'sess_2');
      expect(acceptance.acceptedAt, DateTime.utc(2026, 10, 23, 9));
    });
  });

  group('SchedulesClient.delete', () {
    test('always sends confirm: true and no owner_kind', () async {
      final commands = _RecordingCommands()
        ..response = {'request_id': 'req-1', 'id': 'task_1', 'deleted': true};

      await SchedulesClient(commands).delete(device, 'task_1');

      expect(commands.requests.single, {
        'command': 'schedule.delete',
        'expected': 'schedule.deleted',
        'id': 'task_1',
        'confirm': true,
      });
      expect(commands.requests.single.containsKey('owner_kind'), isFalse);
    });

    test('a response that does not report the deletion is a protocol violation', () async {
      final commands = _RecordingCommands()
        ..response = {'request_id': 'req-1', 'id': 'task_1'};

      await expectLater(
        SchedulesClient(commands).delete(device, 'task_1'),
        throwsA(isA<ScheduleException>().having((error) => error.wireCode, 'wireCode', 'deleted_absent')),
      );
    });
  });

  group('SchedulesClient.runs', () {
    test('passes limit through and forwards an opaque cursor unchanged', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedule_id': 'task_1',
          'runs': [
            {
              'id': 'run_9',
              'run_at': '2026-10-23T09:00:04.000Z',
              'status': 'succeeded',
              'trigger': 'manual',
              'duration_ms': 41230,
              'error': null,
              'session_id': 'sess_2',
              'message_id': 'msg_9c1f0d1c',
              'has_position': true,
              'anchor_event_id': 'history:sess_2:29586081:user_message:0',
              'future_run_field': 'ignored',
            },
          ],
          'has_more': true,
          'next_cursor': 'eyJ2IjoxfQ',
        };

      final page = await SchedulesClient(commands).runs(
        device,
        scheduleId: 'task_1',
        limit: 25,
        cursor: '  eyJ2IjoxLGV4dHJhfQ  ',
      );

      expect(commands.requests.single, {
        'command': 'schedule.runs',
        'expected': 'schedule.runs_result',
        'schedule_id': 'task_1',
        'limit': 25,
        'cursor': 'eyJ2IjoxLGV4dHJhfQ',
      });
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'eyJ2IjoxfQ');
      final run = page.runs.single;
      expect(run.id, 'run_9');
      expect(run.status, ScheduleRunStatus.succeeded);
      expect(run.trigger, ScheduleRunTrigger.manual);
      expect(run.durationMs, 41230);
      expect(run.error, isNull);
      expect(run.messageId, 'msg_9c1f0d1c');
      expect(run.hasPosition, isTrue);
      expect(run.anchorEventId, 'history:sess_2:29586081:user_message:0');
      expect(run.canOpenConversation, isTrue);
    });

    test('a run row from an Agent without anchor_event_id still parses', () async {
      // The field is additive: an older Agent sends none, and that means "no
      // position", not a broken row (Task 139 F2).
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedule_id': 'task_1',
          'runs': [
            {
              'id': 'run_1',
              'run_at': '2026-10-23T09:00:04.000Z',
              'status': 'succeeded',
              'trigger': 'scheduled',
              'duration_ms': 1200,
              'error': null,
              'session_id': 'sess_1',
              'message_id': 'msg_1',
              'has_position': true,
            },
          ],
          'has_more': false,
        };

      final run = (await SchedulesClient(commands).runs(device, scheduleId: 'task_1')).runs.single;

      expect(run.anchorEventId, isNull);
      expect(run.messageId, 'msg_1', reason: 'the identity is still projected, just not an anchor');
      expect(run.canOpenConversation, isTrue, reason: 'the conversation itself can still be opened');
    });

    test('a blank anchor_event_id is absent, not an empty anchor', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedule_id': 'task_1',
          'runs': [
            {
              'id': 'run_1',
              'run_at': '2026-10-23T09:00:04.000Z',
              'status': 'failed',
              'trigger': 'manual',
              'session_id': 'sess_1',
              'anchor_event_id': '   ',
            },
          ],
          'has_more': false,
        };

      final run = (await SchedulesClient(commands).runs(device, scheduleId: 'task_1')).runs.single;

      expect(run.anchorEventId, isNull);
    });

    test('omits limit and cursor when they are not supplied', () async {
      final commands = _RecordingCommands()
        ..response = {'request_id': 'req-1', 'schedule_id': 'task_1', 'runs': [], 'has_more': false};

      final page = await SchedulesClient(commands).runs(device, scheduleId: 'task_1');

      expect(commands.payload, {'schedule_id': 'task_1'});
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
      expect(page.runs, isEmpty);
    });

    test('a position without a conversation is not navigable', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'schedule_id': 'task_1',
          'runs': [
            {
              'id': 'run_1',
              'run_at': '2026-10-23T09:00:04.000Z',
              'status': 'failed',
              'trigger': 'scheduled',
              'duration_ms': null,
              'error': 'Provider refused the turn.',
              'session_id': null,
              'message_id': 'msg_1',
              'has_position': true,
            },
          ],
          'has_more': false,
        };

      final run = (await SchedulesClient(commands).runs(device, scheduleId: 'task_1')).runs.single;

      expect(run.hasPosition, isTrue);
      expect(run.canOpenConversation, isFalse, reason: 'no session_id means nothing to open');
      expect(run.isRunning, isFalse);
      expect(run.error, 'Provider refused the turn.');
    });
  });

  group('SchedulesClient error mapping', () {
    test('every documented protocol code maps to its typed code and drops the message', () async {
      final commands = _RecordingCommands();
      final client = SchedulesClient(commands);
      const codes = {
        'invalid_request': ScheduleErrorCode.invalidRequest,
        'invalid_schedule': ScheduleErrorCode.invalidSchedule,
        'schedule_not_found': ScheduleErrorCode.scheduleNotFound,
        'schedule_expired': ScheduleErrorCode.scheduleExpired,
        'schedule_orphaned': ScheduleErrorCode.scheduleOrphaned,
        'permission_denied': ScheduleErrorCode.permissionDenied,
        'internal_error': ScheduleErrorCode.internalError,
      };

      for (final entry in codes.entries) {
        commands.error = DeviceCommandException('Operator-facing detail.', code: entry.key);
        await expectLater(
          client.pause(device, 'task_1'),
          throwsA(
            isA<ScheduleException>()
                .having((error) => error.code, 'code', entry.value)
                .having((error) => error.scheduleId, 'scheduleId', 'task_1')
                .having((error) => error.wireCode, 'wireCode', isNull),
          ),
          reason: entry.key,
        );
      }
    });

    test('an unknown code keeps its wire token and an unmapped failure is deviceUnavailable', () async {
      final commands = _RecordingCommands();
      final client = SchedulesClient(commands);

      commands.error = DeviceCommandException('Future code.', code: 'schedule_teleported');
      await expectLater(
        client.pause(device, 'task_1'),
        throwsA(
          isA<ScheduleException>()
              .having((error) => error.code, 'code', ScheduleErrorCode.unknown)
              .having((error) => error.wireCode, 'wireCode', 'schedule_teleported'),
        ),
      );

      commands.error = StateError('Device Laptop is not connected.');
      await expectLater(
        client.pause(device, 'task_1'),
        throwsA(isA<ScheduleException>().having((error) => error.code, 'code', ScheduleErrorCode.deviceUnavailable)),
      );

      commands.error = TimeoutException('Timed out');
      await expectLater(
        client.pause(device, 'task_1'),
        throwsA(isA<ScheduleException>().having((error) => error.code, 'code', ScheduleErrorCode.deviceUnavailable)),
      );

      // A formatted refusal never carries the Agent's message text.
      commands.error = DeviceCommandException('Operator-facing detail.', code: 'invalid_request');
      try {
        await client.create(device, const ScheduleDraft(task: 'x', definition: ScheduleDefinitionInput(kind: ScheduleKind.daily)));
        fail('expected a refusal');
      } on ScheduleException catch (error) {
        expect(error.toString(), isNot(contains('Operator-facing detail.')));
      }
    });
  });

  group('SchedulesClient broadcasts', () {
    test('schedule.changed projects no payload at all', () async {
      final commands = _RecordingCommands();
      final client = SchedulesClient(commands);
      final seen = <void>[];

      final subscription = client.changes(device).listen(seen.add);
      commands.broadcasts.add({'event': 'schedule.changed', 'payload': {'schedule_id': 'task_1', 'change': 'deleted'}});
      commands.broadcasts.add({'event': 'schedule.run_failed', 'payload': {'schedule_id': 'task_1'}});
      commands.broadcasts.add({'event': 'schedule.changed', 'payload': {}});
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(2));
      await subscription.cancel();
    });

    test('schedule.run_failed becomes a typed notice with no error text', () async {
      final commands = _RecordingCommands();
      final seen = <dynamic>[];

      final subscription = SchedulesClient(commands).runFailures(device).listen(seen.add);
      commands.broadcasts.add({
        'event': 'schedule.run_failed',
        'payload': {
          'schedule_id': 'task_1',
          'schedule_name': 'Morning brief',
          'run_id': 'run_3',
          'session_id': 'sess_2',
          'consecutive_failures': 3,
          'suggest_pause': true,
          // A later Agent that leaks text here must not reach the Client model.
          'error': 'Provider refused the turn.',
        },
      });
      commands.broadcasts.add({'event': 'schedule.run_failed', 'payload': {'schedule_id': 'task_1'}});
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.scheduleId, 'task_1');
      expect(seen.single.runId, 'run_3');
      expect(seen.single.scheduleName, 'Morning brief');
      expect(seen.single.consecutiveFailures, 3);
      expect(seen.single.suggestPause, isTrue);
      expect(seen.single.toString(), isNot(contains('Provider refused the turn.')));
      await subscription.cancel();
    });
  });
}
