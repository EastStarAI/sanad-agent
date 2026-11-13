// Plan 174f — the Agent's read of one device's notification declaration.
//
// The declaration is the only path a per-device preference takes into the
// Agent. These tests pin the parser's two safety properties: it never lets a
// declaration raise a notification above the product default, and it never
// invents meaning for a token this build does not know.

import 'package:sanad_agent/interfaces/notifications/notification_kind.dart';
import 'package:sanad_agent/interfaces/notifications/notification_preferences.dart';
import 'package:test/test.dart';

void main() {
  group('declaration parsing', () {
    test('an absent or unreadable declaration is not a declaration', () {
      expect(ClientNotificationPreferences.tryParse(null), isNull);
      expect(ClientNotificationPreferences.tryParse('muted'), isNull);
      expect(ClientNotificationPreferences.tryParse(<Object>[]), isNull);
    });

    test('an empty but well-formed declaration is a reset to the product default', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'enabled': true,
        'kinds': <String, dynamic>{},
      });

      expect(parsed, isNotNull);
      expect(parsed!.isProductDefault, isTrue);
      expect(parsed.allowsKind(NotificationKind.permissionRequest), isTrue);
    });

    test('a muted kind and a lowered kind are read as written', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'enabled': true,
        'kinds': <String, dynamic>{'completed': 'off', 'failed': 'normal'},
      })!;

      expect(parsed.allowsKind(NotificationKind.completed), isFalse);
      expect(parsed.allowsKind(NotificationKind.failed), isTrue);
      expect(parsed.ceilingFor(NotificationKind.failed), NotificationUrgency.normal);
      expect(parsed.isProductDefault, isFalse);
    });

    test('the global switch mutes every kind', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'enabled': false,
      })!;

      for (final kind in NotificationKind.agentKinds) {
        expect(parsed.allowsKind(kind), isFalse);
      }
    });

    test('a declaration cannot raise a kind above the product default', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'kinds': <String, dynamic>{'completed': 'high', 'failed': 'critical'},
      })!;

      expect(parsed.ceilingFor(NotificationKind.completed), NotificationUrgency.high);
      expect(parsed.urgencyCeilings.containsKey('completed'), isFalse);
      expect(parsed.urgencyCeilings.containsKey('failed'), isFalse);
    });

    test('an unknown kind or urgency token is ignored, not guessed', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'kinds': <String, dynamic>{
          'future_kind': 'low',
          'not a token': 'low',
          'completed': 'quiet_please',
          'blocked': 42,
        },
      })!;

      expect(parsed.mutedKinds, isEmpty);
      // A kind token this build does not know is kept as a typed token rather
      // than discarded, because a newer Client may name a newer kind. What is
      // never invented is an urgency or a mute from an unreadable value.
      expect(parsed.ceilingFor(NotificationKind('future_kind')), NotificationUrgency.low);
      expect(parsed.urgencyCeilings.containsKey('completed'), isFalse);
      expect(parsed.urgencyCeilings.containsKey('blocked'), isFalse);
      expect(parsed.urgencyCeilings.containsKey('not a token'), isFalse);
    });

    test('a boolean false is accepted as the muted token', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'kinds': <String, dynamic>{'blocked': false},
      })!;

      expect(parsed.allowsKind(NotificationKind.blocked), isFalse);
    });

    test('the round trip keeps the declaration the Client wrote', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'enabled': true,
        'kinds': <String, dynamic>{'completed': 'off', 'failed': 'normal'},
      })!;

      expect(parsed.toJson(), <String, dynamic>{
        'enabled': true,
        'kinds': <String, String>{'completed': 'off', 'failed': 'normal'},
      });
    });
  });

  group('urgency application', () {
    test('the device ceiling lowers the Agent decision and never raises it', () {
      final parsed = ClientNotificationPreferences.tryParse(<String, dynamic>{
        'kinds': <String, dynamic>{'failed': 'normal'},
      })!;

      for (final fromAgent in NotificationUrgency.values) {
        final actual = parsed.urgencyFor(NotificationKind.failed, fromAgent);
        expect(
          actual.index,
          greaterThanOrEqualTo(NotificationUrgency.normal.index),
          reason: 'the Agent enum runs loudest to quietest, so normal is the floor',
        );
      }
    });

    test('an untouched kind keeps the Agent decision', () {
      const parsed = ClientNotificationPreferences.productDefault;

      expect(
        parsed.urgencyFor(NotificationKind.completed, NotificationUrgency.high),
        NotificationUrgency.high,
      );
      expect(
        parsed.urgencyFor(NotificationKind.completed, NotificationUrgency.low),
        NotificationUrgency.low,
      );
    });
  });
}
