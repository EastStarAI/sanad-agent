import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/theme/app_themes.dart';

void main() {
  group('AppThemes TooltipTheme', () {
    test('light theme has inverted light-styled tooltip theme', () {
      final lightTheme = AppThemes.light;
      final tooltipTheme = lightTheme.tooltipTheme;

      expect(tooltipTheme, isNotNull);
      final decoration = tooltipTheme.decoration as BoxDecoration?;
      expect(decoration, isNotNull);
      expect(decoration!.color, const Color(0xFFFFFFFF));
      expect(tooltipTheme.textStyle?.color, const Color(0xFF1A1A1A));
    });

    test('dark theme has inverted dark-styled tooltip theme', () {
      final darkTheme = AppThemes.dark;
      final tooltipTheme = darkTheme.tooltipTheme;

      expect(tooltipTheme, isNotNull);
      final decoration = tooltipTheme.decoration as BoxDecoration?;
      expect(decoration, isNotNull);
      expect(decoration!.color, const Color(0xFF252525));
      expect(tooltipTheme.textStyle?.color, Colors.white);
    });
  });
}
