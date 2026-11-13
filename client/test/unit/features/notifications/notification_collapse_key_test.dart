import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_collapse_key.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';

void main() {
  group('NotificationCollapseKey', () {
    test('derives one key per session and kind', () {
      final first = NotificationCollapseKey.forAsk(
        sessionId: 's1',
        kind: NotificationKind.permissionRequest,
      );
      final again = NotificationCollapseKey.forAsk(
        sessionId: 's1',
        kind: NotificationKind.permissionRequest,
      );
      final otherSession = NotificationCollapseKey.forAsk(
        sessionId: 's2',
        kind: NotificationKind.permissionRequest,
      );
      final otherKind = NotificationCollapseKey.forAsk(
        sessionId: 's1',
        kind: NotificationKind.userQuestion,
      );

      expect(first, again);
      expect(first, isNot(otherSession));
      expect(first, isNot(otherKind));
    });

    test('separator keeps a session id from forging another kind', () {
      // A naive "session:kind" join would let these two pairs collide.
      final a = NotificationCollapseKey.forAsk(
        sessionId: 's1:permission_request',
        kind: NotificationKind.userQuestion,
      );
      final b = NotificationCollapseKey.forAsk(
        sessionId: 's1',
        kind: NotificationKind.permissionRequest,
      );

      expect(a, isNot(b));
    });

    test('accepts only an Agent key that matches the canonical derivation', () {
      final canonical = NotificationCollapseKey.forAsk(
        sessionId: 's1',
        kind: NotificationKind.permissionRequest,
      );

      expect(
        NotificationCollapseKey.agreesWith(
          candidate: canonical,
          sessionId: 's1',
          kind: NotificationKind.permissionRequest,
        ),
        isTrue,
      );
      expect(
        NotificationCollapseKey.agreesWith(
          candidate: 'something-else',
          sessionId: 's1',
          kind: NotificationKind.permissionRequest,
        ),
        isFalse,
      );
      expect(
        NotificationCollapseKey.agreesWith(
          candidate: null,
          sessionId: 's1',
          kind: NotificationKind.permissionRequest,
        ),
        isFalse,
      );
    });

    test('notification id is a stable positive identifier', () {
      // Pinned values: changing the derivation would silently stop replacing a
      // banner that a previous Client version presented with the same key.
      expect(
        NotificationCollapseKey.notificationId(
          NotificationCollapseKey.forAsk(
            sessionId: 's1',
            kind: NotificationKind.permissionRequest,
          ),
        ),
        37406375,
      );
      expect(
        NotificationCollapseKey.notificationId(
          NotificationCollapseKey.forAsk(
            sessionId: 's2',
            kind: NotificationKind.permissionRequest,
          ),
        ),
        2061475272,
      );
    });

    test('notification ids stay inside the positive 31-bit range', () {
      for (var index = 0; index < 500; index++) {
        final id = NotificationCollapseKey.notificationId('ask-$index');
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThanOrEqualTo(0x7FFFFFFF));
      }
    });
  });
}
