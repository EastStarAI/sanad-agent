import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';

import '../../helpers/notifications/fake_web_push_client.dart';

/// Proves the web contract's foreground rules at the pipeline boundary: a push
/// is one more copy of the same canonical event, so it goes through the same
/// dedupe, expiry, preference, and presence checks as a socket delivery.
///
/// The browser itself is not exercised here; the worker's own behavior is
/// recorded as unexecuted in the owning task file.
const NotificationCopy _copy = NotificationCopy(
  title: 'Fallback title',
  body: 'Fallback body',
  actionLabels: <NotificationActionIntent, String>{
    NotificationActionIntent.open: 'Open',
  },
);

NotificationActionRouter _idleRouter(DateTime Function() clock) {
  return NotificationActionRouter(
    readPendingAsk: (String sessionId) => null,
    openSession: (NotificationPayload payload) async {},
    respondToAsk:
        (
          DeviceSuspendedRequest request,
          NotificationActionIntent intent,
          NotificationPayload payload,
        ) async {},
    clock: clock,
  );
}

Map<String, dynamic> _ask({
  String eventId = 'evt-1',
  String sessionId = 's1',
  String requestId = 'r1',
  String? expiresAt,
}) {
  return <String, dynamic>{
    'type': 'device_event',
    'event': 'notification_dispatch',
    'event_id': eventId,
    'payload': <String, dynamic>{
      'notification': <String, dynamic>{
        'instruction': 'dispatch',
        'event_id': eventId,
        'request_id': requestId,
        'kind': 'permission_request',
        'urgency': 'high',
        'title': 'Approve the command?',
        'body': 'shell wants to run ls',
        'deep_link': <String, dynamic>{'session_id': sessionId, 'request_id': requestId},
        if (expiresAt != null) 'expires_at': expiresAt,
      },
    },
  };
}

void main() {
  late FakeNotificationAdapter adapter;
  late NotificationService service;
  late StreamController<Map<String, dynamic>> socket;
  late StreamController<Map<String, dynamic>> push;
  late NotificationPresence presence;
  late NotificationPreferences preferences;
  late DateTime now;

  Future<void> mount() async {
    now = DateTime.utc(2026, 1, 1, 12);
    presence = const NotificationPresence(windowVisible: true);
    preferences = const NotificationPreferences();
    adapter = FakeNotificationAdapter();
    socket = StreamController<Map<String, dynamic>>.broadcast();
    push = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(socket.close);
    addTearDown(push.close);
    service = NotificationService(
      adapter: adapter,
      // The socket and the browser wake-up are two copies of one event stream.
      eventStreams: <Stream<Map<String, dynamic>>>[socket.stream, push.stream],
      copyResolver: (NotificationKind kind) => _copy,
      readPreferences: () => preferences,
      readPermission: () => NotificationPermissionStatus.granted,
      readPresence: () => presence,
      actionRouter: _idleRouter(() => now),
      quietWindow: NotificationQuietWindow(duration: Duration.zero, clock: () => now),
      clock: () => now,
    );
    await service.start();
    addTearDown(service.dispose);
  }

  test('a wake-up that arrives only by push displays once', () async {
    await mount();

    final decision = await service.handleEvent(_ask());

    expect(decision!.shouldDisplay, isTrue);
    expect(adapter.shown, hasLength(1));
  });

  test('the same canonical event over socket and push displays once', () async {
    await mount();

    final socketDecision = await service.handleEvent(_ask());
    final pushDecision = await service.handleEvent(_ask());

    expect(socketDecision!.shouldDisplay, isTrue);
    expect(pushDecision!.shouldDisplay, isFalse);
    expect(pushDecision.outcome.name, 'dropDuplicate');
    expect(adapter.shown, hasLength(1));
  });

  test('a wake-up for the session on screen shows nothing', () async {
    await mount();
    presence = const NotificationPresence(
      windowVisible: true,
      deviceId: 'd1',
      sessionId: 's1',
      requestId: 'r1',
    );

    final decision = await service.handleEvent(_ask());

    expect(decision!.shouldDisplay, isFalse);
    expect(decision.outcome.name, 'suppressedOnScreen');
    expect(adapter.shown, isEmpty);
  });

  test('a wake-up for another visible session still displays', () async {
    await mount();
    presence = const NotificationPresence(
      windowVisible: true,
      deviceId: 'd1',
      sessionId: 'other-session',
    );

    final decision = await service.handleEvent(_ask());

    expect(decision!.shouldDisplay, isTrue);
    expect(adapter.shown, hasLength(1));
  });

  test('a late escalation for an expired ask is dropped', () async {
    await mount();

    final decision = await service.handleEvent(
      _ask(expiresAt: now.subtract(const Duration(minutes: 1)).toIso8601String()),
    );

    expect(decision!.outcome.name, 'dropExpired');
    expect(adapter.shown, isEmpty);
  });

  test('a disabled kind is not raised from a wake-up', () async {
    await mount();
    preferences = const NotificationPreferences().withKind(NotificationKind.permissionRequest, false);

    final decision = await service.handleEvent(_ask());

    expect(decision!.outcome.name, 'suppressedDisabled');
    expect(adapter.shown, isEmpty);
  });
}
