import 'dart:convert';
import 'dart:io';
import '../workspace_path_resolver.dart';
import 'workspace_tools_utils.dart';

class SearchGrepHandler {
  static const int _maxReadBytes = 10 * 1024 * 1024;
  static const int _maxHeadLimit = 100;
  static const int _maxContextLines = 20;
  static const int _maxLineChars = 2000;
  static const int _maxOutputChars = 50000;
  final WorkspacePathResolver _pathResolver;

  const SearchGrepHandler(this._pathResolver);

  Future<String> execute(
    Map<String, dynamic> arguments,
    String workspacePath, {
    String? authorizedExternalRoot,
  }) async {
    var pattern = arguments['pattern']?.toString() ?? '';
    if (pattern.trim().isEmpty) {
      throw const FormatException('pattern is required.');
    }

    // Normalize pattern for grep → Dart RegExp compatibility.
    //
    // grep BRE uses \| for alternation, but Dart RegExp (ECMAScript) uses bare |.
    // \| in Dart RegExp means a *literal* pipe character, which is the opposite
    // of what a grep user expects. Convert \| → | before anything else.
    pattern = pattern.replaceAll(r'\|', '|');
    // Remove extraneous whitespace around regex operators: "a | b" → "a|b"
    pattern = pattern.replaceAll(RegExp(r'\s*\|\s*'), '|');
    // Collapse duplicate pipes: "||" → "|"
    pattern = pattern.replaceAll('||', '|');
    // Trim overall
    pattern = pattern.trim();

    final workspaceRoot = _pathResolver.normalizeWorkspaceRoot(workspacePath);
    final searchRoot = _resolveSearchRoot(
      workspaceRoot: workspaceRoot,
      pathArgument: arguments['path']?.toString(),
      authorizedExternalRoot: authorizedExternalRoot,
    );
    final fileGlob = arguments['glob']?.toString();
    final fileGlobRegexes = fileGlob == null || fileGlob.trim().isEmpty
        ? const <RegExp>[]
        : WorkspaceToolsUtils.expandBraces(
            fileGlob.trim(),
          ).map(WorkspaceToolsUtils.globToRegExp).toList(growable: false);
    final caseInsensitive =
        arguments['case_insensitive'] == true || arguments['-i'] == true;
    final includeLineNumbers =
        arguments['line_numbers'] == true || arguments['-n'] == true;
    final requestedHeadLimit =
        WorkspaceToolsUtils.asPositiveInt(arguments['head_limit']) ??
        _maxHeadLimit;
    final headLimit = requestedHeadLimit.clamp(1, _maxHeadLimit);
    final offset =
        WorkspaceToolsUtils.asNonNegativeInt(arguments['offset']) ?? 0;
    final before =
        WorkspaceToolsUtils.asNonNegativeInt(arguments['before']) ??
        WorkspaceToolsUtils.asNonNegativeInt(arguments['-B']) ??
        0;
    final after =
        WorkspaceToolsUtils.asNonNegativeInt(arguments['after']) ??
        WorkspaceToolsUtils.asNonNegativeInt(arguments['-A']) ??
        0;
    final context =
        WorkspaceToolsUtils.asNonNegativeInt(arguments['context']) ??
        WorkspaceToolsUtils.asNonNegativeInt(arguments['-C']) ??
        0;
    final effectiveBefore = (before > 0 ? before : context).clamp(
      0,
      _maxContextLines,
    );
    final effectiveAfter = (after > 0 ? after : context).clamp(
      0,
      _maxContextLines,
    );

    RegExp regex;
    try {
      regex = RegExp(
        pattern,
        caseSensitive: !caseInsensitive,
        multiLine: true,
        dotAll: false, // Ensure . does not match newlines
      );
    } on FormatException {
      regex = RegExp(
        RegExp.escape(pattern),
        caseSensitive: !caseInsensitive,
        multiLine: true,
        dotAll: false,
      );
    }
    final filenames = <String>{};
    final contentLines = <String>[];
    var contentChars = 0;
    var totalMatches = 0;
    var skippedMatches = 0;
    final filesToSearch = <File>[];

    if (FileSystemEntity.typeSync(searchRoot) == FileSystemEntityType.file) {
      filesToSearch.add(File(searchRoot));
    } else {
      await for (final entity in WorkspaceToolsUtils.listWorkspaceFiles(
        searchRoot,
      )) {
        final relative = _pathResolver.relativeToWorkspace(
          workspaceRoot: workspaceRoot,
          resolvedPath: entity.path,
        );
        final normalizedRelative = relative.replaceAll('\\', '/');
        final basename = normalizedRelative.split('/').last;
        if (fileGlobRegexes.isNotEmpty &&
            !fileGlobRegexes.any(
              (glob) =>
                  glob.hasMatch(normalizedRelative) || glob.hasMatch(basename),
            )) {
          continue;
        }
        filesToSearch.add(entity);
      }
    }

    // Sort alphabetically, matching grep behavior (not by modification time)
    filesToSearch.sort((a, b) => a.path.compareTo(b.path));

    for (final entity in filesToSearch) {
      final relative = _pathResolver.relativeToWorkspace(
        workspaceRoot: workspaceRoot,
        resolvedPath: entity.path,
      );
      final normalizedRelative = relative.replaceAll('\\', '/');

      final stat = await entity.stat();
      if (stat.size > _maxReadBytes ||
          await WorkspaceToolsUtils.looksBinary(entity)) {
        continue;
      }

      String fileContent;
      try {
        fileContent = await entity.readAsString();
      } catch (_) {
        // File contains non-UTF-8 bytes (e.g. binary files that passed
        // looksBinary). Skip silently.
        continue;
      }
      final lines = const LineSplitter().convert(fileContent);
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        final matches = regex.allMatches(line).toList();
        if (matches.isEmpty) {
          continue;
        }
        totalMatches += matches.length;
        if (skippedMatches < offset) {
          skippedMatches++;
          continue;
        }
        filenames.add(normalizedRelative);

        final start = (index - effectiveBefore).clamp(0, lines.length);
        final end = (index + effectiveAfter + 1).clamp(0, lines.length);
        for (var i = start; i < end; i++) {
          final isMatch = i == index;
          final separator = isMatch ? ':' : '-';
          final prefix = includeLineNumbers
              ? '$normalizedRelative:${i + 1}$separator'
              : '$normalizedRelative$separator';
          final sourceLine = lines[i];
          final boundedLine = sourceLine.length > _maxLineChars
              ? '${sourceLine.substring(0, _maxLineChars)}... (line truncated to $_maxLineChars chars)'
              : sourceLine;
          final formattedLine = '$prefix$boundedLine';
          if (contentChars + formattedLine.length > _maxOutputChars) {
            return _encodeResult(
              filenames: filenames,
              contentLines: contentLines,
              offset: offset,
              totalMatches: totalMatches,
              truncated: true,
              truncationReason: 'max_output_chars',
            );
          }
          contentLines.add(formattedLine);
          contentChars += formattedLine.length;
        }

        if (contentLines.length >= headLimit) {
          return _encodeResult(
            filenames: filenames,
            contentLines: contentLines.take(headLimit).toList(growable: false),
            offset: offset,
            totalMatches: totalMatches,
            truncated: true,
            truncationReason: 'head_limit',
          );
        }
      }
    }

    return _encodeResult(
      filenames: filenames,
      contentLines: contentLines,
      offset: offset,
      totalMatches: totalMatches,
      truncated: false,
    );
  }

  String _encodeResult({
    required Set<String> filenames,
    required List<String> contentLines,
    required int offset,
    required int totalMatches,
    required bool truncated,
    String? truncationReason,
  }) {
    return WorkspaceToolsUtils.encode({
      'numFiles': filenames.length,
      'filenames': filenames.toList(growable: false),
      'content': contentLines,
      'numLines': contentLines.length,
      'appliedOffset': offset,
      'totalMatches': totalMatches,
      'truncated': truncated,
      'truncationReason': ?truncationReason,
    });
  }

  String _resolveSearchRoot({
    required String workspaceRoot,
    required String? pathArgument,
    required String? authorizedExternalRoot,
  }) {
    if (pathArgument == null ||
        pathArgument.trim().isEmpty ||
        pathArgument.trim() == '.') {
      return workspaceRoot;
    }
    return _pathResolver.resolveExistingPath(
      workspaceRoot: workspaceRoot,
      inputPath: pathArgument,
      authorizedExternalRoot: authorizedExternalRoot,
    );
  }
}
