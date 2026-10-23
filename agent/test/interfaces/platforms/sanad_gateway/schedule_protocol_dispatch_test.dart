import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import 'handlers/support/schedule_protocol_harness.dart';

/// Proves the one dispatch arm the bridge owns for Task 139: an accepted wire
/// command reaches its handler and answers the requester.
void main() {
  late ScheduleProtocolHarness harness;

  setUp(() async {
    harness = await ScheduleProtocolHarness.start();
    harness.bridge.setScheduleHandlersForTesting(
      command: harness.commands,
      query: harness.queries,
    );
  });

  tearDown(() async {
    await harness.dispose();
  });

  Map<String, dynamic> command(String name, Map<String, dynamic> payload) => {
    'command': name,
    'payload': {
      'request_id': 'req_bridge',
      CommandAuthority.payloadKey: CommandAuthority.owner.value,
      ...payload,
    },
  };

  Future<Map<String, dynamic>?> dispatch(Map<String, dynamic> data) async {
    Map<String, dynamic>? emitted;
    final handled = await harness.bridge.handleCommand(data, (envelope) async {
      emitted = envelope;
    });
    expect(handled, isTrue);
    return emitted;
  }

  test('routes schedule.create to the command handler', () async {
    final envelope = await dispatch(
      command(CanonicalEventTypes.scheduleCreate, {
        'task': 'Bridge-created task',
        'kind': 'daily',
        'time': '09:00',
        'zone': 'Z',
      }),
    );

    expect(envelope, isNotNull);
    expect(envelope!['event'], CanonicalEventTypes.scheduleCreated);
    expect(envelope['request_id'], 'req_bridge');
    expect(harness.storedScheduleCount, 1);
  });

  test('routes schedule.list to the query handler', () async {
    final envelope = await dispatch(
      command(CanonicalEventTypes.scheduleList, {}),
    );

    expect(envelope!['event'], CanonicalEventTypes.scheduleListResult);
    expect(harness.payloadOf(envelope)['schedules'], isEmpty);
  });

  test('keeps an unknown schedule command unhandled', () async {
    Map<String, dynamic>? emitted;
    final handled = await harness.bridge.handleCommand(
      command('schedule.unknown', {}),
      (envelope) async => emitted = envelope,
    );

    expect(handled, isFalse);
    expect(emitted, isNull);
  });
}
