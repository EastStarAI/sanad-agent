import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_action_labels.dart';

const Map<NotificationActionIntent, String> _localized = <NotificationActionIntent, String>{
  NotificationActionIntent.allowOnce: 'Ouvrir une fois',
  NotificationActionIntent.allowSession: 'Ouvrir pour la session',
  NotificationActionIntent.deny: 'Refuser',
  NotificationActionIntent.open: 'Ouvrir',
};

void main() {
  group('action labels', () {
    test('the localized label the adapter receives always wins', () {
      for (final intent in NotificationActionIntent.values) {
        expect(
          NotificationActionLabels.resolve(_localized, intent),
          _localized[intent],
          reason: '${intent.name} must use the localized copy, not the fallback',
        );
      }
      expect(NotificationActionLabels.linuxDefaultActionName(_localized), 'Ouvrir');
    });

    test('a blank entry falls back to English copy, never to a wire token', () {
      final labels = <NotificationActionIntent, String>{
        NotificationActionIntent.allowOnce: '  ',
        NotificationActionIntent.deny: '',
      };

      expect(NotificationActionLabels.resolve(labels, NotificationActionIntent.allowOnce), 'Allow once');
      expect(NotificationActionLabels.resolve(labels, NotificationActionIntent.deny), 'Deny');
      // A raw intent name is protocol vocabulary and must never be a button.
      for (final intent in NotificationActionIntent.values) {
        final label = NotificationActionLabels.resolve(const {}, intent);
        expect(label, isNot(intent.name));
        expect(label.trim(), isNotEmpty);
      }
    });

    test('an empty map still produces the English default action name', () {
      expect(NotificationActionLabels.linuxDefaultActionName(const {}), 'Open');
      expect(
        NotificationActionLabels.linuxDefaultActionName(const {}),
        NotificationActionLabels.english[NotificationActionIntent.open],
        reason: 'Linux fixes this copy at initialization, so it must not be a literal',
      );
    });

    test('the English fallback stays identical to the authored source locale', () {
      final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
      const keys = <NotificationActionIntent, String>{
        NotificationActionIntent.allowOnce: 'notificationActionAllowOnce',
        NotificationActionIntent.allowSession: 'notificationActionAllowSession',
        NotificationActionIntent.deny: 'notificationActionDeny',
        NotificationActionIntent.open: 'notificationActionOpen',
      };

      for (final entry in keys.entries) {
        expect(
          NotificationActionLabels.english[entry.key],
          arb[entry.value],
          reason: '${entry.key.name} drifted from ${entry.value} in app_en.arb',
        );
      }
    });
  });
}
