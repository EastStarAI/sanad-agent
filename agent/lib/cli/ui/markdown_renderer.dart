import 'dart:math';

import 'ansi_styles.dart';
import 'syntax_highlighter.dart';
import 'terminal_theme.dart';

/// Renders Markdown documents into richly formatted terminal output using ANSI escape codes.
class MarkdownRenderer {
  final TerminalTheme theme;
  final SyntaxHighlighter _highlighter;
  final int defaultWidth;

  MarkdownRenderer({TerminalTheme? theme, this.defaultWidth = 80})
    : theme = theme ?? TerminalTheme.dark(),
      _highlighter = SyntaxHighlighter(theme ?? TerminalTheme.dark());

  /// Renders a full Markdown [text] string into formatted terminal output.
  String render(String text, {int? maxWidth}) {
    if (text.isEmpty) return '';

    final width = maxWidth ?? defaultWidth;
    final lines = text.split('\n');
    final output = <String>[];

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      // 1. Fenced code block
      if (trimmed.startsWith('```')) {
        final lang = trimmed.substring(3).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // Skip closing ```
        output.add(
          _renderCodeBlock(codeLines.join('\n'), lang: lang, width: width),
        );
        continue;
      }

      // 2. Table detection (header row containing | followed by separator row |---|)
      if (_isTableRow(line) &&
          i + 1 < lines.length &&
          _isTableSeparator(lines[i + 1])) {
        final tableLines = <String>[line];
        i++;
        tableLines.add(lines[i]); // separator
        i++;
        while (i < lines.length && _isTableRow(lines[i])) {
          tableLines.add(lines[i]);
          i++;
        }
        output.add(_renderTable(tableLines, width: width));
        continue;
      }

      // 3. Blockquote (> ...)
      if (trimmed.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          var qLine = lines[i].trim();
          if (qLine.startsWith('> ')) {
            qLine = qLine.substring(2);
          } else if (qLine.startsWith('>')) {
            qLine = qLine.substring(1).trimLeft();
          }
          quoteLines.add(qLine);
          i++;
        }
        output.add(_renderBlockquote(quoteLines, width: width));
        continue;
      }

      // 4. Horizontal rule (---, ***, ___)
      if (_isHorizontalRule(trimmed)) {
        output.add(_renderHorizontalRule(width: width));
        i++;
        continue;
      }

      // 5. Headers (# Header)
      if (trimmed.startsWith('#')) {
        final header = _parseHeader(trimmed);
        if (header != null) {
          output.add(_renderHeader(header.level, header.text, width: width));
          i++;
          continue;
        }
      }

      // 6. Unordered list item (- item, * item, + item)
      final unorderedMatch = RegExp(r'^(\s*)([-*+])\s+(.*)$').firstMatch(line);
      if (unorderedMatch != null) {
        final indent = unorderedMatch.group(1) ?? '';
        final content = unorderedMatch.group(3) ?? '';
        output.add(_renderUnorderedListItem(indent, content, width: width));
        i++;
        continue;
      }

      // 7. Ordered list item (1. item)
      final orderedMatch = RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(line);
      if (orderedMatch != null) {
        final indent = orderedMatch.group(1) ?? '';
        final number = orderedMatch.group(2) ?? '1';
        final content = orderedMatch.group(3) ?? '';
        output.add(
          _renderOrderedListItem(indent, number, content, width: width),
        );
        i++;
        continue;
      }

      // 8. Empty line
      if (trimmed.isEmpty) {
        output.add('');
        i++;
        continue;
      }

      // 9. Regular paragraph text
      output.add(_renderInlineFormatting(line));
      i++;
    }

    var result = output.join('\n');
    if (!theme.enableColor) {
      result = Ansi.strip(result);
    }
    return result;
  }

  // --- Inline Formatting ---

  /// Formats inline elements: bold, italic, strikethrough, inline code, links.
  String _renderInlineFormatting(String text) {
    if (text.isEmpty) return text;
    var result = text;

    // Inline code: `code`
    result = result.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) {
      final code = m.group(1)!;
      if (!theme.enableColor) return '`$code`';
      return '${theme.inlineCode} $code ${Ansi.reset}';
    });

    // Bold + Italic: ***text*** or ___text___
    result = result.replaceAllMapped(RegExp(r'(\*\*\*|___)(.*?)\1'), (m) {
      final inner = m.group(2)!;
      if (!theme.enableColor) return inner;
      return '${theme.bold}${theme.italic}$inner${Ansi.reset}';
    });

    // Bold: **text** or __text__
    result = result.replaceAllMapped(RegExp(r'(\*\*|__)(.*?)\1'), (m) {
      final inner = m.group(2)!;
      if (!theme.enableColor) return inner;
      return '${theme.bold}$inner${Ansi.reset}';
    });

    // Italic: *text* or _text_ (excluding inside words like some_var_name)
    result = result.replaceAllMapped(
      RegExp(r'(?<!\w)(\*|_)(?!\s)(.+?)(?<!\s)\1(?!\w)'),
      (m) {
        final inner = m.group(2)!;
        if (!theme.enableColor) return inner;
        return '${theme.italic}$inner${Ansi.reset}';
      },
    );

    // Strikethrough: ~~text~~
    result = result.replaceAllMapped(RegExp(r'~~(.*?)~~'), (m) {
      final inner = m.group(1)!;
      if (!theme.enableColor) return inner;
      return '${theme.strikethrough}$inner${Ansi.reset}';
    });

    // Links: [text](url)
    result = result.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (m) {
      final label = m.group(1)!;
      final url = m.group(2)!;
      if (!theme.enableColor) return '$label ($url)';
      return '${theme.linkText}$label${Ansi.reset} ${theme.linkUrl}($url)${Ansi.reset}';
    });

    return result;
  }

  // --- Block Elements ---

  _HeaderInfo? _parseHeader(String trimmed) {
    int level = 0;
    while (level < trimmed.length && trimmed[level] == '#') {
      level++;
    }
    if (level > 6 || level == 0) return null;
    if (level < trimmed.length && trimmed[level] != ' ') return null;
    final text = trimmed.substring(level).trim();
    return _HeaderInfo(level, text);
  }

  String _renderHeader(int level, String text, {required int width}) {
    final formattedText = _renderInlineFormatting(text);
    if (!theme.enableColor) {
      final prefix = '#' * level;
      return '$prefix $text';
    }

    String headerStyle;
    switch (level) {
      case 1:
        headerStyle = theme.h1;
        final bar = '═' * min(width, max(Ansi.visibleLength(text) + 2, 20));
        return '\n$headerStyle$formattedText${Ansi.reset}\n${theme.horizontalRule}$bar${Ansi.reset}';
      case 2:
        headerStyle = theme.h2;
        final bar = '─' * min(width, max(Ansi.visibleLength(text) + 2, 16));
        return '\n$headerStyle$formattedText${Ansi.reset}\n${theme.horizontalRule}$bar${Ansi.reset}';
      case 3:
        headerStyle = theme.h3;
        return '\n$headerStyle▸ $formattedText${Ansi.reset}';
      case 4:
        headerStyle = theme.h4;
        return '\n$headerStyle▪ $formattedText${Ansi.reset}';
      case 5:
        headerStyle = theme.h5;
        return '$headerStyle• $formattedText${Ansi.reset}';
      case 6:
      default:
        headerStyle = theme.h6;
        return '$headerStyle  $formattedText${Ansi.reset}';
    }
  }

  String _renderUnorderedListItem(
    String indent,
    String content, {
    required int width,
  }) {
    final formattedContent = _renderInlineFormatting(content);
    final bulletChar = indent.isEmpty ? '•' : '⁃';
    final bullet = theme.enableColor
        ? '${theme.bullet}$bulletChar${Ansi.reset}'
        : bulletChar;
    return '$indent$bullet $formattedContent';
  }

  String _renderOrderedListItem(
    String indent,
    String number,
    String content, {
    required int width,
  }) {
    final formattedContent = _renderInlineFormatting(content);
    final numStr = theme.enableColor
        ? '${theme.listNumber}$number.${Ansi.reset}'
        : '$number.';
    return '$indent$numStr $formattedContent';
  }

  String _renderBlockquote(List<String> lines, {required int width}) {
    final border = theme.enableColor
        ? '${theme.blockquoteBorder}│${Ansi.reset}'
        : '|';
    final buffer = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      final line = _renderInlineFormatting(lines[i]);
      final styledLine = theme.enableColor
          ? '${theme.blockquoteText}$line${Ansi.reset}'
          : line;
      buffer.write('$border $styledLine');
      if (i < lines.length - 1) buffer.write('\n');
    }
    return buffer.toString();
  }

  bool _isHorizontalRule(String trimmed) {
    if (trimmed.length < 3) return false;
    final ch = trimmed[0];
    if (ch != '-' && ch != '*' && ch != '_') return false;
    return trimmed.replaceAll(ch, '').isEmpty;
  }

  String _renderHorizontalRule({required int width}) {
    final ruleChar = theme.enableColor ? '─' : '-';
    final line = ruleChar * min(width, 60);
    if (!theme.enableColor) return line;
    return '${theme.horizontalRule}$line${Ansi.reset}';
  }

  // --- Code Blocks ---

  String _renderCodeBlock(String code, {String? lang, required int width}) {
    final effectiveLang = (lang ?? '').trim();
    final highlightedCode = _highlighter.highlight(
      code,
      language: effectiveLang,
    );
    final codeLines = highlightedCode.split('\n');

    if (!theme.enableColor) {
      final header = effectiveLang.isNotEmpty ? '```$effectiveLang' : '```';
      return '$header\n$code\n```';
    }

    final boxWidth = min(width, 80);
    final borderStyle = theme.codeBlockBorder;
    final headerStyle = theme.codeBlockHeader;

    final topHeaderLabel = effectiveLang.isNotEmpty ? ' $effectiveLang ' : '';
    final remainingWidth = max(boxWidth - topHeaderLabel.length - 3, 4);
    final topBar = '─' * remainingWidth;

    final buffer = StringBuffer();
    buffer.writeln(
      '$borderStyle╭─$headerStyle$topHeaderLabel$borderStyle$topBar${Ansi.reset}',
    );

    for (final line in codeLines) {
      buffer.writeln('$borderStyle│${Ansi.reset} $line');
    }

    final bottomBar = '─' * (boxWidth - 1);
    buffer.write('$borderStyle╰$bottomBar${Ansi.reset}');
    return buffer.toString();
  }

  // --- Tables ---

  bool _isTableRow(String line) {
    final trimmed = line.trim();
    return trimmed.startsWith('|') &&
        trimmed.endsWith('|') &&
        trimmed.length > 2;
  }

  bool _isTableSeparator(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) return false;
    final cells = trimmed.substring(1, trimmed.length - 1).split('|');
    if (cells.isEmpty) return false;
    return cells.every((c) {
      final t = c.trim();
      return t.isNotEmpty && t.replaceAll(RegExp(r'[:\-]'), '').isEmpty;
    });
  }

  String _renderTable(List<String> rawLines, {required int width}) {
    if (rawLines.length < 2) return rawLines.join('\n');

    // Parse rows
    final rows = <List<String>>[];
    for (final line in rawLines) {
      final trimmed = line.trim();
      final content = trimmed.substring(1, trimmed.length - 1);
      final cells = content.split('|').map((c) => c.trim()).toList();
      rows.add(cells);
    }

    final headerRow = rows[0];
    final separatorRow = rows[1];
    final dataRows = rows.skip(2).toList();
    final columnCount = headerRow.length;

    // Determine alignments (:--- left, :---: center, ---: right)
    final alignments = <_TableAlignment>[];
    for (int col = 0; col < columnCount; col++) {
      final sep = col < separatorRow.length ? separatorRow[col] : '---';
      final startsColon = sep.startsWith(':');
      final endsColon = sep.endsWith(':');
      if (startsColon && endsColon) {
        alignments.add(_TableAlignment.center);
      } else if (endsColon) {
        alignments.add(_TableAlignment.right);
      } else {
        alignments.add(_TableAlignment.left);
      }
    }

    // Measure column widths (visible characters)
    final colWidths = List<int>.filled(columnCount, 3);
    for (final row in [headerRow, ...dataRows]) {
      for (int col = 0; col < columnCount; col++) {
        if (col < row.length) {
          final cellText = Ansi.strip(_renderInlineFormatting(row[col]));
          colWidths[col] = max(colWidths[col], cellText.length);
        }
      }
    }

    final isPlain = !theme.enableColor;
    final borderStyle = theme.tableBorder;
    final headerStyle = theme.tableHeader;
    final cellStyle = theme.tableCell;

    // Unicode box characters vs ASCII characters
    final cTopLeft = isPlain ? '+' : '┌';
    final cTopRight = isPlain ? '+' : '┐';
    final cBottomLeft = isPlain ? '+' : '└';
    final cBottomRight = isPlain ? '+' : '┘';
    final cMidLeft = isPlain ? '+' : '├';
    final cMidRight = isPlain ? '+' : '┤';
    final cCross = isPlain ? '+' : '┼';
    final cTopCross = isPlain ? '+' : '┬';
    final cBottomCross = isPlain ? '+' : '┴';
    final cHoriz = isPlain ? '-' : '─';
    final cVert = isPlain ? '|' : '│';

    final buffer = StringBuffer();

    // Top border
    buffer.write(isPlain ? '' : borderStyle);
    buffer.write(cTopLeft);
    for (int c = 0; c < columnCount; c++) {
      buffer.write(cHoriz * (colWidths[c] + 2));
      if (c < columnCount - 1) buffer.write(cTopCross);
    }
    buffer.writeln('$cTopRight${isPlain ? '' : Ansi.reset}');

    // Header row
    buffer.write(isPlain ? '' : borderStyle);
    buffer.write(cVert);
    buffer.write(isPlain ? '' : Ansi.reset);
    for (int c = 0; c < columnCount; c++) {
      final cell = c < headerRow.length ? headerRow[c] : '';
      final formatted = _renderInlineFormatting(cell);
      final aligned = _alignText(formatted, colWidths[c], alignments[c]);
      buffer.write(' $headerStyle$aligned${isPlain ? '' : Ansi.reset} ');
      buffer.write(isPlain ? '' : borderStyle);
      buffer.write(cVert);
      buffer.write(isPlain ? '' : Ansi.reset);
    }
    buffer.writeln();

    // Divider
    buffer.write(isPlain ? '' : borderStyle);
    buffer.write(cMidLeft);
    for (int c = 0; c < columnCount; c++) {
      buffer.write(cHoriz * (colWidths[c] + 2));
      if (c < columnCount - 1) buffer.write(cCross);
    }
    buffer.writeln('$cMidRight${isPlain ? '' : Ansi.reset}');

    // Data rows
    for (final row in dataRows) {
      buffer.write(isPlain ? '' : borderStyle);
      buffer.write(cVert);
      buffer.write(isPlain ? '' : Ansi.reset);
      for (int c = 0; c < columnCount; c++) {
        final cell = c < row.length ? row[c] : '';
        final formatted = _renderInlineFormatting(cell);
        final aligned = _alignText(formatted, colWidths[c], alignments[c]);
        buffer.write(' $cellStyle$aligned${isPlain ? '' : Ansi.reset} ');
        buffer.write(isPlain ? '' : borderStyle);
        buffer.write(cVert);
        buffer.write(isPlain ? '' : Ansi.reset);
      }
      buffer.writeln();
    }

    // Bottom border
    buffer.write(isPlain ? '' : borderStyle);
    buffer.write(cBottomLeft);
    for (int c = 0; c < columnCount; c++) {
      buffer.write(cHoriz * (colWidths[c] + 2));
      if (c < columnCount - 1) buffer.write(cBottomCross);
    }
    buffer.write('$cBottomRight${isPlain ? '' : Ansi.reset}');

    return buffer.toString();
  }

  String _alignText(String text, int targetWidth, _TableAlignment alignment) {
    final visibleLen = Ansi.visibleLength(text);
    final paddingNeeded = max(0, targetWidth - visibleLen);
    switch (alignment) {
      case _TableAlignment.left:
        return '$text${' ' * paddingNeeded}';
      case _TableAlignment.right:
        return '${' ' * paddingNeeded}$text';
      case _TableAlignment.center:
        final leftPad = paddingNeeded ~/ 2;
        final rightPad = paddingNeeded - leftPad;
        return '${' ' * leftPad}$text${' ' * rightPad}';
    }
  }
}

enum _TableAlignment { left, center, right }

class _HeaderInfo {
  final int level;
  final String text;
  _HeaderInfo(this.level, this.text);
}
