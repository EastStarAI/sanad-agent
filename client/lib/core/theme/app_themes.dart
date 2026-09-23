import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'app_color_scheme.dart';

class AppThemes {
  static ThemeData get light => themeForStyle(AppThemeStyle.light);
  static ThemeData get dark => themeForStyle(AppThemeStyle.dark);
  static ThemeData get midnight => themeForStyle(AppThemeStyle.midnight);
  static ThemeData get sepia => themeForStyle(AppThemeStyle.sepia);

  static ThemeData themeForStyle(
    AppThemeStyle style, {
    AppFontFamily fontFamily = AppFontFamily.system,
    AppPrimaryColor primaryColor = AppPrimaryColor.blue,
  }) {
    final base = switch (style) {
      AppThemeStyle.light => _buildLight(fontFamily),
      AppThemeStyle.dark => _buildDark(fontFamily),
      AppThemeStyle.midnight => _buildMidnight(fontFamily),
      AppThemeStyle.sepia => _buildSepia(fontFamily),
    };
    return _applyPrimaryColor(base, primaryColor);
  }

  static ThemeData _applyPrimaryColor(ThemeData theme, AppPrimaryColor primaryColor) {
    final isDark = theme.brightness == Brightness.dark;
    final primary = primaryColor.colorForBrightness(theme.brightness);
    final onPrimary = ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
        ? Colors.white
        : Colors.black;

    final updatedColorScheme = theme.colorScheme.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primary.withValues(alpha: isDark ? 0.25 : 0.15),
      onPrimaryContainer: isDark ? Colors.white : Colors.black,
      secondary: primary,
      onSecondary: onPrimary,
      secondaryContainer: primary,
      onSecondaryContainer: onPrimary,
    );

    return theme.copyWith(
      colorScheme: updatedColorScheme,
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return primary;
            }
            return null;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return onPrimary;
            }
            return null;
          }),
        ),
      ),
    );
  }

  static TextTheme _applyFontFamily(TextTheme base, AppFontFamily fontFamily) {
    return switch (fontFamily) {
      AppFontFamily.cairo => GoogleFonts.cairoTextTheme(base),
      AppFontFamily.inter => GoogleFonts.interTextTheme(base),
      AppFontFamily.roboto => GoogleFonts.robotoTextTheme(base),
      AppFontFamily.system => base,
    };
  }

  static ThemeData _buildLight(AppFontFamily fontFamily) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: AppColorScheme.light,
      scaffoldBackgroundColor: const Color(0xFFEFEFEF),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFEFEFEF),
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFDCDDE0),
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFFFFFFF),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFFDCDDE0),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: Color(0xFF1A1A1A),
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
    return base.copyWith(textTheme: _applyFontFamily(base.textTheme, fontFamily));
  }

  static ThemeData _buildDark(AppFontFamily fontFamily) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: AppColorScheme.dark,
      scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2D2D2D),
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF252525),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF252525),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFF2D2D2D),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.24),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
    return base.copyWith(textTheme: _applyFontFamily(base.textTheme, fontFamily));
  }

  static ThemeData _buildMidnight(AppFontFamily fontFamily) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: AppColorScheme.midnight,
      scaffoldBackgroundColor: const Color(0xFF000000),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000000),
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF1E1E1E),
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF121212),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFF2A2A2A),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
    return base.copyWith(textTheme: _applyFontFamily(base.textTheme, fontFamily));
  }

  static ThemeData _buildSepia(AppFontFamily fontFamily) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: AppColorScheme.sepia,
      scaffoldBackgroundColor: const Color(0xFFFBF0D9),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFBF0D9),
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFD8C5A8),
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFF5E8D3),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFFFFFDF8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFFD8C5A8),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5A462B).withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: Color(0xFF2D2319),
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
    return base.copyWith(textTheme: _applyFontFamily(base.textTheme, fontFamily));
  }
}
