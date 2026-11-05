import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_navigation.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Issue 339 review 2: widget keys must never be derived from a localized label.
/// A locale switch renamed `nav_tile_general` to `nav_tile_عام`, breaking every
/// key-driven test and automation flow.
void main() {
  testWidgets('a navigation tile key is its stable id in every locale', (
    tester,
  ) async {
    for (final locale in ['en', 'ar']) {
      final l10n = await AppLocalizations.delegate.load(Locale(locale));
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: NavigationTile(
              icon: Icons.tune,
              label: l10n.general,
              navKey: 'general',
              selected: false,
              onTap: () {},
            ),
          ),
        ),
      );

      // The key is the stable id in every locale; the visible label is the
      // localized one.
      expect(find.byKey(const Key('nav_tile_general')), findsOneWidget);
      expect(find.text(l10n.general), findsOneWidget);
    }
  });

  test('the settings navigation source never derives a key from a label', () {
    final source = File(
      'lib/features/settings/presentation/widgets/settings_navigation.dart',
    ).readAsStringSync();

    // The fallback that produced `nav_tile_عام` must not come back.
    expect(source.contains('label.toLowerCase()'), isFalse);
    expect(source.contains(r'nav_tile_$navKey'), isTrue);
    // The ids that automation relies on are literals, never translated labels.
    for (final id in [
      "'profile'",
      "'general'",
      "'sessions_devices'",
      "'privacy_security'",
    ]) {
      expect(source.contains('navKey: $id'), isTrue, reason: id);
    }
  });
}
