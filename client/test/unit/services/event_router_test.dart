library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/socket/event_router.dart';

void main() {
  late EventRouter router;

  setUp(() => router = EventRouter());
  tearDown(() => router.dispose());

  group('Device-scoped routing', () {
    test('routes an event to the matching device stream', () async {
      final received = <Map<String, dynamic>>[];
      final sub = router.forDevice('device-1').listen(received.add);

      router.routeEvent({
        'device_id': 'device-1',
        'event': 'sessions_list',
        'payload': {'sessions': []},
      });

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.single['event'], 'sessions_list');

      await sub.cancel();
    });

    test('merges an explicit device alias set without widening', () async {
      final received = <Map<String, dynamic>>[];
      final sub = router.forDevices({'hardware-1', 'cloud-1'}).listen(received.add);

      for (final deviceId in ['hardware-1', 'cloud-1', 'other-1']) {
        router.routeEvent({
          'device_id': deviceId,
          'event': 'final_answer',
          'payload': {'content': deviceId},
        });
      }

      await Future<void>.delayed(Duration.zero);
      expect(received.map((event) => event['device_id']), ['hardware-1', 'cloud-1']);

      await sub.cancel();
    });

    test('does not route an event to a different device stream', () async {
      final device1Events = <Map<String, dynamic>>[];
      final device2Events = <Map<String, dynamic>>[];

      final s1 = router.forDevice('device-1').listen(device1Events.add);
      final s2 = router.forDevice('device-2').listen(device2Events.add);

      router.routeEvent({
        'device_id': 'device-1',
        'event': 'final_answer',
        'payload': {'content': 'hello'},
      });

      await Future<void>.delayed(Duration.zero);
      expect(device1Events, hasLength(1));
      expect(device2Events, isEmpty);

      await s1.cancel();
      await s2.cancel();
    });

    test('ignores events without device_id', () async {
      final received = <Map<String, dynamic>>[];
      final sub = router.forDevice('device-1').listen(received.add);

      expect(() => router.routeEvent({'event': 'orphan_event'}), returnsNormally);

      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      await sub.cancel();
    });

    test('ignores events with an empty device_id', () async {
      final received = <Map<String, dynamic>>[];
      final sub = router.forDevice('device-1').listen(received.add);

      router.routeEvent({
        'device_id': '',
        'event': 'ack',
        'payload': {'status': 'started'},
      });

      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      await sub.cancel();
    });

    test('multiple listeners on the same device stream receive the event', () async {
      final listener1 = <Map<String, dynamic>>[];
      final listener2 = <Map<String, dynamic>>[];

      final s1 = router.forDevice('device-1').listen(listener1.add);
      final s2 = router.forDevice('device-1').listen(listener2.add);

      router.routeEvent({
        'device_id': 'device-1',
        'type': 'device_event',
        'event': 'session_updated',
        'payload': {'title': 'Updated'},
      });

      await Future<void>.delayed(Duration.zero);
      expect(listener1, hasLength(1));
      expect(listener2, hasLength(1));

      await s1.cancel();
      await s2.cancel();
    });
  });
}
