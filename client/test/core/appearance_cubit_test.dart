import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppearanceCubit', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('initializes with default values', () {
      final cubit = AppearanceCubit(const AppearanceState());
      expect(cubit.state.themeStyle, AppThemeStyle.dark);
      expect(cubit.state.primaryColor, AppPrimaryColor.blue);
      expect(cubit.state.fontFamily, AppFontFamily.system);
      expect(cubit.state.fontSizeScale, AppFontSizeScale.normal);
      expect(cubit.state.backgroundOption, AppBackgroundOption.defaultTheme);
    });

    test('updates theme style and persists', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.updateThemeStyle(AppThemeStyle.midnight);

      expect(cubit.state.themeStyle, AppThemeStyle.midnight);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance_theme_style'), 'midnight');
      expect(prefs.getInt('theme_mode'), 2); // ThemeMode.dark.index
    });

    test('updates primary color and persists', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.updatePrimaryColor(AppPrimaryColor.purple);

      expect(cubit.state.primaryColor, AppPrimaryColor.purple);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance_primary_color'), 'purple');
    });

    test('updates font family and persists', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.updateFontFamily(AppFontFamily.cairo);

      expect(cubit.state.fontFamily, AppFontFamily.cairo);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance_font_family'), 'cairo');
    });

    test('updates font size scale and persists', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.updateFontSizeScale(AppFontSizeScale.large);

      expect(cubit.state.fontSizeScale, AppFontSizeScale.large);
      expect(cubit.state.fontSizeScale.factor, 1.15);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance_font_size_scale'), 'large');
    });

    test('updates background option and persists', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.updateBackgroundOption(AppBackgroundOption.natureForest);

      expect(cubit.state.backgroundOption, AppBackgroundOption.natureForest);
      expect(cubit.state.backgroundOption.isWallpaper, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appearance_background_option'), 'natureForest');
    });

    test('getSavedAppearance loads stored values', () async {
      SharedPreferences.setMockInitialValues({
        'appearance_theme_style': 'sepia',
        'appearance_primary_color': 'blue',
        'appearance_font_family': 'cairo',
        'appearance_font_size_scale': 'extraLarge',
        'appearance_background_option': 'natureMountain',
      });

      final loaded = await AppearanceCubit.getSavedAppearance();
      expect(loaded.themeStyle, AppThemeStyle.sepia);
      expect(loaded.primaryColor, AppPrimaryColor.blue);
      expect(loaded.fontFamily, AppFontFamily.cairo);
      expect(loaded.fontSizeScale, AppFontSizeScale.extraLarge);
      expect(loaded.backgroundOption, AppBackgroundOption.natureMountain);
    });

    test('getSavedAppearance falls back to legacy theme_mode when unset', () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 1, // Light
      });

      final loaded = await AppearanceCubit.getSavedAppearance();
      expect(loaded.themeStyle, AppThemeStyle.light);
      expect(loaded.fontFamily, AppFontFamily.system);
    });
  });
}
