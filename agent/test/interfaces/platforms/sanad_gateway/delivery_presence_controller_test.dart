import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late DeliveryPresenceController controller;

  setUp(() {
    now = DateTime.utc(2026, 8, 13, 12);
    controller = DeliveryPresenceController(now: () => now);
  });

  tearDown(() => controller.dispose());

  test('zero interest suppresses cloud only while a valid lease is fresh', () {
    expect(controller.shouldEmitCloud, isTrue, reason: 'unknown is fail-open');

    expect(
      controller.acceptInterest({
        'protocol': deliveryPresenceProtocol,
        'version': deliveryPresenceVersion,
        'type': 'cloud.delivery_interest',
        'revision': 1,
        'cloud_recipient_count': 0,
        'lease_ms': 30000,
      }),
      isTrue,
    );
    expect(controller.shouldEmitCloud, isFalse);

    now = now.add(const Duration(seconds: 31));
    expect(controller.shouldEmitCloud, isTrue, reason: 'expiry restores cloud');
  });

  test(
    'positive interest emits one cloud copy and stale revisions are ignored',
    () {
      controller.acceptInterest({
        'protocol': deliveryPresenceProtocol,
        'version': deliveryPresenceVersion,
        'type': 'cloud.delivery_interest',
        'revision': 4,
        'cloud_recipient_count': 2,
        'lease_ms': 30000,
      });

      expect(controller.shouldEmitCloud, isTrue);
      expect(
        controller.acceptInterest({
          'protocol': deliveryPresenceProtocol,
          'version': deliveryPresenceVersion,
          'type': 'cloud.delivery_interest',
          'revision': 3,
          'cloud_recipient_count': 0,
          'lease_ms': 30000,
        }),
        isFalse,
      );
      expect(controller.shouldEmitCloud, isTrue);
    },
  );

  test('malformed interest clears prior suppression for safe fallback', () {
    controller.acceptInterest({
      'protocol': deliveryPresenceProtocol,
      'version': deliveryPresenceVersion,
      'type': 'cloud.delivery_interest',
      'revision': 1,
      'cloud_recipient_count': 0,
      'lease_ms': 30000,
    });
    expect(controller.shouldEmitCloud, isFalse);

    expect(controller.acceptInterest({'revision': 2}), isFalse);
    expect(controller.shouldEmitCloud, isTrue);
  });

  test(
    'zero interest gates before response serialization dependencies',
    () async {
      controller.acceptInterest({
        'protocol': deliveryPresenceProtocol,
        'version': deliveryPresenceVersion,
        'type': 'cloud.delivery_interest',
        'revision': 1,
        'cloud_recipient_count': 0,
        'lease_ms': 30000,
      });
      final platform = ServerSanadGatewayPlatform(deliveryPresence: controller);

      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'session-1',
          message: Message(
            role: MessageRole.assistant,
            content: 'not serialized',
          ),
        ),
      );

      // No SanadProtocolBridge is registered. Reaching translation would throw.
      expect(controller.shouldEmitCloud, isFalse);
      expect(controller.metrics, {'local': 0, 'cloud': 0, 'suppressed': 1});
    },
  );

  test(
    'local membership snapshots are full, monotonic, and connection-scoped',
    () async {
      final snapshots = <LocalPresenceSnapshot>[];
      final subscription = controller.localChanges.listen(snapshots.add);

      controller.updateLocalMember(
        'socket-a',
        clientInstanceId: 'instance-a',
        presenceAssertion: 'assertion-a',
      );
      controller.updateLocalMember(
        'socket-b',
        clientInstanceId: 'instance-b',
        presenceAssertion: 'assertion-b',
      );
      controller.removeLocalMember('socket-a');

      expect(snapshots.map((value) => value.revision), [1, 2, 3]);
      expect(snapshots[1].members.map((value) => value.clientInstanceId), {
        'instance-a',
        'instance-b',
      });
      expect(snapshots.last.members.single.clientInstanceId, 'instance-b');

      await subscription.cancel();
    },
  );
}
