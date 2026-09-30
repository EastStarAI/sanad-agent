import 'dart:ui';

import 'package:flutter/material.dart';
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

  /// Loads the persisted locale, falling back to the first supported locale.
  /// An unknown stored value silently resets to the fallback.
  static Future<Locale> getSavedLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_localeKey);
    if (code != null) {
      for (final locale in kSupportedLocales) {
        if (locale.languageCode == code) {
          return locale;
        }
      }
    }
    return kSupportedLocales.first;
  }
}
