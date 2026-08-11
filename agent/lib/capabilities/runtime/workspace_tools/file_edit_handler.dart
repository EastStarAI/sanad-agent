import 'dart:io';
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
    final oldString = arguments['old_string']?.toString() ?? '';
    final newString = arguments['new_string']?.toString() ?? '';
    final replaceAll = arguments['replace_all'] == true;
    if (oldString.isEmpty) {
      throw const FormatException('old_string is required.');
    }

    final workspaceRoot = _pathResolver.normalizeWorkspaceRoot(workspacePath);
    final resolvedPath = _pathResolver.resolveExistingPath(
      workspaceRoot: workspaceRoot,
      inputPath: path,
      authorizedExternalRoot: authorizedExternalRoot,
    );
    final file = File(resolvedPath);
    final originalFile = await file.readAsString();

    final hasCrLf = originalFile.contains('\r\n');
    final originalNormalized = originalFile.replaceAll('\r\n', '\n');
    final oldNormalized = oldString.replaceAll('\r\n', '\n');
    final newNormalized = newString.replaceAll('\r\n', '\n');

    final editResult = _smartReplace(
      originalNormalized,
      oldNormalized,
      newNormalized,
      replaceAll,
    );

    final updatedFile = hasCrLf
        ? editResult.content.replaceAll('\n', '\r\n')
        : editResult.content;

    await file.writeAsString(updatedFile);

    var matches = oldNormalized.allMatches(originalNormalized).length;
    if (matches == 0) matches = 1;

    final patchBuffer = StringBuffer();

    for (final line in oldNormalized.split('\n')) {
      patchBuffer.writeln('- $line');
    }
    for (final line in newNormalized.split('\n')) {
      patchBuffer.writeln('+ $line');
    }

    return WorkspaceToolsUtils.encode({
      'filePath': _pathResolver.relativeToWorkspace(
        workspaceRoot: workspaceRoot,
        resolvedPath: resolvedPath,
      ),
      'oldString': oldString.length > 100
          ? '${oldString.substring(0, 100)}...'
          : oldString,
      'newString': newString.length > 100
          ? '${newString.substring(0, 100)}...'
          : newString,
      'patch': patchBuffer.toString().trimRight(),
      'replaceAll': replaceAll,
      'numReplacements': replaceAll ? matches : 1,
      'startLine': editResult.startLine,
    });
  }

  _EditResult _smartReplace(
    String content,
    String oldString,
    String newString,
    bool replaceAll,
  ) {
    if (oldString == newString) {
      throw StateError(
        'No changes to apply: oldString and newString are identical.',
      );
    }

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
      final candidates = replacer(content, oldString).toList();
      if (candidates.isEmpty) continue;

      for (final search in candidates) {
        final index = content.indexOf(search);
        if (index == -1) continue;
        notFound = false;

        final startLine =
            '\n'.allMatches(content.substring(0, index)).length + 1;

        if (replaceAll) {
          final startLines = <int>[];
          var startIndex = 0;
          while (true) {
            final matchIndex = content.indexOf(search, startIndex);
            if (matchIndex == -1) break;
            final line =
                '\n'.allMatches(content.substring(0, matchIndex)).length + 1;
            startLines.add(line);
            startIndex = matchIndex + search.length;
          }
          return _EditResult(
            content.replaceAll(search, newString),
            startLines.isNotEmpty ? startLines.first : startLine,
            startLines: startLines,
          );
        }

        final lastIndex = content.lastIndexOf(search);
        if (index != lastIndex) continue;

        final updated =
            content.substring(0, index) +
            newString +
            content.substring(index + search.length);
        return _EditResult(updated, startLine);
      }
    }

    if (notFound) {
      throw StateError(
        'old_string was not found in the target file. It must match exactly, including whitespace, indentation, and line endings.',
      );
    }
    throw StateError(
      'Found multiple matches for old_string. Provide more surrounding context to make the match unique.',
    );
  }

  Iterable<String> _simpleReplacer(String content, String find) sync* {
    yield find;
  }

  Iterable<String> _lineTrimmedReplacer(String content, String find) sync* {
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

  Iterable<String> _blockAnchorReplacer(String content, String find) sync* {
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

  int _levenshtein(String a, String b) {
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

  Iterable<String> _whitespaceNormalizedReplacer(
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

  Iterable<String> _indentationFlexibleReplacer(
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

  String _unescapeString(String str) {
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

  Iterable<String> _escapeNormalizedReplacer(
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

  Iterable<String> _trimmedBoundaryReplacer(String content, String find) sync* {
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

  Iterable<String> _contextAwareReplacer(String content, String find) sync* {
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

  Iterable<String> _multiOccurrenceReplacer(String content, String find) sync* {
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

class _EditResult {
  final String content;
  final int startLine;
  final List<int> startLines;
  _EditResult(this.content, this.startLine, {this.startLines = const []});
}
