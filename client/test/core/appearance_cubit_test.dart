import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testAgent1 = DeviceConfig(
    id: 'device-1',
    name: 'MacBook Local',
    isOnline: true,
  );

  final testAgent2 = DeviceConfig(
    id: 'device-2',
    name: 'Cloud Ubuntu',
    isOnline: true,
  );

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

    test('getSavedAppearance loads last active appearance on cold start', () async {
      SharedPreferences.setMockInitialValues({
        'appearance_last_active_theme_style': 'sepia',
        'appearance_last_active_primary_color': 'blue',
        'appearance_last_active_font_family': 'cairo',
        'appearance_last_active_font_size_scale': 'extraLarge',
        'appearance_last_active_background_option': 'natureMountain',
      });

      final loaded = await AppearanceCubit.getSavedAppearance();
      expect(loaded.themeStyle, AppThemeStyle.sepia);
      expect(loaded.primaryColor, AppPrimaryColor.blue);
      expect(loaded.fontFamily, AppFontFamily.cairo);
      expect(loaded.fontSizeScale, AppFontSizeScale.extraLarge);
      expect(loaded.backgroundOption, AppBackgroundOption.natureMountain);
    });

    test('getSavedAppearance loads active agent appearance on cold start when available', () async {
      SharedPreferences.setMockInitialValues({
        'active_agent_id': 'device-1',
        'appearance_theme_style_device-1': 'sepia',
        'appearance_primary_color_device-1': 'orange',
      });

      final loaded = await AppearanceCubit.getSavedAppearance();
      expect(loaded.themeStyle, AppThemeStyle.sepia);
      expect(loaded.primaryColor, AppPrimaryColor.orange);
    });

    test('getSavedAppearance returns default appearance when nothing is saved', () async {
      SharedPreferences.setMockInitialValues({});

      final loaded = await AppearanceCubit.getSavedAppearance();
      expect(loaded.themeStyle, AppThemeStyle.dark);
      expect(loaded.primaryColor, AppPrimaryColor.blue);
      expect(loaded.fontFamily, AppFontFamily.system);
    });

    test('multi-agent switching maintains independent visual identities per device', () async {
      final cubit = AppearanceCubit(const AppearanceState());

      // Device 1: set to Sepia and Orange
      await cubit.setActiveAgent(testAgent1);
      await cubit.updateThemeStyle(AppThemeStyle.sepia);
      await cubit.updatePrimaryColor(AppPrimaryColor.orange);
      expect(cubit.state.themeStyle, AppThemeStyle.sepia);
      expect(cubit.state.primaryColor, AppPrimaryColor.orange);

      // Switch to Device 2: with remote appearance (Midnight + Teal)
      await cubit.setActiveAgent(testAgent2, remoteAppearance: {
        'theme_style': 'midnight',
        'primary_color': 'teal',
        'font_family': 'cairo',
      });
      expect(cubit.state.themeStyle, AppThemeStyle.midnight);
      expect(cubit.state.primaryColor, AppPrimaryColor.teal);
      expect(cubit.state.fontFamily, AppFontFamily.cairo);

      // Switch back to Device 1: should restore Device 1 settings from local cache
      await cubit.setActiveAgent(testAgent1);
      expect(cubit.state.themeStyle, AppThemeStyle.sepia);
      expect(cubit.state.primaryColor, AppPrimaryColor.orange);
    });

    test('switching to unconfigured/legacy device falls back to initial default appearance', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      final legacyAgent = DeviceConfig(id: 'legacy-agent', name: 'Old Agent', isOnline: true);

      // Device 1: customize to Sepia + Orange
      await cubit.setActiveAgent(testAgent1);
      await cubit.updateThemeStyle(AppThemeStyle.sepia);
      await cubit.updatePrimaryColor(AppPrimaryColor.orange);
      expect(cubit.state.themeStyle, AppThemeStyle.sepia);

      // Switch to legacy device with no saved preferences and no remote appearance
      await cubit.setActiveAgent(legacyAgent);
      expect(cubit.state.themeStyle, AppThemeStyle.dark);
      expect(cubit.state.primaryColor, AppPrimaryColor.blue);
      expect(cubit.state.fontFamily, AppFontFamily.system);
      expect(cubit.state.fontSizeScale, AppFontSizeScale.normal);
      expect(cubit.state.backgroundOption, AppBackgroundOption.defaultTheme);

      // Switch back to Device 1: restores customized appearance
      await cubit.setActiveAgent(testAgent1);
      expect(cubit.state.themeStyle, AppThemeStyle.sepia);
      expect(cubit.state.primaryColor, AppPrimaryColor.orange);
    });

    test('getSavedAppearance for deviceId does not bleed last active keys', () async {
      SharedPreferences.setMockInitialValues({
        'appearance_last_active_theme_style': 'sepia',
        'appearance_last_active_primary_color': 'purple',
      });

      // Cold start without deviceId reads last active keys
      final globalAppearance = await AppearanceCubit.getSavedAppearance();
      expect(globalAppearance.themeStyle, AppThemeStyle.sepia);
      expect(globalAppearance.primaryColor, AppPrimaryColor.purple);

      // When querying for an unconfigured device, strictly return defaults instead of last active keys
      final deviceAppearance = await AppearanceCubit.getSavedAppearance(deviceId: 'unconfigured-device');
      expect(deviceAppearance.themeStyle, AppThemeStyle.dark);
      expect(deviceAppearance.primaryColor, AppPrimaryColor.blue);
    });

    test('onCapabilitiesReceived updates active device appearance', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.setActiveAgent(testAgent1);

      await cubit.onCapabilitiesReceived('device-1', {
        'theme_style': 'midnight',
        'primary_color': 'cyan',
      });

      expect(cubit.state.themeStyle, AppThemeStyle.midnight);
      expect(cubit.state.primaryColor, AppPrimaryColor.cyan);
    });

    test('importAppearance applies valid JSON map correctly', () async {
      final cubit = AppearanceCubit(const AppearanceState());
      await cubit.importAppearance({
        'theme_style': 'sepia',
        'primary_color': 'rose',
        'font_family': 'inter',
        'font_size': 'large',
        'background_option': 'natureLake',
      });

      expect(cubit.state.themeStyle, AppThemeStyle.sepia);
      expect(cubit.state.primaryColor, AppPrimaryColor.rose);
      expect(cubit.state.fontFamily, AppFontFamily.inter);
      expect(cubit.state.fontSizeScale, AppFontSizeScale.large);
      expect(cubit.state.backgroundOption, AppBackgroundOption.natureLake);

      // Verify toJson roundtrip
      final json = cubit.state.toJson();
      expect(json['theme_style'], 'sepia');
      expect(json['primary_color'], 'rose');
      expect(json['font_family'], 'inter');
      expect(json['font_size'], 'large');
      expect(json['background_option'], 'natureLake');
    });
  });
}
