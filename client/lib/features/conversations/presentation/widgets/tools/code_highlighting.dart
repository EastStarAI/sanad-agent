import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

/// Syntax-highlighting cache shared by the file tool tile and its diff block.
///
/// The hosting widget `State` owns one instance and clears it whenever the
/// theme, the rendered event, or the expansion state changes; the cache itself
/// never decides when it is stale.
class CodeHighlightCache {
  static final Highlight _highlighter = Highlight()
    ..registerLanguage('dart', langDart)
    ..registerLanguage('json', langJson)
    ..registerLanguage('yaml', langYaml)
    ..registerLanguage('python', langPython)
    ..registerLanguage('xml', langXml)
    ..registerLanguage('bash', langBash);

  TextSpan? _blockSpan;
  final Map<String, List<TextSpan>> _lineCache = {};

  /// Drops every cached span.
  ///
  /// The owner calls this on theme change, event change, and expansion change.
  void clear() {
    _blockSpan = null;
    _lineCache.clear();
  }

  /// Highlights a whole code block, reusing the cached span until [clear].
  TextSpan codeBlockSpan(
    String code,
    String filePath, {
    required TextStyle baseStyle,
    required bool isDark,
  }) {
    final cached = _blockSpan;
    if (cached != null) return cached;

    final langName = languageNameForPath(filePath);
    final theme = isDark ? githubDarkTheme : githubTheme;

    HighlightResult result;
    try {
      if (langName != null) {
        result = _highlighter.highlight(code: code, language: langName);
      } else {
        result = _highlighter.highlightAuto(code);
      }
    } catch (_) {
      result = _highlighter.highlightAuto(code);
    }

    final renderer = TextSpanRenderer(baseStyle, theme);
    result.render(renderer);
    final span = renderer.span ?? TextSpan(text: code, style: baseStyle);
    _blockSpan = span;
    return span;
  }

  /// Returns one span per rendered source line, reusing the cached lines until
  /// [clear].
  ///
  /// [highlightingEnabled] mirrors the tile's expanded state: a collapsed tile
  /// renders [code] unhighlighted instead of reading or filling the cache.
  List<TextSpan> highlightToLines(
    String code,
    String filePath, {
    required TextStyle baseStyle,
    required bool isDark,
    required bool highlightingEnabled,
  }) {
    if (!highlightingEnabled) {
      return splitSpanIntoLines(TextSpan(text: code, style: baseStyle));
    }

    final cacheKey = '$filePath:$code';
    final cached = _lineCache[cacheKey];
    if (cached != null) return cached;

    final langName = languageNameForPath(filePath);
    final theme = isDark ? githubDarkTheme : githubTheme;

    HighlightResult result;
    try {
      if (langName != null) {
        result = _highlighter.highlight(code: code, language: langName);
      } else {
        result = _highlighter.highlightAuto(code);
      }
    } catch (_) {
      result = _highlighter.highlightAuto(code);
    }

    final renderer = TextSpanRenderer(baseStyle, theme);
    result.render(renderer);

    final rootSpan = renderer.span ?? TextSpan(text: code, style: baseStyle);
    final lines = splitSpanIntoLines(rootSpan);
    _lineCache[cacheKey] = lines;
    return lines;
  }
}

/// Registered highlight language for [filePath], or `null` for auto-detection.
String? languageNameForPath(String filePath) {
  final ext = filePath.split('.').last.toLowerCase();
  switch (ext) {
    case 'dart':
      return 'dart';
    case 'json':
      return 'json';
    case 'yaml':
    case 'yml':
      return 'yaml';
    case 'py':
      return 'python';
    case 'html':
    case 'xml':
      return 'xml';
    case 'sh':
    case 'bash':
      return 'bash';
    default:
      return null;
  }
}

/// Splits a highlighted [span] into one span per rendered source line.
List<TextSpan> splitSpanIntoLines(TextSpan span) {
  final List<List<TextSpan>> lines = [[]];

  void traverse(TextSpan node, TextStyle? parentStyle) {
    final currentStyle = node.style != null
        ? (parentStyle != null ? parentStyle.merge(node.style) : node.style)
        : parentStyle;

    if (node.text != null && node.text!.isNotEmpty) {
      final textLines = node.text!.split('\n');
      for (int i = 0; i < textLines.length; i++) {
        if (i > 0) {
          lines.add([]);
        }
        if (textLines[i].isNotEmpty) {
          lines.last.add(TextSpan(text: textLines[i], style: currentStyle));
        }
      }
    }

    if (node.children != null) {
      for (final child in node.children!) {
        if (child is TextSpan) {
          traverse(child, currentStyle);
        }
      }
    }
  }

  traverse(span, span.style);

  return lines.map((lineChildren) {
    return TextSpan(children: lineChildren);
  }).toList();
}
