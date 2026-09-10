import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:test/test.dart';

const localInstance = '11111111-1111-4111-8111-111111111111';
const remoteInstance = '22222222-2222-4222-8222-222222222222';
const unknownInstance = '33333333-3333-4333-8333-333333333333';

Map<String, dynamic> lease({
  required int revision,
  required List<String> instances,
  int leaseMs = 30000,
  bool complete = true,
}) => {
  'protocol': deliveryPresenceProtocol,
  'version': deliveryPresenceVersion,
  'type': 'cloud.delivery_interest',
  'revision': revision,
  'cloud_recipient_instances_complete': complete,
  'cloud_recipient_instance_ids': instances,
  'lease_ms': leaseMs,
};

void main() {
  late DateTime now;
  late DeliveryPresenceController controller;

  setUp(() {
    now = DateTime.utc(2026, 8, 13, 12);
    controller = DeliveryPresenceController(now: () => now);
  });

  tearDown(() => controller.dispose());

  test('fresh empty cloud-only set suppresses until lease expiry', () {
    expect(controller.shouldEmitCloud, isTrue, reason: 'unknown is fail-safe');

    expect(
      controller.acceptInterest(lease(revision: 1, instances: [])),
      isTrue,
    );
    expect(controller.shouldEmitCloud, isFalse);

    now = now.add(const Duration(seconds: 31));
    expect(controller.shouldEmitCloud, isTrue, reason: 'expiry restores cloud');
  });

  test('derives cloud-only instances from cloud minus local sets', () {
    controller.updateLocalMember(
      'socket-local',
      clientInstanceId: localInstance,
    );
    controller.acceptInterest(
      lease(revision: 4, instances: [localInstance, remoteInstance]),
    );

    expect(controller.freshCloudOnlyInstanceIds, {remoteInstance});
    expect(controller.shouldEmitCloud, isTrue);
  });

  test(
    'local disconnect immediately restores cloud egress from same lease',
    () {
      controller.updateLocalMember(
        'socket-local',
        clientInstanceId: localInstance,
      );
      controller.acceptInterest(lease(revision: 1, instances: [localInstance]));
      expect(controller.shouldEmitCloud, isFalse);

      controller.removeLocalMember('socket-local');

      expect(controller.freshCloudOnlyInstanceIds, {localInstance});
      expect(controller.shouldEmitCloud, isTrue);
    },
  );

  test('lower revision cannot replace a newer cloud set', () {
    controller.acceptInterest(lease(revision: 4, instances: [remoteInstance]));

    expect(
      controller.acceptInterest(lease(revision: 3, instances: [])),
      isFalse,
    );
    expect(controller.freshCloudOnlyInstanceIds, {remoteInstance});
  });

  test('incomplete or malformed lease clears prior suppression', () {
    controller.acceptInterest(lease(revision: 1, instances: []));
    expect(controller.shouldEmitCloud, isFalse);

    expect(
      controller.acceptInterest(
        lease(revision: 2, instances: [], complete: false),
      ),
      isFalse,
    );
    expect(controller.shouldEmitCloud, isTrue);

    controller.acceptInterest(lease(revision: 3, instances: []));
    expect(
      controller.acceptInterest({
        ...lease(revision: 4, instances: []),
        'cloud_recipient_instance_ids': ['not-a-client-instance'],
      }),
      isFalse,
    );
    expect(controller.shouldEmitCloud, isTrue);
  });

  test('duplicate or oversized recipient sets fail toward cloud', () {
    expect(
      controller.acceptInterest(
        lease(revision: 1, instances: [localInstance, localInstance]),
      ),
      isFalse,
    );
    expect(controller.shouldEmitCloud, isTrue);

    final oversized = List<String>.generate(
      deliveryPresenceMaxRecipientInstances + 1,
      (index) =>
          '${index.toRadixString(16).padLeft(8, '0')}-1111-4111-8111-111111111111',
    );
    expect(
      controller.acceptInterest(lease(revision: 2, instances: oversized)),
      isFalse,
    );
    expect(controller.shouldEmitCloud, isTrue);
  });

  test(
    'fresh empty set gates before response serialization dependencies',
    () async {
      controller.acceptInterest(lease(revision: 1, instances: []));
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

  test('event-local delivery is cloud-relevant, consumable, and bounded', () {
    controller.acceptInterest(
      lease(revision: 1, instances: [localInstance, remoteInstance]),
    );
    controller.recordLocalDelivery('event-1', [localInstance, unknownInstance]);

    expect(controller.takeLocalDelivery('event-1'), {localInstance});
    expect(controller.takeLocalDelivery('event-1'), isEmpty);

    for (
      var index = 0;
      index <= deliveryPresenceMaxPendingLocalEvents;
      index++
    ) {
      controller.recordLocalDelivery('bounded-$index', [remoteInstance]);
    }
    expect(controller.takeLocalDelivery('bounded-0'), isEmpty);
    expect(
      controller.takeLocalDelivery(
        'bounded-$deliveryPresenceMaxPendingLocalEvents',
      ),
      {remoteInstance},
    );
  });

  test('connect disconnect and replacement transitions fail without loss', () {
    controller.acceptInterest(lease(revision: 1, instances: [localInstance]));
    controller.updateLocalMember('old-socket', clientInstanceId: localInstance);
    expect(controller.shouldEmitCloud, isFalse);

    controller.recordLocalDelivery('delivered-before-disconnect', [
      localInstance,
    ]);
    controller.removeLocalMember('old-socket');
    expect(controller.shouldEmitCloud, isTrue);
    expect(controller.takeLocalDelivery('delivered-before-disconnect'), {
      localInstance,
    });

    controller.updateLocalMember(
      'failed-socket',
      clientInstanceId: localInstance,
    );
    controller.recordLocalDelivery('failed-local-write', const <String>[]);
    controller.removeLocalMember('failed-socket');
    expect(controller.shouldEmitCloud, isTrue);
    expect(controller.takeLocalDelivery('failed-local-write'), isEmpty);

    controller.updateLocalMember(
      'replacement-socket',
      clientInstanceId: localInstance,
    );
    expect(controller.shouldEmitCloud, isFalse);
  });

  test('expired interest consumes event-local delivery without excluding', () {
    controller.acceptInterest(lease(revision: 1, instances: [localInstance]));
    controller.recordLocalDelivery('event-1', [localInstance]);
    now = now.add(const Duration(seconds: 31));

    expect(controller.takeLocalDelivery('event-1'), isEmpty);
    expect(controller.takeLocalDelivery('event-1'), isEmpty);
  });

  test('local membership stays in-memory and connection-scoped', () {
    controller.updateLocalMember('socket-a', clientInstanceId: localInstance);
    controller.updateLocalMember('socket-b', clientInstanceId: remoteInstance);
    controller.removeLocalMember('socket-a');

    expect(controller.localInstanceIds, {remoteInstance});
  });
}
