import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/notifications/application/notification_presence_store.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/notifications/application/notification_session_opener.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_collapse_key.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_deep_link.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_ask_registry.dart';

Map<String, dynamic> _request({
  String sessionId = 's1',
  String requestId = 'r1',
  String? eventType = 'tool_permission_request',
}) {
  return <String, dynamic>{
    'type': 'device_event',
    'event': eventType,
    'event_id': 'evt-ask',
    'session_id': sessionId,
    'request_id': requestId,
    'payload': <String, dynamic>{
      'request_id': requestId,
      'session_id': sessionId,
      'tool_name': 'shell',
      'permission_class': 'execute',
      'scope': 'once',
    },
  };
}

NotificationPayload _payload({String sessionId = 's1', String? requestId = 'r1'}) {
  final collapseKey = NotificationCollapseKey.forAsk(
    sessionId: sessionId,
    kind: NotificationKind.permissionRequest,
  );
  return NotificationPayload(
    eventId: 'evt-1',
    kind: NotificationKind.permissionRequest,
    urgency: NotificationUrgency.high,
    deepLink: NotificationDeepLink(sessionId: sessionId, requestId: requestId),
    collapseKey: collapseKey,
    notificationId: NotificationCollapseKey.notificationId(collapseKey),
  );
}

void main() {
  group('NotificationAskRegistry', () {
    test('remembers the ask an event delivered', () {
      final registry = NotificationAskRegistry();

      registry.observe(_request());

      expect(registry.pendingFor('s1')?.requestId, 'r1');
      expect(registry.isPending(sessionId: 's1', requestId: 'r1'), isTrue);
      expect(registry.isPending(sessionId: 's1', requestId: 'other'), isFalse);
      expect(registry.pendingFor('s2'), isNull);
    });

    test('a resolution names the session it ended', () {
      final registry = NotificationAskRegistry();
      registry.observe(_request());

      final resolved = registry.observe(_request(eventType: 'tool_permission_resolved'));

      expect(resolved, 's1');
      expect(registry.pendingFor('s1'), isNull);
    });

    test('a resolution for another request leaves the pending ask alone', () {
      final registry = NotificationAskRegistry();
      registry.observe(_request());

      final resolved = registry.observe(_request(eventType: 'tool_permission_resolved', requestId: 'r2'));

      expect(resolved, isNull);
      expect(registry.pendingFor('s1')?.requestId, 'r1');
    });

    test('a stopped session ends its ask', () {
      final registry = NotificationAskRegistry();
      registry.observe(_request());

      final resolved = registry.observe(_request(eventType: 'stopped'));

      expect(resolved, 's1');
      expect(registry.isPending(sessionId: 's1', requestId: null), isFalse);
    });

    test('a terminal event with no ask reports nothing to withdraw', () {
      final registry = NotificationAskRegistry();

      expect(registry.observe(_request(eventType: 'tool_permission_resolved')), isNull);
    });

    test('stays bounded by evicting the oldest ask first', () {
      final registry = NotificationAskRegistry(maxEntries: 2);

      registry.observe(_request(sessionId: 's1', requestId: 'r1'));
      registry.observe(_request(sessionId: 's2', requestId: 'r2'));
      registry.observe(_request(sessionId: 's3', requestId: 'r3'));

      expect(registry.size, 2);
      expect(registry.pendingFor('s1'), isNull);
      expect(registry.pendingFor('s3')?.requestId, 'r3');
    });

    test('ignores an ask with no request identity', () {
      final registry = NotificationAskRegistry();

      registry.observe(<String, dynamic>{
        'event': 'tool_permission_request',
        'session_id': 's1',
        'payload': <String, dynamic>{'session_id': 's1'},
      });

      expect(registry.size, 0);
    });
  });

  group('NotificationPresenceStore', () {
    test('nothing is on screen until a surface reports itself', () {
      final store = NotificationPresenceStore();

      expect(store.presence.windowVisible, isFalse);
      expect(store.presence.sessionId, isNull);
    });

    test('reports the session on screen and its pending request', () {
      final store = NotificationPresenceStore();
      store.setWindowVisible(true);
      store.reportConversationSurface(deviceId: 'd1', sessionId: 's1');
      store.reportPendingRequest('r1');

      expect(store.presence.showsAsk(sessionId: 's1', requestId: 'r1'), isTrue);
      expect(store.presence.showsAsk(sessionId: 's2', requestId: 'r1'), isFalse);
    });

    test('hiding the window keeps the session but stops matching', () {
      final store = NotificationPresenceStore();
      store.setWindowVisible(true);
      store.reportConversationSurface(deviceId: 'd1', sessionId: 's1');

      store.setWindowVisible(false);

      expect(store.presence.sessionId, 's1');
      expect(store.presence.showsAsk(sessionId: 's1', requestId: null), isFalse);
    });

    test('clearing the surface keeps window visibility', () {
      final store = NotificationPresenceStore();
      store.setWindowVisible(true);
      store.reportConversationSurface(deviceId: 'd1', sessionId: 's1');

      store.clearConversationSurface();

      expect(store.presence.sessionId, isNull);
      expect(store.presence.windowVisible, isTrue);
    });

    test('a pending request for no session is dropped', () {
      final store = NotificationPresenceStore();
      store.setWindowVisible(true);

      store.reportPendingRequest('r1');

      expect(store.presence.requestId, isNull);
    });
  });

  group('NotificationSessionOpener', () {
    test('resolves the agent that raised the notification', () {
      final opened = <ConversationDestination>[];
      final opener = _opener(opened: opened);

      final agent = opener.resolveAgent(sessionId: 's1', deviceId: 'cloud-2');

      expect(agent?.id, 'agent-2');
    });

    test('falls back to the cached session index when the envelope has no identity', () {
      final opener = _opener(opened: <ConversationDestination>[]);

      final agent = opener.resolveAgent(sessionId: 'session-of-agent-1');

      expect(agent?.id, 'agent-1');
    });

    test('falls back to the active device as a last resort', () {
      final opener = _opener(opened: <ConversationDestination>[]);

      final agent = opener.resolveAgent(sessionId: 'unknown-session');

      expect(agent?.id, 'agent-1');
    });

    test('fails closed when no device is known', () {
      final opener = NotificationSessionOpener(
        readDevices: () => const [],
        sessionsForDevice: (_) => const [],
        activeDeviceId: () => null,
        openDestination: (_) async {},
        showWindow: () async {},
      );

      expect(opener.resolveAgent(sessionId: 's1'), isNull);
    });

    test('opens the resolved session after restoring the window', () async {
      final steps = <String>[];
      final opened = <ConversationDestination>[];
      final opener = NotificationSessionOpener(
        readDevices: _devices,
        sessionsForDevice: _sessionsForDevice,
        activeDeviceId: () => 'agent-1',
        openDestination: (destination) async {
          steps.add('open');
          opened.add(destination);
        },
        showWindow: () async => steps.add('show'),
      );

      await opener.open(_payload());

      expect(steps, <String>['show', 'open']);
      expect(opened.single.kind, ConversationDestinationKind.session);
      expect(opened.single.deviceId, 'agent-1');
      expect(opened.single.sessionId, 's1');
    });
  });
}

NotificationSessionOpener _opener({required List<ConversationDestination> opened}) {
  return NotificationSessionOpener(
    readDevices: _devices,
    sessionsForDevice: _sessionsForDevice,
    activeDeviceId: () => 'agent-1',
    openDestination: (destination) async => opened.add(destination),
    showWindow: () async {},
  );
}

List<DeviceConfig> _devices() => <DeviceConfig>[
      DeviceConfig(
        id: 'agent-1',
        name: 'Local',
        hardwareId: 'hw-1',
        metadata: const <String, dynamic>{'cloud_device_id': 'cloud-1'},
      ),
      DeviceConfig(
        id: 'agent-2',
        name: 'Remote',
        hardwareId: 'hw-2',
        metadata: const <String, dynamic>{'cloud_device_id': 'cloud-2'},
      ),
    ];

List<Session> _sessionsForDevice(String deviceId) => <Session>[
      if (deviceId == 'agent-1')
        Session(
          id: 'session-of-agent-1',
          title: 'Local session',
          deviceId: 'agent-1',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
    ];
