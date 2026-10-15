import 'dart:io';
import 'dart:isolate';
import '../workspace_path_resolver.dart';
import 'workspace_tools_utils.dart';

class FileEditHandler {
  final WorkspacePathResolver _pathResolver;

  const FileEditHandler(this._pathResolver);

  Future<String> execute(
    Map<String, dynamic> arguments,
    String workspacePath, {
    String? authorizedExternalRoot,
  }) async {
    final path = arguments['path']?.toString() ?? '';
    final rawEdits = arguments['edits'];
    final oldString = arguments['old_string']?.toString();
    final newString = arguments['new_string']?.toString();
    final replaceAll = arguments['replace_all'] == true;

    final List<_EditOperation> edits;
    final bool isMulti;

    if (rawEdits is List && rawEdits.isNotEmpty) {
      isMulti = true;
      edits = [];
      for (var i = 0; i < rawEdits.length; i++) {
        final item = rawEdits[i];
        if (item is! Map) {
          throw FormatException('Edit #${i + 1} must be an object.');
        }
        final oldStr = item['old_string']?.toString() ?? '';
        final newStr = item['new_string']?.toString() ?? '';
        final repAll = item['replace_all'] == true;
        if (oldStr.isEmpty) {
          throw FormatException('Edit #${i + 1}: old_string is required.');
        }
        if (oldStr == newStr) {
          throw StateError(
            'Edit #${i + 1}: No changes to apply: old_string and new_string are identical.',
          );
        }
        edits.add(
          _EditOperation(
            oldString: oldStr,
            newString: newStr,
            replaceAll: repAll,
            index: i + 1,
          ),
        );
      }
    } else if (oldString != null && newString != null) {
      isMulti = false;
      if (oldString.isEmpty) {
        throw const FormatException('old_string is required.');
      }
      if (oldString == newString) {
        throw StateError(
          'No changes to apply: oldString and newString are identical.',
        );
      }
      edits = [
        _EditOperation(
          oldString: oldString,
          newString: newString,
          replaceAll: replaceAll,
          index: 1,
        ),
      ];
    } else {
      throw const FormatException(
        'Either old_string and new_string, or edits list is required.',
      );
    }

    final workspaceRoot = await _pathResolver.normalizeWorkspaceRootAsync(
      workspacePath,
    );
    final resolvedPath = await _pathResolver.resolveExistingPathAsync(
      workspaceRoot: workspaceRoot,
      inputPath: path,
      authorizedExternalRoot: authorizedExternalRoot,
    );
    final file = File(resolvedPath);
    final originalFile = await file.readAsString();

    final hasCrLf = originalFile.contains('\r\n');
    final originalNormalized = originalFile.replaceAll('\r\n', '\n');

    final normalizedEdits = edits
        .map(
          (e) => _EditOperation(
            oldString: e.oldString.replaceAll('\r\n', '\n'),
            newString: e.newString.replaceAll('\r\n', '\n'),
            replaceAll: e.replaceAll,
            index: e.index,
          ),
        )
        .toList();

    final editResult = await _applyEditsAsync(
      originalNormalized,
      normalizedEdits,
      isMulti,
    );

    final updatedFile = hasCrLf
        ? editResult.content.replaceAll('\n', '\r\n')
        : editResult.content;

    await file.writeAsString(updatedFile);

    final patchBuffer = StringBuffer();
    for (var i = 0; i < normalizedEdits.length; i++) {
      final edit = normalizedEdits[i];
      if (i > 0) patchBuffer.writeln('---');
      for (final line in edit.oldString.split('\n')) {
        patchBuffer.writeln('- $line');
      }
      for (final line in edit.newString.split('\n')) {
        patchBuffer.writeln('+ $line');
      }
    }

    final firstEdit = edits.first;
    return WorkspaceToolsUtils.encode({
      'filePath': _pathResolver.relativeToWorkspace(
        workspaceRoot: workspaceRoot,
        resolvedPath: resolvedPath,
      ),
      'oldString': firstEdit.oldString.length > 100
          ? '${firstEdit.oldString.substring(0, 100)}...'
          : firstEdit.oldString,
      'newString': firstEdit.newString.length > 100
          ? '${firstEdit.newString.substring(0, 100)}...'
          : firstEdit.newString,
      'patch': patchBuffer.toString().trimRight(),
      'replaceAll': isMulti ? false : firstEdit.replaceAll,
      'numReplacements': editResult.totalReplacements,
      'startLine': editResult.startLine,
      if (isMulti) 'numEdits': edits.length,
    });
  }

  static Future<_MultiEditResult> _applyEditsAsync(
    String content,
    List<_EditOperation> edits,
    bool isMulti,
  ) async {
    if (content.length < 32768) {
      return _applyEdits(content, edits, isMulti);
    }

    return Isolate.run(
      () => _applyEdits(content, edits, isMulti),
    );
  }

  static _MultiEditResult _applyEdits(
    String content,
    List<_EditOperation> edits,
    bool isMulti,
  ) {
    final allMatches = <_MatchRange>[];

    for (final edit in edits) {
      final matches = _findMatchesForEdit(content, edit, isMulti);
      allMatches.addAll(matches);
    }

    // Overlap detection: sort by startIndex ascending
    allMatches.sort((a, b) => a.startIndex.compareTo(b.startIndex));

    for (var i = 0; i < allMatches.length - 1; i++) {
      final current = allMatches[i];
      final next = allMatches[i + 1];
      if (current.endIndex > next.startIndex) {
        throw StateError(
          'Overlapping edits detected in target file between '
          'edit #${current.editIndex} and edit #${next.editIndex}. '
          'Ensure all edits specify distinct, non-overlapping sections.',
        );
      }
    }

    // Apply from bottom to top (highest startIndex first)
    final sortedDescending = List<_MatchRange>.from(allMatches)
      ..sort((a, b) => b.startIndex.compareTo(a.startIndex));

    var updated = content;
    for (final match in sortedDescending) {
      updated = updated.substring(0, match.startIndex) +
          match.newString +
          updated.substring(match.endIndex);
    }

    final startLines = allMatches.map((m) => m.startLine).toList();
    final firstStartLine = startLines.isNotEmpty ? startLines.first : 1;

    return _MultiEditResult(
      content: updated,
      startLine: firstStartLine,
      startLines: startLines,
      totalReplacements: allMatches.length,
    );
  }

  static List<_MatchRange> _findMatchesForEdit(
    String content,
    _EditOperation edit,
    bool isMulti,
  ) {
    var notFound = true;
    final replacers = [
      _simpleReplacer,
      _lineTrimmedReplacer,
      _blockAnchorReplacer,
      _whitespaceNormalizedReplacer,
      _indentationFlexibleReplacer,
      _escapeNormalizedReplacer,
      _trimmedBoundaryReplacer,
      _contextAwareReplacer,
      _multiOccurrenceReplacer,
    ];

    for (final replacer in replacers) {
      final candidates = replacer(content, edit.oldString).toList();
      if (candidates.isEmpty) continue;

      for (final search in candidates) {
        final index = content.indexOf(search);
        if (index == -1) continue;
        notFound = false;

        if (edit.replaceAll) {
          final matches = <_MatchRange>[];
          var startIndex = 0;
          while (true) {
            final matchIndex = content.indexOf(search, startIndex);
            if (matchIndex == -1) break;
            final line =
                '\n'.allMatches(content.substring(0, matchIndex)).length + 1;
            matches.add(
              _MatchRange(
                startIndex: matchIndex,
                endIndex: matchIndex + search.length,
                matchedText: search,
                newString: edit.newString,
                startLine: line,
                editIndex: edit.index,
              ),
            );
            startIndex = matchIndex + search.length;
          }
          if (matches.isNotEmpty) {
            return matches;
          }
        }

        final lastIndex = content.lastIndexOf(search);
        if (index != lastIndex) continue;

        final line = '\n'.allMatches(content.substring(0, index)).length + 1;
        return [
          _MatchRange(
            startIndex: index,
            endIndex: index + search.length,
            matchedText: search,
            newString: edit.newString,
            startLine: line,
            editIndex: edit.index,
          ),
        ];
      }
    }

    final prefix = isMulti ? 'Edit #${edit.index}: ' : '';
    if (notFound) {
      throw StateError(
        '${prefix}old_string was not found in the target file. It must match exactly, including whitespace, indentation, and line endings.',
      );
    }
    throw StateError(
      '${prefix}Found multiple matches for old_string. Provide more surrounding context to make the match unique.',
    );
  }

  static Iterable<String> _simpleReplacer(String content, String find) sync* {
    yield find;
  }

  static Iterable<String> _lineTrimmedReplacer(
    String content,
    String find,
  ) sync* {
    final originalLines = content.split('\n');
    final searchLines = find.split('\n');
    if (searchLines.isNotEmpty && searchLines.last.isEmpty) {
      searchLines.removeLast();
    }
    if (searchLines.isEmpty) return;
    for (var i = 0; i <= originalLines.length - searchLines.length; i++) {
      var matches = true;
      for (var j = 0; j < searchLines.length; j++) {
        if (originalLines[i + j].trim() != searchLines[j].trim()) {
          matches = false;
          break;
        }
      }
      if (matches) {
        yield originalLines.sublist(i, i + searchLines.length).join('\n');
      }
    }
  }

  static Iterable<String> _blockAnchorReplacer(
    String content,
    String find,
  ) sync* {
    final originalLines = content.split('\n');
    final searchLines = find.split('\n');
    if (searchLines.length < 3) return;
    if (searchLines.isNotEmpty && searchLines.last.isEmpty) {
      searchLines.removeLast();
    }
    if (searchLines.isEmpty) return;

    final firstLineSearch = searchLines.first.trim();
    final lastLineSearch = searchLines.last.trim();
    final searchBlockSize = searchLines.length;

    final candidates = <_CandidatePosition>[];
    for (var i = 0; i < originalLines.length; i++) {
      if (originalLines[i].trim() != firstLineSearch) continue;
      for (var j = i + 2; j < originalLines.length; j++) {
        if (originalLines[j].trim() == lastLineSearch) {
          candidates.add(_CandidatePosition(i, j));
          break;
        }
      }
    }

    if (candidates.isEmpty) return;

    if (candidates.length == 1) {
      final cand = candidates.first;
      final actualBlockSize = cand.endLine - cand.startLine + 1;
      var similarity = 0.0;
      final linesToCheck = (searchBlockSize - 2) < (actualBlockSize - 2)
          ? (searchBlockSize - 2)
          : (actualBlockSize - 2);

      if (linesToCheck > 0) {
        for (
          var j = 1;
          j < searchBlockSize - 1 && j < actualBlockSize - 1;
          j++
        ) {
          final originalLine = originalLines[cand.startLine + j].trim();
          final searchLine = searchLines[j].trim();
          final maxLen = originalLine.length > searchLine.length
              ? originalLine.length
              : searchLine.length;
          if (maxLen == 0) continue;
          final distance = _levenshtein(originalLine, searchLine);
          similarity += (1.0 - distance / maxLen) / linesToCheck;
        }
      } else {
        similarity = 1.0;
      }
      if (similarity >= 0.0) {
        yield originalLines
            .sublist(cand.startLine, cand.endLine + 1)
            .join('\n');
      }
      return;
    }

    _CandidatePosition? bestMatch;
    var maxSimilarity = -1.0;

    for (final cand in candidates) {
      final actualBlockSize = cand.endLine - cand.startLine + 1;
      var similarity = 0.0;
      final linesToCheck = (searchBlockSize - 2) < (actualBlockSize - 2)
          ? (searchBlockSize - 2)
          : (actualBlockSize - 2);

      if (linesToCheck > 0) {
        for (
          var j = 1;
          j < searchBlockSize - 1 && j < actualBlockSize - 1;
          j++
        ) {
          final originalLine = originalLines[cand.startLine + j].trim();
          final searchLine = searchLines[j].trim();
          final maxLen = originalLine.length > searchLine.length
              ? originalLine.length
              : searchLine.length;
          if (maxLen == 0) continue;
          final distance = _levenshtein(originalLine, searchLine);
          similarity += (1.0 - distance / maxLen);
        }
        similarity /= linesToCheck;
      } else {
        similarity = 1.0;
      }
      if (similarity > maxSimilarity) {
        maxSimilarity = similarity;
        bestMatch = cand;
      }
    }
    if (maxSimilarity >= 0.3 && bestMatch != null) {
      yield originalLines
          .sublist(bestMatch.startLine, bestMatch.endLine + 1)
          .join('\n');
    }
  }

  static int _levenshtein(String a, String b) {
    if (a.isEmpty || b.isEmpty) {
      return a.length > b.length ? a.length : b.length;
    }
    final dp = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      dp[0][j] = j;
    }

    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce((curr, next) => curr < next ? curr : next);
      }
    }
    return dp[a.length][b.length];
  }

  static Iterable<String> _whitespaceNormalizedReplacer(
    String content,
    String find,
  ) sync* {
    String normalizeWhitespace(String text) =>
        text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final normalizedFind = normalizeWhitespace(find);
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (normalizeWhitespace(line) == normalizedFind) {
        yield line;
      } else {
        final normalizedLine = normalizeWhitespace(line);
        if (normalizedLine.contains(normalizedFind)) {
          final words = find.trim().split(RegExp(r'\s+'));
          if (words.isNotEmpty) {
            final pattern = words.map((w) => RegExp.escape(w)).join(r'\s+');
            try {
              final regex = RegExp(pattern);
              final match = regex.firstMatch(line);
              if (match != null) yield match.group(0)!;
            } catch (_) {}
          }
        }
      }
    }
    final findLines = find.split('\n');
    if (findLines.length > 1) {
      for (var i = 0; i <= lines.length - findLines.length; i++) {
        final block = lines.sublist(i, i + findLines.length);
        if (normalizeWhitespace(block.join('\n')) == normalizedFind) {
          yield block.join('\n');
        }
      }
    }
  }

  static Iterable<String> _indentationFlexibleReplacer(
    String content,
    String find,
  ) sync* {
    String removeIndentation(String text) {
      final lines = text.split('\n');
      final nonEmptyLines = lines.where((l) => l.trim().isNotEmpty).toList();
      if (nonEmptyLines.isEmpty) return text;
      int? minIndent;
      for (final line in nonEmptyLines) {
        final match = RegExp(r'^(\s*)').firstMatch(line);
        final indentLen = match != null ? match.group(1)!.length : 0;
        if (minIndent == null || indentLen < minIndent) {
          minIndent = indentLen;
        }
      }
      if (minIndent == null || minIndent == 0) return text;
      return lines
          .map((l) => l.trim().isEmpty ? l : l.substring(minIndent!))
          .join('\n');
    }

    final normalizedFind = removeIndentation(find);
    final contentLines = content.split('\n');
    final findLines = find.split('\n');
    for (var i = 0; i <= contentLines.length - findLines.length; i++) {
      final block = contentLines.sublist(i, i + findLines.length).join('\n');
      if (removeIndentation(block) == normalizedFind) yield block;
    }
  }

  static String _unescapeString(String str) {
    return str.replaceAllMapped(RegExp(r'\\(n|t|r|\x27|\x22|\x60|\\|\n|\$)'), (
      match,
    ) {
      final char = match.group(1);
      switch (char) {
        case 'n':
          return '\n';
        case 't':
          return '\t';
        case 'r':
          return '\r';
        case "'":
          return "'";
        case '"':
          return '"';
        case '`':
          return '`';
        case '\\':
          return '\\';
        case '\n':
          return '\n';
        case r'$':
          return r'$';
        default:
          return match.group(0)!;
      }
    });
  }

  static Iterable<String> _escapeNormalizedReplacer(
    String content,
    String find,
  ) sync* {
    final unescapedFind = _unescapeString(find);
    if (content.contains(unescapedFind)) yield unescapedFind;
    final lines = content.split('\n');
    final findLines = unescapedFind.split('\n');
    for (var i = 0; i <= lines.length - findLines.length; i++) {
      final block = lines.sublist(i, i + findLines.length).join('\n');
      if (_unescapeString(block) == unescapedFind) yield block;
    }
  }

  static Iterable<String> _trimmedBoundaryReplacer(
    String content,
    String find,
  ) sync* {
    final trimmedFind = find.trim();
    if (trimmedFind == find) return;
    if (content.contains(trimmedFind)) yield trimmedFind;
    final lines = content.split('\n');
    final findLines = find.split('\n');
    for (var i = 0; i <= lines.length - findLines.length; i++) {
      final block = lines.sublist(i, i + findLines.length).join('\n');
      if (block.trim() == trimmedFind) yield block;
    }
  }

  static Iterable<String> _contextAwareReplacer(
    String content,
    String find,
  ) sync* {
    final findLines = find.split('\n');
    if (findLines.length < 3) return;
    if (findLines.isNotEmpty && findLines.last.isEmpty) findLines.removeLast();
    final contentLines = content.split('\n');
    final firstLine = findLines.first.trim();
    final lastLine = findLines.last.trim();

    for (var i = 0; i < contentLines.length; i++) {
      if (contentLines[i].trim() != firstLine) continue;
      for (var j = i + 2; j < contentLines.length; j++) {
        if (contentLines[j].trim() == lastLine) {
          final blockLines = contentLines.sublist(i, j + 1);
          if (blockLines.length == findLines.length) {
            var matchingLines = 0;
            var totalNonEmptyLines = 0;
            for (var k = 1; k < blockLines.length - 1; k++) {
              final blockLine = blockLines[k].trim();
              final findLine = findLines[k].trim();
              if (blockLine.isNotEmpty || findLine.isNotEmpty) {
                totalNonEmptyLines++;
                if (blockLine == findLine) matchingLines++;
              }
            }
            if (totalNonEmptyLines == 0 ||
                (matchingLines / totalNonEmptyLines) >= 0.5) {
              yield blockLines.join('\n');
              break;
            }
          }
          break;
        }
      }
    }
  }

  static Iterable<String> _multiOccurrenceReplacer(
    String content,
    String find,
  ) sync* {
    var startIndex = 0;
    while (true) {
      final index = content.indexOf(find, startIndex);
      if (index == -1) break;
      yield find;
      startIndex = index + find.length;
    }
  }
}

class _CandidatePosition {
  final int startLine;
  final int endLine;
  _CandidatePosition(this.startLine, this.endLine);
}

class _EditOperation {
  final String oldString;
  final String newString;
  final bool replaceAll;
  final int index;

  const _EditOperation({
    required this.oldString,
    required this.newString,
    this.replaceAll = false,
    this.index = 1,
  });
}

class _MatchRange {
  final int startIndex;
  final int endIndex;
  final String matchedText;
  final String newString;
  final int startLine;
  final int editIndex;

  const _MatchRange({
    required this.startIndex,
    required this.endIndex,
    required this.matchedText,
    required this.newString,
    required this.startLine,
    required this.editIndex,
  });
}

class _MultiEditResult {
  final String content;
  final int startLine;
  final List<int> startLines;
  final int totalReplacements;

  _MultiEditResult({
    required this.content,
    required this.startLine,
    this.startLines = const [],
    required this.totalReplacements,
  });
}
