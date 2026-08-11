import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../workspace_path_resolver.dart';
import 'workspace_tools_utils.dart';

class FileReadHandler {
  static const int _maxReadBytes = 10 * 1024 * 1024;
  static const int _maxLines = 2000;
  static const int _maxLineChars = 2000;
  static const int _maxOutputChars = 50000;
  final WorkspacePathResolver _pathResolver;

  const FileReadHandler(this._pathResolver);

  Future<String> execute(
    Map<String, dynamic> arguments,
    String workspacePath, {
    String? authorizedExternalRoot,
  }) async {
    final path = arguments['path']?.toString() ?? '';
    final offset =
        WorkspaceToolsUtils.asNonNegativeInt(arguments['offset']) ?? 0;
    final limit = WorkspaceToolsUtils.asPositiveInt(arguments['limit']);

    final workspaceRoot = _pathResolver.normalizeWorkspaceRoot(workspacePath);
    final resolvedPath = _pathResolver.resolveExistingPath(
      workspaceRoot: workspaceRoot,
      inputPath: path,
      authorizedExternalRoot: authorizedExternalRoot,
    );

    if (FileSystemEntity.isDirectorySync(resolvedPath)) {
      return _handleDirectory(resolvedPath, workspaceRoot, offset, limit);
    }

    return _handleFile(resolvedPath, workspaceRoot, offset, limit);
  }

  Future<String> _handleDirectory(
    String resolvedPath,
    String workspaceRoot,
    int offset,
    int? limit,
  ) async {
    final dir = Directory(resolvedPath);
    final list = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (const {
        '.git',
        'node_modules',
        '.dart_tool',
        '.fvm',
        'build',
      }.contains(name)) {
        continue;
      }
      if (entity is Directory) {
        list.add('$name/');
      } else if (entity is Link) {
        try {
          final targetType = FileSystemEntity.typeSync(
            entity.path,
            followLinks: true,
          );
          if (targetType == FileSystemEntityType.directory) {
            list.add('$name/');
          } else {
            list.add(name);
          }
        } catch (_) {
          list.add(name);
        }
      } else {
        list.add(name);
      }
    }
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final start = offset.clamp(0, list.length);
    final maxLimit = (limit ?? _maxLines).clamp(1, _maxLines);
    final end = (start + maxLimit).clamp(0, list.length);
    final sliced = list.sublist(start, end);
    final truncated = start + sliced.length < list.length;

    final relativePath = _pathResolver.relativeToWorkspace(
      workspaceRoot: workspaceRoot,
      resolvedPath: resolvedPath,
    );

    final buffer = StringBuffer();
    buffer.writeln('<path>$relativePath</path>');
    buffer.writeln('<type>directory</type>');
    buffer.writeln('<entries>');
    buffer.write(sliced.join('\n'));
    if (truncated) {
      buffer.write(
        '\n(Showing ${sliced.length} of ${list.length} entries. Use \'offset\' parameter to read beyond entry ${offset + sliced.length})',
      );
    } else {
      buffer.write('\n(${list.length} entries)');
    }
    buffer.writeln('\n</entries>');

    return WorkspaceToolsUtils.encode({
      'type': 'directory',
      'file': {
        'filePath': relativePath,
        'content': buffer.toString(),
        'numEntries': sliced.length,
        'totalEntries': list.length,
      },
    });
  }

  Future<String> _handleFile(
    String resolvedPath,
    String workspaceRoot,
    int offset,
    int? limit,
  ) async {
    final file = File(resolvedPath);
    final metadata = await file.stat();
    if (metadata.size > _maxReadBytes) {
      throw FileSystemException(
        'File is too large to read safely (${metadata.size} bytes).',
        resolvedPath,
      );
    }

    if (await WorkspaceToolsUtils.looksBinary(file)) {
      throw FileSystemException('File appears to be binary.', resolvedPath);
    }

    final content = await file.readAsString();
    final lines = const LineSplitter().convert(content);
    final startIndex = offset.clamp(0, lines.length);
    final pageLimit = (limit ?? _maxLines).clamp(1, _maxLines);
    final requestedEnd = (startIndex + pageLimit).clamp(0, lines.length);
    final selectedLines = <String>[];
    var selectedChars = 0;
    for (var index = startIndex; index < requestedEnd; index++) {
      final line = lines[index];
      final boundedLine = line.length > _maxLineChars
          ? '${line.substring(0, _maxLineChars)}... (line truncated to $_maxLineChars chars)'
          : line;
      final addedChars = boundedLine.length + (selectedLines.isEmpty ? 0 : 1);
      if (selectedChars + addedChars > _maxOutputChars) {
        break;
      }
      selectedLines.add(boundedLine);
      selectedChars += addedChars;
    }
    final endIndex = startIndex + selectedLines.length;
    final truncated = endIndex < lines.length;

    return WorkspaceToolsUtils.encode({
      'type': 'text',
      'file': {
        'filePath': _pathResolver.relativeToWorkspace(
          workspaceRoot: workspaceRoot,
          resolvedPath: resolvedPath,
        ),
        'content': selectedLines.join('\n'),
        'numLines': selectedLines.length,
        'startLine': startIndex + 1,
        'totalLines': lines.length,
        'truncated': truncated,
        if (truncated) 'nextOffset': endIndex,
      },
    });
  }
}
