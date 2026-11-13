import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/notifications/notification_kind.dart';
import 'package:sanad_agent/interfaces/notifications/notification_payload.dart';
import 'package:sanad_agent/interfaces/notifications/notification_policy.dart';
import 'package:sanad_agent/interfaces/notifications/notification_presence.dart';
import 'package:test/test.dart';

final class _Presence implements NotificationTargetPresence {
  _Presence(this._attached);

  final Set<String> _attached;

  @override
  bool isInstanceAttached(String clientInstanceId) =>
      _attached.contains(clientInstanceId.toLowerCase());
}

const _desktopInstance = '11111111-1111-4111-8111-111111111111';
const _phoneInstance = '22222222-2222-4222-8222-222222222222';

NotificationOrigin _sanadClientOrigin({
  String? instanceId = _desktopInstance,
  bool canNotify = true,
}) => NotificationOrigin(
  platformFamily: PlatformFamily.sanadClient,
  clientInstanceId: instanceId,
  canNotify: canNotify,
);

void main() {
  group('NotificationKind model', () {
    test('every Agent kind defaults to high urgency', () {
      for (final kind in NotificationKind.agentKinds) {
        expect(
          kind.defaultUrgency,
          NotificationUrgency.high,
          reason: '${kind.value} must not ship silent',
        );
      }
    });

    test('the plan kinds are Agent-owned and Client kinds are not', () {
      expect(
        NotificationKind.agentKinds.map((kind) => kind.value),
        containsAll(<String>[
          'permission_request',
          'user_question',
          'blocked',
          'failed',
          'completed',
          'background_task_done',
          'scheduled_result',
          'provider_quota',
        ]),
      );
      expect(NotificationKind.agentKinds, hasLength(8));
      expect(NotificationKind.connectionLost.isAgentOwned, isFalse);
      expect(NotificationKind.authRequired.isAgentOwned, isFalse);
    });

    test('a custom kind is a typed token and defaults to high', () {
      final custom = NotificationKind('deployment_ready');
      expect(custom.value, 'deployment_ready');
      expect(custom.isAgentOwned, isFalse);
      expect(custom.defaultUrgency, NotificationUrgency.high);
      expect(NotificationKind.tryParse('not a token'), isNull);
      expect(() => NotificationKind('Not-A-Token'), throwsArgumentError);
    });

    test('urgency parses its wire token and never downgrades bad input', () {
      expect(NotificationUrgency.fromWire('high'), NotificationUrgency.high);
      expect(NotificationUrgency.fromWire('low'), NotificationUrgency.low);
      expect(NotificationUrgency.fromWire('urgent'), NotificationUrgency.high);
      expect(NotificationUrgency.fromWire(null), NotificationUrgency.high);
    });
  });

  group('origin-first delivery policy', () {
    test('an attached, notifiable origin receives the first dispatch', () {
      final policy = NotificationDispatchPolicy(_Presence({_desktopInstance}));
      final plan = policy.plan(_sanadClientOrigin());

      expect(plan.step, NotificationDispatchStep.origin);
      expect(plan.armEscalation, isTrue);
      expect(plan.target.scope, NotificationTargetScope.clientInstance);
      expect(plan.target.clientInstanceId, _desktopInstance);
    });

    test(
      'an attached origin declared unable to notify fans out immediately',
      () {
        final policy = NotificationDispatchPolicy(
          _Presence({_desktopInstance}),
        );
        final plan = policy.plan(_sanadClientOrigin(canNotify: false));

        expect(plan.step, NotificationDispatchStep.immediate);
        expect(plan.armEscalation, isFalse);
        expect(plan.target, NotificationTarget.account);
      },
    );

    test('an unreachable origin fans out immediately', () {
      final policy = NotificationDispatchPolicy(_Presence({_phoneInstance}));
      final plan = policy.plan(_sanadClientOrigin());

      expect(plan.step, NotificationDispatchStep.immediate);
      expect(plan.target.isAccountWide, isTrue);
      expect(plan.armEscalation, isFalse);
    });

    test('a CLI origin is not notifiable and fans out immediately', () {
      final policy = NotificationDispatchPolicy(_Presence({_desktopInstance}));
      final plan = policy.plan(
        const NotificationOrigin(
          platformFamily: PlatformFamily.cli,
          clientInstanceId: _desktopInstance,
        ),
      );

      expect(plan.step, NotificationDispatchStep.immediate);
      expect(plan.target.isAccountWide, isTrue);
    });

    test('a missing origin fans out immediately', () {
      final policy = NotificationDispatchPolicy(_Presence({_desktopInstance}));
      final plan = policy.plan(null);

      expect(plan.step, NotificationDispatchStep.immediate);
      expect(plan.armEscalation, isFalse);
    });

    test('an origin without an instance identity cannot be targeted', () {
      final policy = NotificationDispatchPolicy(_Presence({_desktopInstance}));
      for (final instanceId in <String?>[null, '']) {
        final plan = policy.plan(_sanadClientOrigin(instanceId: instanceId));
        expect(plan.step, NotificationDispatchStep.immediate);
        expect(plan.target.isAccountWide, isTrue);
      }
    });

    test('a scheduled run with no platform family fans out immediately', () {
      final policy = NotificationDispatchPolicy(_Presence({_desktopInstance}));
      final plan = policy.plan(
        const NotificationOrigin(
          platformFamily: null,
          clientInstanceId: _desktopInstance,
        ),
      );

      expect(plan.step, NotificationDispatchStep.immediate);
    });
  });
}
