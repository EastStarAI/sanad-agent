import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'appearance_state.dart';

class AppearanceCubit extends Cubit<AppearanceState> {
  static const String _themeStyleKey = 'appearance_theme_style';
  static const String _primaryColorKey = 'appearance_primary_color';
  static const String _fontFamilyKey = 'appearance_font_family';
  static const String _fontSizeScaleKey = 'appearance_font_size_scale';
  static const String _backgroundOptionKey = 'appearance_background_option';

  AppearanceCubit(super.initialState);

  Future<void> updateThemeStyle(AppThemeStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeStyleKey, style.id);
    await prefs.setInt('theme_mode', style.themeMode.index);
    emit(state.copyWith(themeStyle: style));
  }

  Future<void> updatePrimaryColor(AppPrimaryColor color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_primaryColorKey, color.id);
    emit(state.copyWith(primaryColor: color));
  }

  Future<void> updateFontFamily(AppFontFamily family) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontFamilyKey, family.id);
    emit(state.copyWith(fontFamily: family));
  }

  Future<void> updateFontSizeScale(AppFontSizeScale scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontSizeScaleKey, scale.id);
    emit(state.copyWith(fontSizeScale: scale));
  }

  Future<void> updateBackgroundOption(AppBackgroundOption option) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backgroundOptionKey, option.id);
    emit(state.copyWith(backgroundOption: option));
  }

  static Future<AppearanceState> getSavedAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    final themeStyleId = prefs.getString(_themeStyleKey);
    final primaryColorId = prefs.getString(_primaryColorKey);
    final fontFamilyId = prefs.getString(_fontFamilyKey);
    final fontSizeScaleId = prefs.getString(_fontSizeScaleKey);
    final backgroundOptionId = prefs.getString(_backgroundOptionKey);

    AppThemeStyle style;
    if (themeStyleId != null) {
      style = AppThemeStyle.fromId(themeStyleId);
    } else {
      final legacyThemeIndex = prefs.getInt('theme_mode');
      if (legacyThemeIndex == 1) {
        style = AppThemeStyle.light;
      } else {
        style = AppThemeStyle.dark;
      }
    }

    return AppearanceState(
      themeStyle: style,
      primaryColor: AppPrimaryColor.fromId(primaryColorId),
      fontFamily: AppFontFamily.fromId(fontFamilyId),
      fontSizeScale: AppFontSizeScale.fromId(fontSizeScaleId),
      backgroundOption: AppBackgroundOption.fromId(backgroundOptionId),
    );
  }
}
