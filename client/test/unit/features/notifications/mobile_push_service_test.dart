import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/application/mobile_push_service.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/mobile_foreground_policy.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_ask_registry.dart';

class _FakeAdapter implements NotificationPlatformAdapter {
  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];
  final List<int> cancelled = <int>[];

  @override
  bool get isSupported => true;

  @override
  bool get supportsApprovalActions => true;

  @override
  bool get canOpenSystemSettings => false;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
    Map<NotificationKind, String> kindLabels = const <NotificationKind, String>{},
  }) async {}

  @override
  Future<NotificationPermissionStatus> checkPermission() async => NotificationPermissionStatus.granted;

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async => null;

  @override
  Future<NotificationPermissionStatus> requestPermission() async => NotificationPermissionStatus.granted;

  @override
  Future<void> show(NotificationPresentationRequest request) async => shown.add(request);

  @override
  Future<bool> cancel(int notificationId) async {
    cancelled.add(notificationId);
    return true;
  }

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> dispose() async {}
}

class _FakeTransport implements MobilePushTransport {
  final StreamController<MobilePushMessage> displayController =
      StreamController<MobilePushMessage>.broadcast();
  final StreamController<MobilePushMessage> interactionController =
      StreamController<MobilePushMessage>.broadcast();
  final StreamController<MobilePushToken> tokenController = StreamController<MobilePushToken>.broadcast();
  MobilePushMessage? initial;
  final List<String?> visibleSessions = <String?>[];

  @override
  bool get isSupported => true;

  @override
  Stream<MobilePushMessage> get displays => displayController.stream;

  @override
  Stream<MobilePushMessage> get interactions => interactionController.stream;

  @override
  Stream<MobilePushToken> get tokenRefreshes => tokenController.stream;

  @override
  Future<MobilePushMessage?> takeInitialMessage() async => initial;

  @override
  Future<MobilePushToken?> currentToken() async => null;

  @override
  Future<void> ensureRegistration() async {}

  @override
  Future<void> reportVisibleSession(String? sessionId) async => visibleSessions.add(sessionId);

  @override
  Future<void> dispose() async {}
}

final NotificationCopy _copy = NotificationCopy(
  title: 'Fallback title',
  body: 'Fallback body',
  actionLabels: <NotificationActionIntent, String>{
    NotificationActionIntent.allowOnce: 'Allow once',
    NotificationActionIntent.allowSession: 'Allow for this session',
    NotificationActionIntent.deny: 'Deny',
    NotificationActionIntent.open: 'Open',
  },
);

/// The canonical notification event the socket also delivers.
Map<String, dynamic> _notification({
  String eventId = 'evt-1',
  String sessionId = 's1',
  String requestId = 'r1',
  String? expiresAt,
}) {
  return <String, dynamic>{
    'event': 'notification',
    'event_id': eventId,
    'session_id': sessionId,
    'payload': <String, dynamic>{
      'kind': 'permission_request',
      'urgency': 'high',
      'title': 'Approve the command?',
      'body': 'shell wants to run ls',
      'deep_link': <String, dynamic>{'session_id': sessionId, 'request_id': requestId},
      if (expiresAt != null) 'expires_at': expiresAt,
    },
  };
}

MobilePushMessage _push(Map<String, dynamic> event, {String? actionId}) {
  return MobilePushMessage.fromData(<String, Object?>{
    MobilePushMessage.envelopeKey: jsonEncode(event),
    if (actionId != null) MobilePushMessage.actionKey: actionId,
  });
}

Map<String, dynamic> _request({String eventType = 'tool_permission_request', String requestId = 'r1'}) {
  return <String, dynamic>{
    'event': eventType,
    'event_id': 'evt-ask-$eventType',
    'session_id': 's1',
    'request_id': requestId,
    'payload': <String, dynamic>{
      'request_id': requestId,
      'session_id': 's1',
      'tool_name': 'shell',
      'permission_class': 'execute',
      'scope': 'once',
    },
  };
}

void main() {
  late _FakeAdapter adapter;
  late _FakeTransport transport;
  late NotificationService notifications;
  late NotificationAskRegistry asks;
  late MobilePushService service;
  late NotificationPresence presence;
  late DateTime now;
  late List<DeviceSuspendedRequest> responded;
  late List<NotificationActionIntent> respondedIntents;
  late List<String> opened;

  setUp(() async {
    now = DateTime.utc(2026, 1, 1, 12);
    adapter = _FakeAdapter();
    transport = _FakeTransport();
    asks = NotificationAskRegistry();
    presence = NotificationPresence.none;
    responded = <DeviceSuspendedRequest>[];
    respondedIntents = <NotificationActionIntent>[];
    opened = <String>[];

    final router = NotificationActionRouter(
      readPendingAsk: asks.pendingFor,
      openSession: (payload) async => opened.add(payload.sessionId),
      respondToAsk: (request, intent, payload) async {
        responded.add(request);
        respondedIntents.add(intent);
      },
      clock: () => now,
    );

    notifications = NotificationService(
      adapter: adapter,
      eventStreams: const <Stream<Map<String, dynamic>>>[],
      copyResolver: (NotificationKind kind) => _copy,
      readPreferences: () => const NotificationPreferences(),
      readPermission: () => NotificationPermissionStatus.granted,
      readPresence: () => presence,
      readApprovalActionLabels: () => _copy.actionLabels,
      readKindLabels: () => <NotificationKind, String>{NotificationKind.permissionRequest: 'Permission requests'},
      askRegistry: asks,
      actionRouter: router,
      clock: () => now,
    );
    await notifications.start();

    service = MobilePushService(
      transport: transport,
      notifications: notifications,
      actionRouter: router,
      readPresence: () => presence,
      isAppInForeground: () => presence.windowVisible,
      clock: () => now,
    );
  });

  tearDown(() async {
    await service.dispose();
    await notifications.dispose();
  });

  group('MobilePushService display', () {
    test('the exact session on screen raises no banner', () async {
      presence = const NotificationPresence(windowVisible: true, deviceId: 'd1', sessionId: 's1');

      final decision = await service.handleDisplay(_push(_notification()));

      expect(decision?.outcome, MobileForegroundOutcome.inAppOnly);
      expect(adapter.shown, isEmpty);
    });

    test('another session raises a heads-up notification with the Agent copy and actions', () async {
      presence = const NotificationPresence(windowVisible: true, deviceId: 'd1', sessionId: 'other');

      await service.handleDisplay(_push(_notification()));

      expect(adapter.shown, hasLength(1));
      final request = adapter.shown.single;
      expect(request.title, 'Approve the command?');
      expect(request.body, 'shell wants to run ls');
      expect(request.urgency.isInterruptive, isTrue);
      expect(request.androidChannelId, 'sanad_permission_request_high');
      expect(request.iosCategoryId, 'SANAD_PERMISSION_REQUEST');
      expect(request.actions.map((action) => action.id), containsAll(<String>['allow_once', 'deny']));
    });

    test('the same event over the socket and over push is one notification', () async {
      presence = const NotificationPresence(windowVisible: true, deviceId: 'd1', sessionId: 'other');

      await notifications.handleEvent(_notification());
      await service.handleDisplay(_push(_notification()));

      expect(adapter.shown, hasLength(1));
    });

    test('an expired arrival never wakes the device', () async {
      presence = const NotificationPresence(windowVisible: true, deviceId: 'd1', sessionId: 'other');

      final decision = await service.handleDisplay(
        _push(_notification(expiresAt: '2026-01-01T11:00:00.000Z')),
      );

      expect(decision, isNull);
      expect(adapter.shown, isEmpty);
    });

    test('an unreadable arrival is dropped instead of guessed', () async {
      final decision = await service.handleDisplay(
        MobilePushMessage.fromData(const <String, Object?>{'nothing': 'useful'}),
      );

      expect(decision, isNull);
      expect(adapter.shown, isEmpty);
    });
  });

  group('MobilePushService interaction', () {
    test('an approval is answered through the existing ask path', () async {
      asks.observe(_request());

      final outcome = await service.handleInteraction(
        _push(_notification(), actionId: 'allow_once'),
      );

      expect(outcome, NotificationActionOutcome.responded);
      expect(responded.single.requestId, 'r1');
      expect(respondedIntents.single, NotificationActionIntent.allowOnce);
      expect(opened, isEmpty);
    });

    test('a denial is answered through the same path', () async {
      asks.observe(_request());

      await service.handleInteraction(_push(_notification(), actionId: 'deny'));

      expect(respondedIntents.single, NotificationActionIntent.deny);
    });

    test('opening a notification navigates without answering anything', () async {
      asks.observe(_request());

      final outcome = await service.handleInteraction(_push(_notification(), actionId: 'open'));

      expect(outcome, NotificationActionOutcome.opened);
      expect(opened, <String>['s1']);
      expect(responded, isEmpty);
    });

    test('an approval for an already resolved ask is dropped', () async {
      asks.observe(_request());
      asks.observe(_request(eventType: 'tool_permission_resolved'));

      final outcome = await service.handleInteraction(
        _push(_notification(), actionId: 'allow_once'),
      );

      expect(outcome, NotificationActionOutcome.stale);
      expect(responded, isEmpty);
    });

    test('an approval for an unknown ask fails closed', () async {
      final outcome = await service.handleInteraction(
        _push(_notification(), actionId: 'allow_once'),
      );

      expect(outcome, NotificationActionOutcome.stale);
      expect(responded, isEmpty);
    });

    test('an interaction with an expired ask is stale even when the ask is pending', () async {
      asks.observe(_request());

      final outcome = await service.handleInteraction(
        _push(_notification(expiresAt: '2026-01-01T11:00:00.000Z'), actionId: 'allow_once'),
      );

      expect(outcome, NotificationActionOutcome.stale);
      expect(responded, isEmpty);
    });

    test('a launch interaction is handled once the service starts', () async {
      asks.observe(_request());
      transport.initial = _push(_notification(), actionId: 'allow_session');

      await service.start();

      expect(respondedIntents.single, NotificationActionIntent.allowSession);
    });
  });
}
