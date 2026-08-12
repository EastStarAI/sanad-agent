import 'dart:io';
import '../workspace_path_resolver.dart';
import 'workspace_tools_utils.dart';

class SearchGlobHandler {
  static const int _maxSearchResults = 500;
  final WorkspacePathResolver _pathResolver;

  const SearchGlobHandler(this._pathResolver);

  Future<String> execute(
    Map<String, dynamic> arguments,
    String workspacePath, {
    String? authorizedExternalRoot,
  }) async {
    final pattern = arguments['pattern']?.toString() ?? '';
    if (pattern.trim().isEmpty) {
      throw const FormatException('pattern is required.');
    }

    final workspaceRoot = _pathResolver.normalizeWorkspaceRoot(workspacePath);
    final searchRoot = _resolveSearchRoot(
      workspaceRoot: workspaceRoot,
      pathArgument: arguments['path']?.toString(),
      authorizedExternalRoot: authorizedExternalRoot,
    );
    final filenames = <String>[];
    var truncated = false;
    final stopwatch = Stopwatch()..start();

    await for (final entity in WorkspaceToolsUtils.listWorkspaceFiles(
      searchRoot,
    )) {
      final relative = _pathResolver.relativeToWorkspace(
        workspaceRoot: workspaceRoot,
        resolvedPath: entity.path,
      );
      final normalizedRelative = relative.replaceAll('\\', '/');

      final patterns = WorkspaceToolsUtils.expandBraces(pattern);
      var matched = false;
      for (final expanded in patterns) {
        if (WorkspaceToolsUtils.globToRegExp(
          expanded,
        ).hasMatch(normalizedRelative)) {
          matched = true;
          break;
        }
      }

      if (matched) {
        filenames.add(normalizedRelative);
      }
    }

    final fileStats = <String, DateTime>{};
    for (final relative in filenames) {
      final absolute = _pathResolver.resolveExistingPath(
        workspaceRoot: workspaceRoot,
        inputPath: relative,
        authorizedExternalRoot: authorizedExternalRoot,
      );
      fileStats[relative] = File(absolute).statSync().modified;
    }
    filenames.sort((a, b) => fileStats[b]!.compareTo(fileStats[a]!));

    if (filenames.length > _maxSearchResults) {
      filenames.removeRange(_maxSearchResults, filenames.length);
      truncated = true;
    }

    stopwatch.stop();
    return WorkspaceToolsUtils.encode({
      'durationMs': stopwatch.elapsedMilliseconds,
      'numFiles': filenames.length,
      'filenames': filenames,
      'truncated': truncated,
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
