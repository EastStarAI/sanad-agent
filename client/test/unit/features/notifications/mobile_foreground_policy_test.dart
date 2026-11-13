import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/mobile_foreground_policy.dart';

NotificationPayload _payload({
  String sessionId = 's1',
  String? requestId = 'r1',
  NotificationKind kind = NotificationKind.permissionRequest,
}) {
  return NotificationPayload.fromEvent(<String, dynamic>{
    'event': 'notification',
    'event_id': 'evt-1',
    'session_id': sessionId,
    'payload': <String, dynamic>{
      'kind': kind.wire,
      'deep_link': <String, dynamic>{
        'session_id': sessionId,
        if (requestId != null) 'request_id': requestId,
      },
    },
  })!;
}

NotificationPresence _presence({
  bool visible = true,
  String? sessionId = 's1',
  String? requestId = 'r1',
}) {
  return NotificationPresence(
    windowVisible: visible,
    deviceId: sessionId == null ? null : 'device-1',
    sessionId: sessionId,
    requestId: requestId,
  );
}

void main() {
  group('MobileForegroundPolicy', () {
    test('the exact session on screen is in-app only', () {
      final decision = MobileForegroundPolicy.decide(
        payload: _payload(),
        presence: _presence(),
        appInForeground: true,
      );

      expect(decision.outcome, MobileForegroundOutcome.inAppOnly);
      expect(decision.showsBanner, isFalse);
    });

    test('the same session with no projected ask is in-app only', () {
      final decision = MobileForegroundPolicy.decide(
        payload: _payload(),
        presence: _presence(requestId: null),
        appInForeground: true,
      );

      // The session is on screen and its prompt has not been projected yet, so
      // the arriving ask is exactly what the user is about to see.
      expect(decision.outcome, MobileForegroundOutcome.inAppOnly);
    });

    test('the same session showing a different ask raises a banner', () {
      final decision = MobileForegroundPolicy.decide(
        payload: _payload(requestId: 'r2'),
        presence: _presence(requestId: 'r1'),
        appInForeground: true,
      );

      // The shared presence rule refines by request: the ask in the notification
      // is not the one in front of the user, so a banner is the only way to show
      // that a second decision is waiting.
      expect(decision.outcome, MobileForegroundOutcome.headsUp);
    });

    test('another session raises a heads-up banner', () {
      final decision = MobileForegroundPolicy.decide(
        payload: _payload(sessionId: 's2'),
        presence: _presence(),
        appInForeground: true,
      );

      expect(decision.outcome, MobileForegroundOutcome.headsUp);
      expect(decision.sessionId, 's2');
    });

    test('a session on a hidden window is not presence', () {
      final decision = MobileForegroundPolicy.decide(
        payload: _payload(),
        presence: _presence(visible: false),
        appInForeground: true,
      );

      expect(decision.outcome, MobileForegroundOutcome.headsUp);
    });

    test('a backgrounded app always lets the system present the arrival', () {
      final decision = MobileForegroundPolicy.decide(
        payload: _payload(),
        presence: _presence(),
        appInForeground: false,
      );

      expect(decision.outcome, MobileForegroundOutcome.headsUp);
    });

    test('only the exact visible session is mirrored to the native hook', () {
      expect(
        MobileForegroundPolicy.visibleSessionForNative(_presence(), appInForeground: true),
        's1',
      );
      expect(
        MobileForegroundPolicy.visibleSessionForNative(_presence(visible: false), appInForeground: true),
        isNull,
      );
      expect(
        MobileForegroundPolicy.visibleSessionForNative(_presence(), appInForeground: false),
        isNull,
      );
      expect(
        MobileForegroundPolicy.visibleSessionForNative(
          const NotificationPresence(windowVisible: true),
          appInForeground: true,
        ),
        isNull,
      );
    });
  });
}
