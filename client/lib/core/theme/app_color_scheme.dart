import 'package:flutter/material.dart';

class AppColorScheme {
  static const ColorScheme light = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF60A5FA),
    onPrimary: Color(0xFF0A0A0A),
    primaryContainer: Color(0xFFE0E7FF),
    onPrimaryContainer: Color(0xFF0A0A0A),
    secondary: Color(0xFF0D9488),
    onSecondary: Colors.white,
    error: Color(0xFFB00020),
    onError: Colors.white,
    surface: Color(0xFFF4F4F5),
    onSurface: Color(0xFF1A1A1A),
    onSurfaceVariant: Color(0xFF737373),
    outline: Color(0xFFDCDDE0),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F7F8),
    surfaceContainer: Color(0xFFEFEFEF),
    surfaceContainerHigh: Color(0xFFEFEFEF),
    surfaceContainerHighest: Color(0xFFE5E5E7),
  );

  static const ColorScheme dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF60A5FA),
    onPrimary: Color(0xFF0A0A0A),
    primaryContainer: Color(0xFF252525),
    onPrimaryContainer: Colors.white,
    secondary: Color(0xFF03DAC6),
    onSecondary: Colors.black,
    error: Color(0xFFCF6679),
    onError: Colors.black,
    surface: Color(0xFF171717), // Sidebar color
    onSurface: Colors.white,
    onSurfaceVariant: Colors.white70,
    outline: Color(0xFF2D2D2D), // Border color
    surfaceContainerLowest: Color(0xFF141414),
    surfaceContainerLow: Color(0xFF171717),
    surfaceContainer: Color(0xFF252525), // Selected/Hover color
    surfaceContainerHigh: Color(0xFF1E1E1E), // Matches main app background
    surfaceContainerHighest: Color(0xFF222222),
  );

  static const ColorScheme midnight = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF60A5FA),
    onPrimary: Color(0xFF0A0A0A),
    primaryContainer: Color(0xFF141414),
    onPrimaryContainer: Colors.white,
    secondary: Color(0xFF03DAC6),
    onSecondary: Colors.black,
    error: Color(0xFFCF6679),
    onError: Colors.black,
    surface: Color(0xFF000000), // Pure OLED black
    onSurface: Colors.white,
    onSurfaceVariant: Color(0xFFA1A1AA),
    outline: Color(0xFF1E1E1E),
    surfaceContainerLowest: Color(0xFF000000),
    surfaceContainerLow: Color(0xFF080808),
    surfaceContainer: Color(0xFF121212),
    surfaceContainerHigh: Color(0xFF000000),
    surfaceContainerHighest: Color(0xFF181818),
  );

  static const ColorScheme sepia = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFFB45309),
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFF3E5D0),
    onPrimaryContainer: Color(0xFF2C2416),
    secondary: Color(0xFF78350F),
    onSecondary: Colors.white,
    error: Color(0xFFB00020),
    onError: Colors.white,
    surface: Color(0xFFF5E8D3),
    onSurface: Color(0xFF2D2319),
    onSurfaceVariant: Color(0xFF6E5843),
    outline: Color(0xFFD8C5A8),
    surfaceContainerLowest: Color(0xFFFFFDF8),
    surfaceContainerLow: Color(0xFFFBF2E3),
    surfaceContainer: Color(0xFFF2E2C8),
    surfaceContainerHigh: Color(0xFFF7ECDA),
    surfaceContainerHighest: Color(0xFFE8D4B4),
  );
}

extension AppColorSchemeX on ColorScheme {
  Color get codeColor => brightness == Brightness.dark
      ? const Color(0xFFE5C07B) // Warm amber/gold for dark mode
      : const Color(0xFFB58900); // Warm amber/gold for light mode
}
