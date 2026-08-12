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

  /// Determines direction from the first strong character on the first
  /// directional line. Markdown markers, numbers, punctuation, and URLs do not
  /// override the natural-language opening word.
  static TextDirection getTextDirection(String? text) {
    if (text == null || text.trim().isEmpty) return TextDirection.ltr;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final withoutUrls = trimmed.replaceAll(_urlRegex, '').trim();
      final lineToAnalyze = withoutUrls.isNotEmpty ? withoutUrls : trimmed;
      final strongMatch = _strongCharRegex.firstMatch(lineToAnalyze);
      if (strongMatch == null) continue;

      return _rtlCharRegex.hasMatch(strongMatch.group(0)!) ? TextDirection.rtl : TextDirection.ltr;
    }

    return TextDirection.ltr;
  }
}
