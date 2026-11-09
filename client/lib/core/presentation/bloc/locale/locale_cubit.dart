import 'dart:ui';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supported UI locales, in priority order. The first entry is the fallback.
const List<Locale> kSupportedLocales = [Locale('en'), Locale('ar')];

class LocaleCubit extends Cubit<Locale> {
  static const String _localeKey = 'app_locale';

  LocaleCubit(Locale initialState) : super(initialState);

  Future<void> updateLocale(Locale locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, locale.languageCode);
    emit(locale);
  }

  /// Resolves the UI locale: the saved choice wins, then the system language,
  /// then the first supported locale.
  ///
  /// Following the system matters for the small hints the app shows (tooltips
  /// included): a user running macOS in Arabic should not get English hints
  /// before ever opening the language menu.
  static Future<Locale> getSavedLocale() async {
    final prefs = await SharedPreferences.getInstance();
    return resolveInitial(
      systemLocale: PlatformDispatcher.instance.locale,
      savedCode: prefs.getString(_localeKey),
    );
  }

  /// Pure form of [getSavedLocale], so the fallback order is testable.
  static Locale resolveInitial({
    required Locale systemLocale,
    required String? savedCode,
  }) {
    return _match(savedCode) ?? _match(systemLocale.languageCode) ?? kSupportedLocales.first;
  }

  static Locale? _match(String? code) {
    if (code == null) return null;
    for (final locale in kSupportedLocales) {
      if (locale.languageCode == code) return locale;
    }
    return null;
  }
}
