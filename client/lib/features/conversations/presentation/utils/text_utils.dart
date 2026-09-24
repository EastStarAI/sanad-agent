import 'package:flutter/material.dart';

class TextUtils {
  /// Regular expression for RTL script characters (Hebrew, Arabic,
  /// Syriac, Thaana, N'Ko, Samaritan, Mandaic, Arabic Extended, Presentation Forms).
  static final RegExp _rtlCharRegex = RegExp(
    r'[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F\u0870-\u089F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
  );

  /// Regular expression to strip URLs when analyzing natural language direction.
  static final RegExp _urlRegex = RegExp(
    r'https?://[^\s]+|www\.[^\s]+',
    caseSensitive: false,
  );

  /// Combined expression to find the first strong directional character.
  static final RegExp _strongCharRegex = RegExp(
    r'[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F\u0870-\u089F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]|[a-zA-Z\u00C0-\u024F\u0370-\u052F\u1E00-\u1EFF\u2C00-\u2DDF\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]',
  );

  /// Determines direction from the first strong character, while also accounting
  /// for predominant RTL script across multi-line content (e.g. a brief English
  /// intro followed by a substantial Arabic response).
  static TextDirection getTextDirection(String? text) {
    if (text == null || text.trim().isEmpty) return TextDirection.ltr;

    // 1. Identify the first strong directional character on the first directional line
    TextDirection? firstLineDirection;
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final withoutUrls = trimmed.replaceAll(_urlRegex, '').trim();
      final lineToAnalyze = withoutUrls.isNotEmpty ? withoutUrls : trimmed;
      // Strip numeric multiplier/tag prefixes (e.g. '99x ', '1x ', 'v2 ') before checking direction
      final normalizedLine = lineToAnalyze.replaceFirst(
        RegExp(r'^[\d\s#_.:-]*\d+[a-zA-Z]{1,3}\s+'),
        '',
      );
      final strongMatch = _strongCharRegex.firstMatch(
        normalizedLine.isNotEmpty ? normalizedLine : lineToAnalyze,
      );
      if (strongMatch == null) continue;

      firstLineDirection = _rtlCharRegex.hasMatch(strongMatch.group(0)!)
          ? TextDirection.rtl
          : TextDirection.ltr;
      break;
    }

    // If first strong character is RTL, respect it immediately
    if (firstLineDirection == TextDirection.rtl) {
      return TextDirection.rtl;
    }

    // 2. If first strong character was LTR, check if multi-line text is predominantly RTL
    // (e.g. an English greeting or header followed by a largely Arabic body).
    if (text.contains('\n')) {
      final withoutCode = text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
      final clean = withoutCode.replaceAll(_urlRegex, '').trim();

      int rtlCount = 0;
      int ltrCount = 0;
      for (final match in _strongCharRegex.allMatches(clean)) {
        final char = match.group(0)!;
        if (_rtlCharRegex.hasMatch(char)) {
          rtlCount++;
        } else {
          ltrCount++;
        }
      }

      if (rtlCount > ltrCount && rtlCount > 0) {
        return TextDirection.rtl;
      }
    }

    return firstLineDirection ?? TextDirection.ltr;
  }
}
