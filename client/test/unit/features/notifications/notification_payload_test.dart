import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_collapse_key.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';

Map<String, dynamic> _event({
  String name = 'notification',
  String? eventId = 'evt-1',
  String sessionId = 's1',
  String? requestId = 'r1',
  Map<String, dynamic>? payload,
}) {
  return <String, dynamic>{
    'type': 'device_event',
    'event': name,
    if (eventId != null) 'event_id': eventId,
    'device_id': 'device-cloud',
    'hardware_id': 'hw-1',
    'session_id': sessionId,
    if (requestId != null) 'request_id': requestId,
    'payload': <String, dynamic>{
      'kind': 'permission_request',
      'urgency': 'high',
      'title': 'Run a shell command?',
      'body': 'The agent wants to run rm -rf build',
      'deep_link': <String, dynamic>{'session_id': sessionId, 'request_id': requestId},
      if (payload != null) ...payload,
    },
  };
}

void main() {
  group('NotificationPayload.fromEvent', () {
    test('reads an Agent notification from the canonical envelope', () {
      final payload = NotificationPayload.fromEvent(_event());

      expect(payload, isNotNull);
      expect(payload!.eventId, 'evt-1');
      expect(payload.kind, NotificationKind.permissionRequest);
      expect(payload.urgency, NotificationUrgency.high);
      expect(payload.sessionId, 's1');
      expect(payload.requestId, 'r1');
      expect(payload.title, 'Run a shell command?');
      expect(payload.body, 'The agent wants to run rm -rf build');
      expect(payload.deviceId, 'device-cloud');
      expect(payload.hardwareId, 'hw-1');
      expect(
        payload.collapseKey,
        NotificationCollapseKey.forAsk(
          sessionId: 's1',
          kind: NotificationKind.permissionRequest,
        ),
      );
      expect(payload.notificationId, NotificationCollapseKey.notificationId(payload.collapseKey));
    });

    test('accepts the dispatch alias and a nested notification block', () {
      final payload = NotificationPayload.fromEvent(<String, dynamic>{
        'type': 'device_event',
        'event': 'notification_dispatch',
        'event_id': 'evt-2',
        'payload': <String, dynamic>{
          'notification': <String, dynamic>{
            'kind': 'user_question',
            'deep_link': <String, dynamic>{'session_id': 's9', 'request_id': 'r9'},
          },
        },
      });

      expect(payload, isNotNull);
      expect(payload!.kind, NotificationKind.userQuestion);
      expect(payload.sessionId, 's9');
      expect(payload.requestId, 'r9');
      expect(payload.urgency, NotificationUrgency.defaultUrgency);
    });

    test('ignores unrelated events', () {
      expect(
        NotificationPayload.fromEvent(<String, dynamic>{
          'event': 'final_answer',
          'event_id': 'evt-3',
          'session_id': 's1',
          'payload': <String, dynamic>{},
        }),
        isNull,
      );
    });

    test('rejects an unknown kind instead of guessing one', () {
      expect(
        NotificationPayload.fromEvent(_event(payload: <String, dynamic>{'kind': 'teleport_started'})),
        isNull,
      );
    });

    test('rejects a notification with no session identity', () {
      expect(
        NotificationPayload.fromEvent(<String, dynamic>{
          'event': 'notification',
          'event_id': 'evt-4',
          'payload': <String, dynamic>{'kind': 'completed'},
        }),
        isNull,
      );
    });

    test('takes the session from the envelope when the deep link omits it', () {
      final payload = NotificationPayload.fromEvent(<String, dynamic>{
        'event': 'notification',
        'event_id': 'evt-5',
        'session_id': 'envelope-session',
        'payload': <String, dynamic>{'kind': 'blocked'},
      });

      expect(payload?.sessionId, 'envelope-session');
      expect(payload?.requestId, isNull);
    });

    test('replaces a disagreeing Agent collapse key with the canonical one', () {
      final payload = NotificationPayload.fromEvent(
        _event(payload: <String, dynamic>{'collapse_key': 'agent-invented-key'}),
      );

      expect(
        payload!.collapseKey,
        NotificationCollapseKey.forAsk(
          sessionId: 's1',
          kind: NotificationKind.permissionRequest,
        ),
      );
    });

    test('honours an Agent collapse key that matches the derivation', () {
      final canonical = NotificationCollapseKey.forAsk(
        sessionId: 's1',
        kind: NotificationKind.permissionRequest,
      );
      final payload = NotificationPayload.fromEvent(
        _event(payload: <String, dynamic>{'collapse_key': canonical}),
      );

      expect(payload!.collapseKey, canonical);
    });

    test('keeps Agent labels and drops action ids this build cannot name', () {
      final payload = NotificationPayload.fromEvent(
        _event(
          payload: <String, dynamic>{
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'allow_once', 'label': 'Allow once'},
              <String, dynamic>{'id': 'launch_missiles', 'label': 'Now'},
              <String, dynamic>{'id': 'deny'},
            ],
          },
        ),
      );

      expect(payload!.actions.map((action) => action.id), <String>['allow_once', 'deny']);
      expect(payload.actions.first.label, 'Allow once');
      expect(payload.actions.last.label, isNull);
      expect(payload.actions.first.intent, NotificationActionIntent.allowOnce);
    });

    test('falls back to the approval action set for a permission request', () {
      final payload = NotificationPayload.fromEvent(_event());

      expect(
        payload!.actions.map((action) => action.id),
        NotificationAction.approvalActions.map((action) => action.id),
      );
    });

    test('offers no actions for a kind that cannot be answered', () {
      final payload = NotificationPayload.fromEvent(
        _event(payload: <String, dynamic>{'kind': 'completed'}),
      );

      expect(payload!.actions, isEmpty);
    });

    test('parses an expiry as ISO-8601 and as epoch milliseconds', () {
      final iso = NotificationPayload.fromEvent(
        _event(payload: <String, dynamic>{'expires_at': '2026-01-01T12:00:00Z'}),
      );
      final millis = NotificationPayload.fromEvent(
        _event(payload: <String, dynamic>{'expires_at': 1767268800000}),
      );

      expect(iso!.expiresAt, DateTime.utc(2026, 1, 1, 12));
      expect(millis!.expiresAt, DateTime.fromMillisecondsSinceEpoch(1767268800000, isUtc: true));
      expect(millis.isExpiredAt(DateTime.utc(2026, 1, 2)), isTrue);
      expect(iso.isExpiredAt(DateTime.utc(2025, 12, 31)), isFalse);
    });

    test('round-trips through the presentation payload without losing identity', () {
      final payload = NotificationPayload.fromEvent(
        _event(payload: <String, dynamic>{'expires_at': '2026-01-01T12:00:00Z'}),
      )!;

      final restored = NotificationPayload.fromPresentationPayload(payload.toPresentationPayload());

      expect(restored, isNotNull);
      expect(restored!.eventId, payload.eventId);
      expect(restored.kind, payload.kind);
      expect(restored.urgency, payload.urgency);
      expect(restored.sessionId, payload.sessionId);
      expect(restored.requestId, payload.requestId);
      expect(restored.collapseKey, payload.collapseKey);
      expect(restored.notificationId, payload.notificationId);
      expect(restored.expiresAt, payload.expiresAt);
      expect(restored.actions.map((action) => action.id), payload.actions.map((action) => action.id));
    });

    test('rejects a presentation payload with no kind or session', () {
      expect(NotificationPayload.fromPresentationPayload(<String, dynamic>{'kind': 'completed'}), isNull);
      expect(
        NotificationPayload.fromPresentationPayload(<String, dynamic>{'session_id': 's1'}),
        isNull,
      );
      expect(NotificationPayload.fromPresentationPayload('not a map'), isNull);
    });
  });
}
