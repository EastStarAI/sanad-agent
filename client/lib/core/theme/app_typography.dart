import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central typography owner for the Client.
///
/// Widget code must never name a font family. There are exactly two entry
/// points:
///
/// * [text] resolves the font the user selected in Settings from the active
///   theme, so a hand-built [TextStyle] still follows that choice.
/// * [mono] is the single monospace style for code, diffs, terminals, paths,
///   commands and raw JSON. Machine-readable text is intentionally fixed and
///   never follows the user's app font.
///
/// A widget that needs a plain style inherits the selected family from the
/// ambient [DefaultTextStyle] through the themed [Material] surface; a widget
/// that builds its own [TextStyle], a `RichText` root span, or a
/// `ButtonStyle.textStyle` must go through [text].
abstract final class AppTypography {
  /// Family name of the bundled Cairo asset family declared in `pubspec.yaml`.
  ///
  /// Cairo is the default app font and ships as a Flutter asset family, so the
  /// default renders offline on every platform from the first frame, including
  /// a first launch with no network.
  static const String bundledCairoFamily = 'Cairo';

  /// A [TextStyle] carrying the user's selected app font.
  ///
  /// Only the attributes passed here are set. Every other attribute keeps
  /// inheriting from the ambient [DefaultTextStyle], so call sites keep their
  /// previous metrics and only the family becomes dynamic.
  static TextStyle text(
    BuildContext context, {
    TextStyle? textStyle,
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    List<FontFeature>? fontFeatures,
  }) {
    final selected = Theme.of(context).textTheme.bodyMedium;
    return (textStyle ?? const TextStyle()).copyWith(
      fontFamily: selected?.fontFamily,
      fontFamilyFallback: selected?.fontFamilyFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      height: height,
      decoration: decoration,
      decorationColor: decorationColor,
      fontFeatures: fontFeatures,
    );
  }

  /// The one monospace style for machine-readable text.
  ///
  /// Use it for code, diffs, terminals, shell commands, paths and raw JSON.
  /// It is deliberately independent of the user's app font.
  static TextStyle mono({
    TextStyle? textStyle,
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    List<FontFeature>? fontFeatures,
  }) {
    return GoogleFonts.firaCode(
      textStyle: textStyle,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      height: height,
      decoration: decoration,
      decorationColor: decorationColor,
      fontFeatures: fontFeatures,
    );
  }
}
