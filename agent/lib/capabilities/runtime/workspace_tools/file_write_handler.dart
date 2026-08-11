import 'dart:convert';
import 'dart:io';
import '../workspace_path_resolver.dart';
import 'workspace_tools_utils.dart';

class FileWriteHandler {
  static const int _maxWriteBytes = 10 * 1024 * 1024;
  final WorkspacePathResolver _pathResolver;

  const FileWriteHandler(this._pathResolver);

  Future<String> execute(
    Map<String, dynamic> arguments,
    String workspacePath, {
    String? authorizedExternalRoot,
  }) async {
    final path = arguments['path']?.toString() ?? '';
    final content = arguments['content']?.toString() ?? '';
    if (utf8.encode(content).length > _maxWriteBytes) {
      throw const FileSystemException('Content is too large to write safely.');
    }

    final workspaceRoot = _pathResolver.normalizeWorkspaceRoot(workspacePath);
    final resolvedPath = _pathResolver.resolvePathAllowMissing(
      workspaceRoot: workspaceRoot,
      inputPath: path,
      authorizedExternalRoot: authorizedExternalRoot,
    );
    final file = File(resolvedPath);
    final exists = await file.exists();
    String? patch;
    if (exists) {
      try {
        final original = await file.readAsString();
        patch = _generateSimpleDiff(original, content);
      } catch (_) {}
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(content);

    final payload = <String, dynamic>{
      'type': exists ? 'update' : 'create',
      'filePath': _pathResolver.relativeToWorkspace(
        workspaceRoot: workspaceRoot,
        resolvedPath: resolvedPath,
      ),
      'contentLength': content.length,
    };
    if (patch != null) {
      payload['patch'] = patch;
    }
    return WorkspaceToolsUtils.encode(payload);
  }

  String _generateSimpleDiff(String original, String updated) {
    final originalLines = const LineSplitter().convert(original);
    final updatedLines = const LineSplitter().convert(updated);
    final buffer = StringBuffer();

    final maxLength = originalLines.length > updatedLines.length
        ? originalLines.length
        : updatedLines.length;
    for (var index = 0; index < maxLength; index++) {
      final oldLine = index < originalLines.length
          ? originalLines[index]
          : null;
      final newLine = index < updatedLines.length ? updatedLines[index] : null;
      if (oldLine == newLine) continue;
      if (oldLine != null) buffer.writeln('- $oldLine');
      if (newLine != null) buffer.writeln('+ $newLine');
    }

    return buffer.toString().trimRight();
  }
}
