import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_collapse_key.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_deep_link.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';

final DateTime _now = DateTime.utc(2026, 1, 1, 12);

NotificationPayload _payload({
  String sessionId = 's1',
  String? requestId = 'r1',
  NotificationKind kind = NotificationKind.permissionRequest,
  DateTime? expiresAt,
}) {
  final collapseKey = NotificationCollapseKey.forAsk(sessionId: sessionId, kind: kind);
  return NotificationPayload(
    eventId: 'evt-$sessionId',
    kind: kind,
    urgency: NotificationUrgency.high,
    deepLink: NotificationDeepLink(sessionId: sessionId, requestId: requestId),
    collapseKey: collapseKey,
    notificationId: NotificationCollapseKey.notificationId(collapseKey),
    expiresAt: expiresAt,
  );
}

NotificationDisplayOutcome _decide({
  NotificationPayload? payload,
  bool alreadyProcessed = false,
  NotificationPreferences preferences = const NotificationPreferences(),
  NotificationPermissionStatus permission = NotificationPermissionStatus.granted,
  bool quietWindowOpen = false,
  NotificationPresence presence = NotificationPresence.none,
  bool platformSupported = true,
  DateTime? now,
}) {
  return NotificationDisplayPolicy.decide(
    payload: payload ?? _payload(),
    alreadyProcessed: alreadyProcessed,
    preferences: preferences,
    permission: permission,
    quietWindowOpen: quietWindowOpen,
    presence: presence,
    now: now ?? _now,
    platformSupported: platformSupported,
  ).outcome;
}

void main() {
  group('NotificationDisplayPolicy', () {
    test('raises a notification when nothing suppresses it', () {
      expect(_decide(), NotificationDisplayOutcome.display);
    });

    test('suppresses while the exact session and request are on screen', () {
      expect(
        _decide(
          presence: const NotificationPresence(
            windowVisible: true,
            deviceId: 'd1',
            sessionId: 's1',
            requestId: 'r1',
          ),
        ),
        NotificationDisplayOutcome.suppressedOnScreen,
      );
    });

    test('raises for a different session in the same focused window', () {
      expect(
        _decide(
          presence: const NotificationPresence(
            windowVisible: true,
            deviceId: 'd1',
            sessionId: 'other-session',
            requestId: 'r9',
          ),
        ),
        NotificationDisplayOutcome.display,
      );
    });

    test('raises when the window is hidden even for the selected session', () {
      expect(
        _decide(
          presence: const NotificationPresence(
            windowVisible: false,
            deviceId: 'd1',
            sessionId: 's1',
            requestId: 'r1',
          ),
        ),
        NotificationDisplayOutcome.display,
      );
    });

    test('suppresses the same session before its prompt is projected', () {
      // The event reaches this decision before the conversation store has
      // projected the ask, so an on-screen session with no request hint still
      // means the user is about to see the prompt itself.
      expect(
        _decide(
          presence: const NotificationPresence(
            windowVisible: true,
            deviceId: 'd1',
            sessionId: 's1',
          ),
        ),
        NotificationDisplayOutcome.suppressedOnScreen,
      );
    });

    test('raises when the same session shows a different pending ask', () {
      expect(
        _decide(
          presence: const NotificationPresence(
            windowVisible: true,
            deviceId: 'd1',
            sessionId: 's1',
            requestId: 'another-request',
          ),
        ),
        NotificationDisplayOutcome.display,
      );
    });

    test('drops a replayed canonical event id', () {
      expect(
        _decide(alreadyProcessed: true),
        NotificationDisplayOutcome.dropDuplicate,
      );
    });

    test('suppresses during the post-connect quiet window', () {
      expect(
        _decide(quietWindowOpen: true),
        NotificationDisplayOutcome.suppressedQuietWindow,
      );
    });

    test('suppresses a kind the user turned off', () {
      expect(
        _decide(
          preferences: const NotificationPreferences().withKind(
            NotificationKind.permissionRequest,
            false,
          ),
        ),
        NotificationDisplayOutcome.suppressedDisabled,
      );
    });

    test('suppresses everything when the global switch is off', () {
      expect(
        _decide(preferences: const NotificationPreferences().withEnabled(false)),
        NotificationDisplayOutcome.suppressedDisabled,
      );
    });

    test('suppresses a kind that was never explicitly enabled but defaults on', () {
      expect(
        _decide(preferences: const NotificationPreferences(), payload: _payload(kind: NotificationKind.completed)),
        NotificationDisplayOutcome.display,
      );
    });

    test('suppresses while the OS has not granted permission', () {
      for (final status in <NotificationPermissionStatus>[
        NotificationPermissionStatus.unknown,
        NotificationPermissionStatus.denied,
        NotificationPermissionStatus.unavailable,
      ]) {
        expect(_decide(permission: status), NotificationDisplayOutcome.suppressedPermission);
      }
    });

    test('drops an expired notification before any other check', () {
      expect(
        _decide(
          payload: _payload(expiresAt: _now.subtract(const Duration(seconds: 1))),
          alreadyProcessed: true,
          quietWindowOpen: true,
        ),
        NotificationDisplayOutcome.dropExpired,
      );
    });

    test('drops everything on a platform with no notification surface', () {
      expect(
        _decide(platformSupported: false, permission: NotificationPermissionStatus.unsupported),
        NotificationDisplayOutcome.dropUnsupported,
      );
    });

    test('carries the kind and session for a content-free log line', () {
      final decision = NotificationDisplayPolicy.decide(
        payload: _payload(),
        alreadyProcessed: false,
        preferences: const NotificationPreferences(),
        permission: NotificationPermissionStatus.granted,
        quietWindowOpen: false,
        presence: NotificationPresence.none,
        now: _now,
      );

      expect(decision.reason, contains('display'));
      expect(decision.reason, contains('kind=permission_request'));
      expect(decision.reason, contains('session=s1'));
    });
  });
}
