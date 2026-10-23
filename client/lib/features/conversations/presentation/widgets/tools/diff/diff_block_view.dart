import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/code_highlighting.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/diff/unified_diff_parser.dart';

/// Renders a parsed unified diff patch with its gutter, word-level highlights
/// for paired additions and deletions, and hunk separators.
///
/// The hosting tile `State` owns [highlightCache] and the collapse decision;
/// this view only renders the rows it is given.
class DiffBlockView extends StatelessWidget {
  const DiffBlockView({
    super.key,
    required this.patch,
    required this.filePath,
    this.startLine,
    this.editStartLines,
    required this.isFullyExpanded,
    required this.highlightCache,
  });

  final String patch;
  final String filePath;
  final int? startLine;
  final List<int>? editStartLines;

  /// Mirrors the tile's expanded state; a collapsed tile renders unhighlighted
  /// rows, exactly like a collapsed code block.
  final bool isFullyExpanded;

  /// Highlight cache owned by the hosting tile `State`.
  final CodeHighlightCache highlightCache;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Soft, transparent background colors to support both light and dark themes beautifully
    final redBgColor = Colors.red.withValues(alpha: isDark ? 0.12 : 0.06);
    final greenBgColor = Colors.green.withValues(alpha: isDark ? 0.12 : 0.06);

    // Highlight colors for word-level differences
    final redHighlightColor = Colors.red.withValues(alpha: isDark ? 0.35 : 0.2);
    final greenHighlightColor = Colors.green.withValues(alpha: isDark ? 0.35 : 0.2);

    // High-contrast text colors
    final redTextColor = isDark ? Colors.red.shade300 : Colors.red.shade900;
    final greenTextColor = isDark ? Colors.green.shade300 : Colors.green.shade900;

    final parsedLines = parseAndPairDiff(patch, startLine: startLine, editStartLines: editStartLines);
    final widgets = <Widget>[];

    for (final line in parsedLines) {
      if (line.isHeader) {
        widgets.add(
          Container(
            width: double.infinity,
            color: isDark
                ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.12)
                : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            child: Row(
              children: [
                Icon(
                  Icons.unfold_more,
                  size: 13,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 8),
                Text(
                  line.content,
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      final isAddition = line.prefix == '+';
      final isDeletion = line.prefix == '-';

      Color? bgColor;
      Color prefixColor = Colors.grey;

      if (isAddition) {
        bgColor = greenBgColor;
        prefixColor = greenTextColor;
      } else if (isDeletion) {
        bgColor = redBgColor;
        prefixColor = redTextColor;
      }

      // Build the codeSpan
      TextSpan codeSpan;
      if (isAddition && line.pairedContent != null) {
        // Paired addition: do word-level diffing
        final defaultStyle = GoogleFonts.firaCode(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurface,
          height: 1.5,
        );
        codeSpan = TextSpan(
          children: _buildWordDiffSpans(
            line.pairedContent!,
            line.content,
            isAddition: true,
            baseStyle: defaultStyle,
            highlightColor: greenHighlightColor,
          ),
        );
      } else if (isDeletion && line.pairedContent != null) {
        // Paired deletion: do word-level diffing
        final defaultStyle = GoogleFonts.firaCode(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurface,
          height: 1.5,
        );
        codeSpan = TextSpan(
          children: _buildWordDiffSpans(
            line.content,
            line.pairedContent!,
            isAddition: false,
            baseStyle: defaultStyle,
            highlightColor: redHighlightColor,
          ),
        );
      } else {
        // Unpaired deletion/addition or unchanged line: do normal highlighting
        final highlightedSpans = highlightCache.highlightToLines(
          line.content,
          filePath,
          baseStyle: GoogleFonts.firaCode(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurface,
            height: 1.5,
          ),
          isDark: isDark,
          highlightingEnabled: isFullyExpanded,
        );
        codeSpan = highlightedSpans.isNotEmpty ? highlightedSpans.first : TextSpan(text: line.content);
      }

      widgets.add(
        _buildDiffLine(
          context,
          oldLineNumber: line.oldLineNumber,
          newLineNumber: line.newLineNumber,
          prefix: line.prefix,
          codeSpan: codeSpan,
          bgColor: bgColor,
          prefixColor: prefixColor,
          showLineNumbers: true,
        ),
      );
    }

    return SelectionArea(
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 350),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: constraints.maxWidth,
                      ),
                      child: IntrinsicWidth(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: widgets,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

Widget _buildDiffLine(
  BuildContext context, {
  required int? oldLineNumber,
  required int? newLineNumber,
  required String prefix,
  required TextSpan codeSpan,
  required Color? bgColor,
  required Color prefixColor,
  bool showLineNumbers = true,
}) {
  final lineNumbersStyle = GoogleFonts.firaCode(
    fontSize: 11,
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
    height: 1.5,
  );

  final defaultStyle = GoogleFonts.firaCode(
    fontSize: 11,
    color: Theme.of(context).colorScheme.onSurface,
    height: 1.5,
  );

  final lineNumber = prefix == '-' ? oldLineNumber : newLineNumber;

  return Container(
    color: bgColor,
    padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLineNumbers) ...[
          SelectionContainer.disabled(
            child: SizedBox(
              width: 36,
              child: Text(
                lineNumber != null ? '$lineNumber' : '',
                style: lineNumbersStyle,
                textAlign: TextAlign.right,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        SelectionContainer.disabled(
          child: SizedBox(
            width: 10,
            child: Text(
              prefix,
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: prefixColor,
                fontWeight: FontWeight.bold,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(
            style: defaultStyle,
            children: [codeSpan],
          ),
        ),
      ],
    ),
  );
}

List<TextSpan> _buildWordDiffSpans(
  String oldText,
  String newText, {
  required bool isAddition,
  required TextStyle baseStyle,
  required Color highlightColor,
}) {
  final diffs = diff(oldText, newText);
  cleanupSemantic(diffs);

  final spans = <TextSpan>[];
  for (final diff in diffs) {
    if (isAddition) {
      if (diff.operation == DIFF_EQUAL) {
        spans.add(TextSpan(text: diff.text, style: baseStyle));
      } else if (diff.operation == DIFF_INSERT) {
        spans.add(
          TextSpan(
            text: diff.text,
            style: baseStyle.copyWith(
              backgroundColor: highlightColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    } else {
      if (diff.operation == DIFF_EQUAL) {
        spans.add(TextSpan(text: diff.text, style: baseStyle));
      } else if (diff.operation == DIFF_DELETE) {
        spans.add(
          TextSpan(
            text: diff.text,
            style: baseStyle.copyWith(
              backgroundColor: highlightColor,
              decoration: TextDecoration.lineThrough,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    }
  }
  return spans;
}
