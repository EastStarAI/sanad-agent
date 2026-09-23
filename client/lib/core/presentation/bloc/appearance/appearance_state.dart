import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

enum AppThemeStyle {
  light,
  dark,
  midnight,
  sepia;

  String get id => name;

  static AppThemeStyle fromId(String? id) {
    return AppThemeStyle.values.firstWhere(
      (e) => e.name == id,
      orElse: () => AppThemeStyle.dark,
    );
  }

  ThemeMode get themeMode => switch (this) {
    AppThemeStyle.light || AppThemeStyle.sepia => ThemeMode.light,
    AppThemeStyle.dark || AppThemeStyle.midnight => ThemeMode.dark,
  };
}

enum AppFontFamily {
  system('System Default'),
  cairo('Cairo'),
  inter('Inter'),
  roboto('Roboto');

  final String displayName;
  const AppFontFamily(this.displayName);

  String get id => name;

  static AppFontFamily fromId(String? id) {
    return AppFontFamily.values.firstWhere(
      (e) => e.name == id,
      orElse: () => AppFontFamily.system,
    );
  }
}

enum AppFontSizeScale {
  small(0.85, 'Small'),
  normal(1.0, 'Default'),
  large(1.15, 'Large'),
  extraLarge(1.30, 'Extra Large');

  final double factor;
  final String displayName;
  const AppFontSizeScale(this.factor, this.displayName);

  String get id => name;

  static AppFontSizeScale fromId(String? id) {
    return AppFontSizeScale.values.firstWhere(
      (e) => e.name == id,
      orElse: () => AppFontSizeScale.normal,
    );
  }
}

enum AppBackgroundOption {
  defaultTheme('Default', null, false),
  solidSlate('Slate', null, false),
  solidNavy('Deep Navy', null, false),
  natureForest('Forest Mist', 'assets/wallpapers/forest.jpg', true),
  natureMountain('Mountain Dusk', 'assets/wallpapers/mountain.jpg', true),
  natureLake('Calm Aurora Lake', 'assets/wallpapers/lake.jpg', true);

  final String displayName;
  final String? assetPath;
  final bool isWallpaper;
  const AppBackgroundOption(this.displayName, this.assetPath, this.isWallpaper);

  String get id => name;

  static AppBackgroundOption fromId(String? id) {
    return AppBackgroundOption.values.firstWhere(
      (e) => e.name == id,
      orElse: () => AppBackgroundOption.defaultTheme,
    );
  }
}

enum AppPrimaryColor {
  blue('Default', Color(0xFF2563EB), Color(0xFF60A5FA)),
  teal('Teal', Color(0xFF0D9488), Color(0xFF03DAC6)),
  green('Green', Color(0xFF059669), Color(0xFF34D399)),
  cyan('Cyan', Color(0xFF0284C7), Color(0xFF38BDF8)),
  purple('Purple', Color(0xFF7C3AED), Color(0xFFA78BFA)),
  magenta('Magenta', Color(0xFFC026D3), Color(0xFFE879F9)),
  orange('Orange', Color(0xFFD97706), Color(0xFFFB923C)),
  rose('Rose', Color(0xFFE11D48), Color(0xFFFB7185));

  final String displayName;
  final Color lightColor;
  final Color darkColor;

  const AppPrimaryColor(this.displayName, this.lightColor, this.darkColor);

  String get id => name;

  static AppPrimaryColor fromId(String? id) {
    return AppPrimaryColor.values.firstWhere(
      (e) => e.name == id,
      orElse: () => AppPrimaryColor.blue,
    );
  }

  Color colorForBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? darkColor : lightColor;
}

class AppearanceState extends Equatable {
  final AppThemeStyle themeStyle;
  final AppPrimaryColor primaryColor;
  final AppFontFamily fontFamily;
  final AppFontSizeScale fontSizeScale;
  final AppBackgroundOption backgroundOption;

  const AppearanceState({
    this.themeStyle = AppThemeStyle.dark,
    this.primaryColor = AppPrimaryColor.blue,
    this.fontFamily = AppFontFamily.system,
    this.fontSizeScale = AppFontSizeScale.normal,
    this.backgroundOption = AppBackgroundOption.defaultTheme,
  });

  AppearanceState copyWith({
    AppThemeStyle? themeStyle,
    AppPrimaryColor? primaryColor,
    AppFontFamily? fontFamily,
    AppFontSizeScale? fontSizeScale,
    AppBackgroundOption? backgroundOption,
  }) {
    return AppearanceState(
      themeStyle: themeStyle ?? this.themeStyle,
      primaryColor: primaryColor ?? this.primaryColor,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSizeScale: fontSizeScale ?? this.fontSizeScale,
      backgroundOption: backgroundOption ?? this.backgroundOption,
    );
  }

  @override
  List<Object?> get props => [
        themeStyle,
        primaryColor,
        fontFamily,
        fontSizeScale,
        backgroundOption,
      ];
}
