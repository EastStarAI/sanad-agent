import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/theme/app_color_scheme.dart';
import 'package:sanad_client/core/theme/app_themes.dart';

void main() {
  test('light and dark themes use the application primary color', () {
    const applicationPrimary = Color(0xFF60A5FA);
    const onApplicationPrimary = Color(0xFF0A0A0A);

    expect(AppColorScheme.light.primary, applicationPrimary);
    expect(AppColorScheme.dark.primary, applicationPrimary);
    expect(AppColorScheme.light.onPrimary, onApplicationPrimary);
    expect(AppColorScheme.dark.onPrimary, onApplicationPrimary);
  });

  test('light theme provides distinct surface, card, and outline contrast levels', () {
    final light = AppColorScheme.light;
    final theme = AppThemes.light;

    // Card background should be elevated and pure white
    expect(theme.cardTheme.color, const Color(0xFFFFFFFF));
    // Scaffold background is separated from card and surface
    expect(theme.scaffoldBackgroundColor, const Color(0xFFEFEFEF));
    expect(light.surface, const Color(0xFFF4F4F5));
    expect(light.outline, const Color(0xFFDCDDE0));
    expect(theme.dividerTheme.color, const Color(0xFFDCDDE0));
  });

  test('dark theme provides distinct surface, card, and outline contrast levels', () {
    final dark = AppColorScheme.dark;
    final theme = AppThemes.dark;

    expect(theme.cardTheme.color, const Color(0xFF252525));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF1E1E1E));
    expect(dark.surface, const Color(0xFF171717));
    expect(dark.outline, const Color(0xFF2D2D2D));
    expect(theme.dividerTheme.color, const Color(0xFF2D2D2D));
  });
}

