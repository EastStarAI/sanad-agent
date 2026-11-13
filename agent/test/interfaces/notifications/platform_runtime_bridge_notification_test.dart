import 'dart:async';

import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/notifications/client_instance_profiles.dart';
import 'package:sanad_agent/interfaces/notifications/notification_dispatcher.dart';
import 'package:sanad_agent/interfaces/notifications/notification_payload.dart';
import 'package:sanad_agent/interfaces/notifications/notification_presence.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

const _sessionId = 'session-1';
const _instance = '11111111-1111-4111-8111-111111111111';

final class _Presence implements NotificationTargetPresence {
  _Presence(this.attached);

  final Set<String> attached;

  @override
  bool isInstanceAttached(String clientInstanceId) =>
      attached.contains(clientInstanceId.toLowerCase());
}

final class _Harness {
  _Harness({Set<String>? attached, bool withNotifications = true}) {
    final dispatcher = withNotifications
        ? NotificationDispatcher(
            sink: instructions.add,
            presence: _Presence(attached ?? {_instance}),
            profiles: profiles,
            sessionTitle: (sessionId) => 'Fix the build',
          )
        : null;
    this.dispatcher = dispatcher;
    bridge = PlatformRuntimeBridge(notifications: dispatcher);
  }

  final List<NotificationInstructionMessage> instructions = [];
  final ClientInstanceProfiles profiles = ClientInstanceProfiles();
  final List<GatewayResponse> responses = [];
  late final NotificationDispatcher? dispatcher;
  late final PlatformRuntimeBridge bridge;

  void registerOrigin({PlatformFamily family = PlatformFamily.sanadClient}) {
    bridge
      ..registerSessionOrigin(
        _sessionId,
        OriginContext(
          platformFamily: family,
          transport: family == PlatformFamily.cli
              ? PlatformTransport.cli
              : PlatformTransport.local,
          platformId: 'local-daemon',
          sessionId: _sessionId,
          clientInstanceId: _instance,
        ),
      )
      ..attachResponseSink(responses.add);
  }

  List<Map<String, dynamic>> get dispatches => [
    for (final instruction in instructions)
      if (instruction.eventType == CanonicalEventTypes.notificationDispatch)
        instruction.payload[NotificationWire.payloadKey]
            as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> get withdrawals => [
    for (final instruction in instructions)
      if (instruction.eventType == CanonicalEventTypes.notificationWithdraw)
        instruction.payload[NotificationWire.payloadKey]
            as Map<String, dynamic>,
  ];

  Future<Map<String, dynamic>> ask({
    Map<String, dynamic> payload = const {
      'request_id': 'permission-1',
      'tool_name': 'shell_execute',
      'tool_input': {'command': 'git status'},
    },
  }) => bridge.requestToolPermission(sessionId: _sessionId, payload: payload);

  void respond({
    String requestId = 'permission-1',
    Map<String, dynamic> decision = const {'allowed': true},
  }) {
    expect(
      bridge.handleProtocolEvent(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: _sessionId,
          payload: {
            'session_id': _sessionId,
            'request_id': requestId,
            ...decision,
          },
        ),
      ),
      isTrue,
    );
  }
}

void main() {
  group('bridge to notification dispatcher', () {
    test(
      'a permission ask dispatches to the origin and withdraws on resolve',
      () async {
        final harness = _Harness()..registerOrigin();
        final pending = harness.ask();
        await Future<void>.delayed(Duration.zero);

        expect(harness.dispatches, hasLength(1));
        final dispatched = harness.dispatches.single;
        expect(dispatched['step'], 'origin');
        expect(dispatched['kind'], 'permission_request');
        expect(dispatched['title'], 'Fix the build');
        expect(dispatched['body'], contains('git status'));
        expect((dispatched['target'] as Map)['client_instance_id'], _instance);

        harness.respond();
        await pending;

        expect(harness.withdrawals, hasLength(1));
        expect(harness.withdrawals.single['reason'], 'resolved');
        // The ask's canonical event id is preserved as the notification identity.
        final requestEvent = harness.responses.firstWhere(
          (response) =>
              response.message.metadata?['canonical_event_type'] ==
              CanonicalEventTypes.toolPermissionRequest,
        );
        expect(dispatched['event_id'], requestEvent.eventId);
      },
    );

    test('an ask-user payload is a user question, not a permission', () async {
      final harness = _Harness()..registerOrigin();
      final pending = harness.ask(
        payload: const {
          'request_id': 'ask-1',
          'tool_name': 'system_ask_user',
          'questions': [
            {
              'question': 'Which database should I target?',
              'options': ['local', 'staging', 'production'],
            },
          ],
        },
      );
      await Future<void>.delayed(Duration.zero);

      final dispatched = harness.dispatches.single;
      expect(dispatched['kind'], 'user_question');
      expect(dispatched['body'], 'Which database should I target?');
      expect(
        (dispatched['actions'] as List).map((action) => (action as Map)['id']),
        ['answer', 'open'],
      );

      harness.respond(requestId: 'ask-1', decision: const {'answer': 'local'});
      await pending;
    });

    test(
      'a secret request is a user-input ask and never quotes field names',
      () async {
        final harness = _Harness()..registerOrigin();
        final pending = harness.ask(
          payload: const {
            'request_id': 'secret-1',
            'tool_name': 'system_request_secret',
            'reason': 'A deployment token is required to continue.',
            'fields': [
              {'name': 'DEPLOY_TOKEN', 'label': 'Deployment token'},
            ],
          },
        );
        await Future<void>.delayed(Duration.zero);

        final dispatched = harness.dispatches.single;
        expect(dispatched['kind'], 'user_question');
        expect(
          dispatched['body'],
          'A deployment token is required to continue.',
        );
        expect(dispatched.toString(), isNot(contains('DEPLOY_TOKEN')));

        // The form itself stays open: a secret decision needs values this test
        // never supplies, and an open suspension is the real state after an ask.
        unawaited(pending);
      },
    );

    test('a CLI-originated ask fans out immediately with no timer', () async {
      final harness = _Harness()..registerOrigin(family: PlatformFamily.cli);
      final pending = harness.ask();
      await Future<void>.delayed(Duration.zero);

      expect(harness.dispatches.single['step'], 'immediate');
      expect((harness.dispatches.single['target'] as Map)['scope'], 'account');
      expect(
        harness.dispatcher!.isEscalationArmed(
          sessionId: _sessionId,
          requestId: 'permission-1',
        ),
        isFalse,
      );

      harness.respond();
      await pending;
    });

    test('a late second response never withdraws twice', () async {
      final harness = _Harness()..registerOrigin();
      final pending = harness.ask();
      await Future<void>.delayed(Duration.zero);

      harness.respond();
      await pending;
      harness.respond();

      expect(harness.withdrawals, hasLength(1));
    });
  });

  group('bridge without a notification owner', () {
    test(
      'a suspension is delivered with no instruction and no throw',
      () async {
        final harness = _Harness(withNotifications: false)..registerOrigin();
        final pending = harness.ask();
        await Future<void>.delayed(Duration.zero);

        expect(harness.instructions, isEmpty);
        expect(harness.responses, isNotEmpty);

        harness.respond();
        await pending;
        expect(harness.instructions, isEmpty);
      },
    );
  });
}
