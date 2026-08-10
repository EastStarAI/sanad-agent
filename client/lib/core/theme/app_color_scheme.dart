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
    surfaceContainer: Color(0xFFE5E5E7),
    surfaceContainerHigh: Color(0xFFDCDDE0),
    surfaceContainerHighest: Color(0xFFD0D1D5),
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
    surfaceContainerLow: Color(0xFF1A1A1A),
    surfaceContainer: Color(0xFF252525), // Selected/Hover color
    surfaceContainerHigh: Color(0xFF2A2A2A),
    surfaceContainerHighest: Color(0xFF333333),
  );
}

extension AppColorSchemeX on ColorScheme {
  Color get codeColor => brightness == Brightness.dark
      ? const Color(0xFFE5C07B) // Warm amber/gold for dark mode
      : const Color(0xFFB58900); // Warm amber/gold for light mode
}
