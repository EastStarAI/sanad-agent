import 'dart:convert';

/// Line anchors reported by the file-edit tool for every `---`-separated hunk.
///
/// Returns `null` when the payload carries no list or a value that is not a
/// number, so the caller falls back to sequential numbering.
List<int>? parseEditStartLines(Map<String, dynamic>? parsedOutput) {
  final raw = parsedOutput?['editStartLines'];
  if (raw is! List) return null;
  final lines = <int>[];
  for (final item in raw) {
    if (item is num) {
      lines.add(item.toInt());
    } else {
      final parsed = int.tryParse(item?.toString() ?? '');
      if (parsed == null) return null;
      lines.add(parsed);
    }
  }
  return lines;
}

/// Parses [patch] into renderable rows and pairs deletions with additions.
///
/// [startLine] anchors the first row's old/new line numbers. A `---` row
/// separates hunks and re-anchors the counters at the matching entry of
/// [editStartLines] when the payload provides one.
List<ParsedDiffLine> parseAndPairDiff(String patch, {int? startLine, List<int>? editStartLines}) {
  final List<ParsedDiffLine> tempLines = [];
  final lines = const LineSplitter().convert(patch);

  int? oldLineCounter = startLine;
  int? newLineCounter = startLine;
  var hunkIndex = 0;

  for (final line in lines) {
    if (line == '---') {
      // Multi-chunk hunk separator: reposition counters at the next chunk's start.
      hunkIndex++;
      if (editStartLines != null && hunkIndex < editStartLines.length) {
        oldLineCounter = editStartLines[hunkIndex];
        newLineCounter = editStartLines[hunkIndex];
      }
      continue;
    }
    if (line.startsWith('+')) {
      tempLines.add(
        ParsedDiffLine(
          oldLineNumber: null,
          newLineNumber: newLineCounter,
          prefix: '+',
          content: line.substring(1),
        ),
      );
      if (newLineCounter != null) newLineCounter++;
    } else if (line.startsWith('-')) {
      tempLines.add(
        ParsedDiffLine(
          oldLineNumber: oldLineCounter,
          newLineNumber: null,
          prefix: '-',
          content: line.substring(1),
        ),
      );
      if (oldLineCounter != null) oldLineCounter++;
    } else {
      final content = line.startsWith(' ') ? line.substring(1) : line;
      tempLines.add(
        ParsedDiffLine(
          oldLineNumber: oldLineCounter,
          newLineNumber: newLineCounter,
          prefix: ' ',
          content: content,
        ),
      );
      if (oldLineCounter != null) oldLineCounter++;
      if (newLineCounter != null) newLineCounter++;
    }
  }

  final List<ParsedDiffLine> finalLines = [];
  int i = 0;
  while (i < tempLines.length) {
    if (tempLines[i].prefix == '-') {
      final List<ParsedDiffLine> deletions = [];
      while (i < tempLines.length && tempLines[i].prefix == '-') {
        deletions.add(tempLines[i]);
        i++;
      }
      final List<ParsedDiffLine> additions = [];
      while (i < tempLines.length && tempLines[i].prefix == '+') {
        additions.add(tempLines[i]);
        i++;
      }

      final int commonCount = deletions.length < additions.length ? deletions.length : additions.length;
      for (int k = 0; k < deletions.length; k++) {
        finalLines.add(
          ParsedDiffLine(
            oldLineNumber: deletions[k].oldLineNumber,
            newLineNumber: deletions[k].newLineNumber,
            prefix: deletions[k].prefix,
            content: deletions[k].content,
            isHeader: deletions[k].isHeader,
            pairedContent: k < commonCount ? additions[k].content : null,
          ),
        );
      }
      for (int k = 0; k < additions.length; k++) {
        finalLines.add(
          ParsedDiffLine(
            oldLineNumber: additions[k].oldLineNumber,
            newLineNumber: additions[k].newLineNumber,
            prefix: additions[k].prefix,
            content: additions[k].content,
            isHeader: additions[k].isHeader,
            pairedContent: k < commonCount ? deletions[k].content : null,
          ),
        );
      }
    } else {
      finalLines.add(tempLines[i]);
      i++;
    }
  }

  return finalLines;
}

/// One row of a parsed unified diff patch.
class ParsedDiffLine {
  final int? oldLineNumber;
  final int? newLineNumber;
  final String prefix;
  final String content;
  final bool isHeader;
  final String? pairedContent;

  ParsedDiffLine({
    this.oldLineNumber,
    this.newLineNumber,
    required this.prefix,
    required this.content,
    this.isHeader = false,
    this.pairedContent,
  });
}
