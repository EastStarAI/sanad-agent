// Plan 174 — Agent/Client notification copy parity.
//
// Notification copy lives in two codebases: the Agent renders it for the
// payload, and the Client renders the same sentences in its own surfaces. This
// test is the only thing that stops the two from drifting. It runs against the
// Client's authored locale files, so it fails the moment either side adds,
// renames, or re-wordplaces a notification key alone.
//
// Keys that the Client has not authored yet are recorded in
// [_expectedMissingClientKeys]. Adding one on the Client side makes that list
// stale and fails this test until the record here is updated, which is exactly
// the review signal plan 174 wants.

import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/interfaces/notifications/notification_copy.dart';
import 'package:sanad_agent/interfaces/notifications/notification_kind.dart';
import 'package:test/test.dart';

/// Notification keys the Agent depends on that the Client localization does
/// not author yet.
///
/// `174a` freezes the Agent side of the vocabulary; task `174f` authors the
/// Client strings. Every entry leaving this set must be matched by the same
/// key and the same placeholders in `client/lib/l10n/app_en.arb`, and the list
/// must shrink to empty when `174f` lands.
const Set<String> _expectedMissingClientKeys = <String>{};

/// Notification copy keys the Client owns for kinds the Agent never copies.
///
/// `authRequired` and `connectionLost` are decided by the Client alone, so the
/// Agent carries no template for them and the parity check must not demand one.
/// Every other Client key that starts with `notification` is shared vocabulary.
const Set<String> _clientOnlyKeys = <String>{
  'notificationAuthRequiredTitle',
  'notificationAuthRequiredBody',
  'notificationConnectionLostTitle',
  'notificationConnectionLostBody',
};

final RegExp _placeholderPattern = RegExp(r'\{([a-zA-Z][a-zA-Z0-9]*)\}');

void main() {
  late Map<String, dynamic> english;
  late Map<String, dynamic> arabic;

  setUpAll(() {
    english = _readArb('client/lib/l10n/app_en.arb');
    arabic = _readArb('client/lib/l10n/app_ar.arb');
  });

  group('client localization parity', () {
    test('every Agent copy key is authored on the Client or recorded', () {
      final agentKeys = NotificationCopy.clientKeys;
      final clientKeys = _messageKeys(english);
      final missing = agentKeys.difference(clientKeys);

      expect(
        missing,
        _expectedMissingClientKeys,
        reason:
            'The Agent and the Client disagree about the notification key '
            'set. Author the Client key, or update the recorded expectation in '
            'this test — never both silently.',
      );
    });

    test('the Client authors no notification key the Agent does not know', () {
      final clientNotificationKeys = _messageKeys(english)
          .where((key) => key.startsWith('notification'))
          .where((key) => !key.startsWith('notifications'))
          .toSet();

      expect(
        clientNotificationKeys
            .difference(NotificationCopy.clientKeys)
            .difference(_clientOnlyKeys),
        isEmpty,
        reason:
            'A Client notification key has no Agent counterpart, so the '
            'payload could never carry that label.',
      );
    });

    test('shared keys keep the same placeholders on both sides', () {
      final agentPlaceholders = _agentPlaceholders();
      final shared = NotificationCopy.clientKeys.difference(
        _expectedMissingClientKeys,
      );

      for (final key in shared) {
        final clientValue = english[key];
        expect(
          clientValue,
          isA<String>(),
          reason: 'The recorded shared key $key is missing on the Client.',
        );
        expect(
          _placeholdersIn(clientValue! as String),
          agentPlaceholders[key],
          reason: 'The placeholders of $key differ between the two sides.',
        );
      }
    });

    test('the Arabic table covers every Agent key with Arabic text', () {
      final arabicKeys = _messageKeys(arabic);
      expect(
        NotificationCopy.clientKeys.difference(arabicKeys),
        _expectedMissingClientKeys,
      );
      for (final key in NotificationCopy.clientKeys) {
        final value = arabic[key];
        if (value == null) continue;
        expect(
          _containsArabicScript(value as String),
          isTrue,
          reason: 'The Arabic locale value of $key is not Arabic.',
        );
      }
    });
  });

  group('Agent copy table', () {
    test('every Agent kind has an English and an Arabic template', () {
      for (final kind in NotificationKind.agentKinds) {
        final template = NotificationCopy.templateFor(kind);
        expect(template, isNotNull, reason: 'No copy for ${kind.value}');
        for (final locale in NotificationLocale.values) {
          expect(
            template!.titles[locale],
            isNotEmpty,
            reason: '${kind.value} has no ${locale.code} title',
          );
          expect(
            template.bodies[locale],
            isNotEmpty,
            reason: '${kind.value} has no ${locale.code} body',
          );
        }
      }
    });

    test('Client-owned kinds carry no Agent copy', () {
      expect(
        NotificationCopy.templateFor(NotificationKind.connectionLost),
        isNull,
      );
      expect(
        NotificationCopy.templateFor(NotificationKind.authRequired),
        isNull,
      );
    });

    test('every kind offers actions that exist in the label table', () {
      for (final kind in NotificationKind.agentKinds) {
        final template = NotificationCopy.templateFor(kind)!;
        expect(template.actionIds, isNotEmpty);
        for (final actionId in template.actionIds) {
          final action = NotificationCopy.actionFor(actionId);
          expect(action, isNotNull, reason: 'No label for $actionId');
          for (final locale in NotificationLocale.values) {
            expect(action!.labels[locale], isNotEmpty);
          }
        }
      }
    });

    test('every authored value differs between English and Arabic', () {
      for (final kind in NotificationKind.agentKinds) {
        final template = NotificationCopy.templateFor(kind)!;
        if (kind != NotificationKind.userQuestion) {
          expect(
            template.titles[NotificationLocale.english],
            isNot(template.titles[NotificationLocale.arabic]),
          );
        }
        expect(
          _containsArabicScript(template.titles[NotificationLocale.arabic]!),
          isTrue,
        );
      }
      for (final action in notificationActionCopy) {
        expect(
          _containsArabicScript(action.labels[NotificationLocale.arabic]!),
          isTrue,
          reason: '${action.id} has no Arabic label',
        );
      }
    });

    test('no template translates the session title', () {
      for (final kind in NotificationKind.agentKinds) {
        for (final body in NotificationCopy.templateFor(kind)!.bodies.values) {
          expect(body, isNot(contains('sessionTitle')));
          expect(body, isNot(contains('{title}')));
        }
      }
    });
  });

  group('locale resolution', () {
    test('a supported tag resolves and anything else falls back', () {
      expect(NotificationLocale.tryParse('ar'), NotificationLocale.arabic);
      expect(NotificationLocale.tryParse('ar-SA'), NotificationLocale.arabic);
      expect(NotificationLocale.tryParse('ar_SA'), NotificationLocale.arabic);
      expect(NotificationLocale.tryParse('EN'), NotificationLocale.english);
      expect(NotificationLocale.tryParse('fr'), isNull);
      expect(NotificationLocale.tryParse(null), isNull);
      expect(NotificationLocale.resolve('fr'), NotificationLocale.fallback);
    });
  });
}

Map<String, dynamic> _readArb(String relativePath) {
  final file = _locate(relativePath);
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// Finds a repository-relative file from either the package root or the
/// repository root, so the suite does not depend on the caller's directory.
File _locate(String relativePath) {
  var directory = Directory.current;
  for (var depth = 0; depth < 8; depth += 1) {
    final candidate = File('${directory.path}/$relativePath');
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  fail(
    'Could not find $relativePath above ${Directory.current.path}. '
    'Run this suite from the agent package against a full checkout.',
  );
}

Set<String> _messageKeys(Map<String, dynamic> arb) => {
  for (final key in arb.keys)
    if (!key.startsWith('@')) key,
};

Map<String, Set<String>> _agentPlaceholders() {
  final placeholders = <String, Set<String>>{};
  for (final kind in NotificationKind.agentKinds) {
    final template = NotificationCopy.templateFor(kind)!;
    placeholders[template.titleKey] = _placeholdersIn(
      template.titles[NotificationLocale.english]!,
    );
    placeholders[template.bodyKey] = _placeholdersIn(
      template.bodies[NotificationLocale.english]!,
    );
  }
  for (final action in notificationActionCopy) {
    placeholders[action.clientKey] = _placeholdersIn(
      action.labels[NotificationLocale.english]!,
    );
  }
  return placeholders;
}

Set<String> _placeholdersIn(String value) => {
  for (final match in _placeholderPattern.allMatches(value)) match.group(1)!,
};

bool _containsArabicScript(String value) =>
    RegExp(r'[\u0600-\u06FF]').hasMatch(value);
