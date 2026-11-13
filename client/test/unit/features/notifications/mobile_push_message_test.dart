import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';

Map<String, dynamic> _envelope({
  String eventId = 'evt-1',
  String sessionId = 's1',
  String requestId = 'r1',
  String kind = 'permission_request',
  String? expiresAt,
}) {
  return <String, dynamic>{
    'event': 'notification',
    'event_id': eventId,
    'session_id': sessionId,
    'request_id': requestId,
    'payload': <String, dynamic>{
      'kind': kind,
      'urgency': 'high',
      'title': 'Fix the login redirect',
      'body': 'Approve the command?',
      'deep_link': <String, dynamic>{'session_id': sessionId, 'request_id': requestId},
      if (expiresAt != null) 'expires_at': expiresAt,
      'actions': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'allow_once'},
        <String, dynamic>{'id': 'deny'},
      ],
    },
  };
}

void main() {
  group('MobilePushMessage', () {
    test('rebuilds the canonical payload from a provider data map', () {
      final message = MobilePushMessage.fromData(<String, Object?>{
        MobilePushMessage.envelopeKey: jsonEncode(_envelope()),
      });

      final payload = message.payload;
      expect(payload, isNotNull);
      expect(payload!.eventId, 'evt-1');
      expect(payload.kind, NotificationKind.permissionRequest);
      expect(payload.sessionId, 's1');
      expect(payload.requestId, 'r1');
      expect(payload.title, 'Fix the login redirect');
      expect(payload.body, 'Approve the command?');
      expect(payload.actions.map((action) => action.id), containsAll(<String>['allow_once', 'deny']));
    });

    test('reads the flat fallback so a flattening provider still delivers', () {
      final message = MobilePushMessage.fromData(<String, Object?>{
        'kind': 'permission_request',
        'session_id': 's2',
        'request_id': 'r9',
        'title': 'Session title',
        'body': 'Approve?',
        'actions': 'allow_once,deny',
      });

      final payload = message.payload;
      expect(payload, isNotNull);
      expect(payload!.sessionId, 's2');
      expect(payload.requestId, 'r9');
      expect(payload.actions.length, 2);
      // The canonical event it rebuilds is one the socket parser accepts.
      expect(message.canonicalEvent?['event'], 'notification');
    });

    test('drops a message with no kind or no session identity', () {
      expect(MobilePushMessage.fromData(<String, Object?>{'kind': 'permission_request'}).payload, isNull);
      expect(MobilePushMessage.fromData(<String, Object?>{'session_id': 's1'}).payload, isNull);
      expect(MobilePushMessage.fromData(<String, Object?>{'kind': 'unknown_kind', 'session_id': 's'}).payload, isNull);
      expect(MobilePushMessage.decode('not json'), isNull);
      expect(MobilePushMessage.decode(7), isNull);
    });

    test('reads the interaction action and treats an expiry as stale', () {
      final expired = MobilePushMessage.fromData(<String, Object?>{
        MobilePushMessage.envelopeKey: jsonEncode(
          _envelope(expiresAt: '2026-01-01T11:00:00.000Z'),
        ),
        MobilePushMessage.actionKey: 'allow_once',
      });

      expect(expired.actionId, 'allow_once');
      expect(expired.isInteraction, isTrue);
      expect(expired.isExpiredAt(DateTime.utc(2026, 1, 1, 12)), isTrue);

      final live = MobilePushMessage.fromData(<String, Object?>{
        MobilePushMessage.envelopeKey: jsonEncode(_envelope(expiresAt: '2026-01-01T13:00:00.000Z')),
      });
      expect(live.isExpiredAt(DateTime.utc(2026, 1, 1, 12)), isFalse);
      expect(live.isInteraction, isFalse);
    });

    test('a message without an envelope never parses into a guessed kind', () {
      final message = MobilePushMessage.fromData(<String, Object?>{'unrelated': 'value'});
      expect(message.payload, isNull);
      expect(message.eventId, isNull);
    });
  });
}
