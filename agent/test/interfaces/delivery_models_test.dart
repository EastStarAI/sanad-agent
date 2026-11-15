import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformFamily', () {
    test('well-known families are equal by value', () {
      expect(PlatformFamily.sanadClient, PlatformFamily('sanad_client'));
      expect(PlatformFamily.telegram, PlatformFamily('telegram'));
      expect(PlatformFamily.whatsapp, PlatformFamily('whatsapp'));
      expect(PlatformFamily.cli, PlatformFamily('cli'));
    });

    test('custom family is constructible without touching GatewayManager', () {
      final custom = PlatformFamily('discord');
      expect(custom.value, 'discord');
      expect(custom, PlatformFamily('discord'));
      expect(custom.isSanadClient, isFalse);
    });

    test('rejects empty value', () {
      expect(() => PlatformFamily(''), throwsArgumentError);
    });

    test('toJson/fromJson round-trips', () {
      final json = PlatformFamily.sanadClient.toJson();
      expect(PlatformFamily.fromJson(json), PlatformFamily.sanadClient);
    });
  });

  group('PlatformDescriptor', () {
    test('sanad_client local and cloud share family, differ on transport', () {
      const local = PlatformDescriptor.sanadClient(
        transport: PlatformTransport.local,
        platformInstanceId: 'local-daemon',
      );
      const cloud = PlatformDescriptor.sanadClient(
        transport: PlatformTransport.cloud,
        platformInstanceId: 'sanad-gateway',
      );
      expect(local.platformFamily, cloud.platformFamily);
      expect(local.transport, isNot(cloud.transport));
      expect(local, isNot(cloud));
    });

    test('cli is isolated from sanad_client', () {
      const cli = PlatformDescriptor(
        platformFamily: PlatformFamily.cli,
        transport: PlatformTransport.cli,
      );
      expect(cli.platformFamily.isSanadClient, isFalse);
    });

    test('toJson includes only non-null instance id', () {
      const withInstance = PlatformDescriptor.sanadClient(
        transport: PlatformTransport.local,
        platformInstanceId: 'local-daemon',
      );
      const withoutInstance = PlatformDescriptor.sanadClient(
        transport: PlatformTransport.cloud,
      );
      expect(withInstance.toJson(), contains('platform_instance_id'));
      expect(withoutInstance.toJson(), isNot(contains('platform_instance_id')));
    });
  });

  group('DeliveryPolicy', () {
    test('platform_family requires family', () {
      const invalid = DeliveryPolicy(scope: DeliveryScope.platformFamily);
      expect(invalid.validate(), isNotNull);
    });

    test('hardware requires target_hardware_id and family', () {
      const noTarget = DeliveryPolicy(
        scope: DeliveryScope.hardware,
        platformFamily: PlatformFamily.sanadClient,
      );
      expect(noTarget.validate(), contains('target_hardware_id'));
      const noFamily = DeliveryPolicy(
        scope: DeliveryScope.hardware,
        targetHardwareId: 'abc',
      );
      expect(noFamily.validate(), contains('platform_family'));
    });

    test('origin and device are always valid', () {
      expect(const DeliveryPolicy.origin().validate(), isNull);
      expect(const DeliveryPolicy.device().validate(), isNull);
    });

    test('toJson/fromJson round-trips every scope', () {
      final policies = [
        const DeliveryPolicy.origin(requestId: 'req-1'),
        const DeliveryPolicy.platformFamily(PlatformFamily.sanadClient),
        const DeliveryPolicy.hardware(targetHardwareId: 'desktop-A'),
        const DeliveryPolicy.device(),
      ];
      for (final p in policies) {
        final restored = DeliveryPolicy.fromJson(p.toJson());
        expect(restored.scope, p.scope);
        expect(restored.platformFamily, p.platformFamily);
        expect(restored.targetHardwareId, p.targetHardwareId);
        expect(restored.requestId, p.requestId);
        expect(restored.validate(), isNull);
      }
    });

    test('rejects unknown scope name', () {
      expect(
        () => DeliveryPolicy.fromJson({'scope': 'broadcast'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('EventId', () {
    test('generates unique, prefixed ids', () {
      final a = EventId.generate();
      final b = EventId.generate();
      expect(a, startsWith('evt_'));
      expect(b, startsWith('evt_'));
      expect(a, isNot(b));
    });
  });

  group('GatewayResponse delivery attachment', () {
    test('defaults to platform_family=sanad_client and a fresh event_id', () {
      final r = GatewayResponse(
        sessionId: 's1',
        message: Message(role: MessageRole.assistant, content: 'hi'),
      );
      expect(r.eventId, startsWith('evt_'));
      expect(r.delivery.scope, DeliveryScope.platformFamily);
      expect(r.delivery.platformFamily, PlatformFamily.sanadClient);
    });

    test('preserves event_id across copies', () {
      final r = GatewayResponse(
        sessionId: 's1',
        message: Message(role: MessageRole.assistant, content: 'hi'),
        eventId: 'evt_fixed',
      );
      final copy = r.copyWithDelivery(delivery: const DeliveryPolicy.origin());
      expect(copy.eventId, 'evt_fixed');
      expect(copy.delivery.scope, DeliveryScope.origin);
    });

    test('preserves the stream ordinal and event identity across copies', () {
      final r = GatewayResponse(
        sessionId: 's1',
        message: Message(role: MessageRole.assistant, reasoning: 'why'),
        isComplete: false,
        runId: 'r1',
        modelStepId: 'model_step_1',
        eventId: 'evt_seq',
        streamSeq: 7,
      );

      // Routing copies a response for each delivery decision; the ordinal was
      // allocated once for the delta, so no copy may renumber or drop it.
      final rescoped = r.copyWithDelivery(
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      );
      final unchanged = r.copyWithDelivery();

      for (final copy in [rescoped, unchanged]) {
        expect(copy.streamSeq, 7);
        expect(copy.eventId, 'evt_seq');
        expect(copy.runId, 'r1');
        expect(copy.modelStepId, 'model_step_1');
        expect(copy.message.reasoning, 'why');
      }
    });
  });

  group('CanonicalEvent round-trip', () {
    test('carries event_id and delivery through toJson/fromJson', () {
      final ev = CanonicalEvent(
        type: 'final_answer',
        payload: {'content': 'hi'},
        sessionId: 's1',
        runId: 'r1',
        eventId: 'evt_abc',
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      );
      final restored = CanonicalEvent.fromJson(ev.toJson());
      expect(restored.eventId, 'evt_abc');
      expect(restored.delivery?.scope, DeliveryScope.platformFamily);
      expect(restored.delivery?.platformFamily, PlatformFamily.sanadClient);
    });

    test(
      'accepts missing event_id/delivery for backward-compatible shapes',
      () {
        final restored = CanonicalEvent.fromJson(<String, dynamic>{
          'type': 'thought',
          'payload': <String, dynamic>{},
        });
        expect(restored.eventId, isNull);
        expect(restored.delivery, isNull);
      },
    );
  });
}
