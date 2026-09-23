import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('locale', () {
    test('unsupported stored locale silently falls back to en', () async {
      final locale = await LocaleCubit.getSavedLocale();
      expect(locale.languageCode, 'en');
    });

    test('supported locales contain en and ar', () {
      expect(
        kSupportedLocales.map((l) => l.languageCode),
        containsAll(['en', 'ar']),
      );
    });
  });

  group('arb parity', () {
    test('ar has exactly the same translation keys as en', () {
      final en = _keys('lib/l10n/app_en.arb');
      final ar = _keys('lib/l10n/app_ar.arb');
      expect(ar, en);
    });
  });
}

/// Reads key lists from checked-in fixtures so the parity test does not
/// depend on l10n codegen output paths.
Set<String> _keys(String assetPath) {
  final file = File(assetPath);
  if (!file.existsSync()) {
    fail('Missing parity fixture: $assetPath');
  }
  final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return body.keys.where((k) => !k.startsWith('@')).toSet();
}
