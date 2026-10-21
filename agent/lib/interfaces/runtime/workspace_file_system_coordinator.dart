import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_boundary.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Owns workspace file-system work for [LocalWorkspaceRuntimeService]:
/// directory tree browsing, folder creation, rename, delete preview and
/// delete, path confinement for managed remote access, the managed workspaces
/// root, confirmation fingerprints, and the single serialized mutation queue.
///
/// Workspace records stay with the host; this coordinator reads them through
/// the injected lookups only.
class WorkspaceFileSystemCoordinator {
  WorkspaceFileSystemCoordinator({
    required String Function() getSanadHome,
    required Map<String, dynamic>? Function(String workspaceId)
    getWorkspaceRecordById,
    required Future<String?> Function(String workspaceId)
    resolveWorkspacePathById,
    required Future<List<Map<String, dynamic>>> Function() readStoredWorkspaces,
  }) : _getSanadHome = getSanadHome,
       _getWorkspaceRecordById = getWorkspaceRecordById,
       _resolveWorkspacePathById = resolveWorkspacePathById,
       _readStoredWorkspaces = readStoredWorkspaces;

  final String Function() _getSanadHome;
  final Map<String, dynamic>? Function(String workspaceId)
  _getWorkspaceRecordById;
  final Future<String?> Function(String workspaceId) _resolveWorkspacePathById;
  final Future<List<Map<String, dynamic>>> Function() _readStoredWorkspaces;

  Future<void> _mutationTail = Future<void>.value();

  /// Completes when every previously accepted filesystem mutation has settled.
  ///
  /// Callers that are about to release the databases and runtime managers this
  /// coordinator writes through must await this before disposing them.
  Future<void> drainMutations() => _mutationTail;

  String get _sanadHome => _getSanadHome();

  /// Runs [operation] on the serialized workspace mutation queue.
  Future<T> serialized<T>(Future<T> Function() operation) =>
      _serialized(operation);

  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
    bool managedRemote = false,
  }) async {
    final trimmedPath = path?.trim();
    if (trimmedPath == null || trimmedPath.isEmpty) {
      if (workspaceId != null && workspaceId.trim().isNotEmpty) {
        final workspace = _getWorkspaceRecordById(workspaceId);
        final resolvedWorkspacePath = await _resolveWorkspacePathById(
          workspaceId,
        );
        if (workspace == null || resolvedWorkspacePath == null) {
          throw StateError('Workspace not found or its folder is unavailable.');
        }
        if (managedRemote) {
          await _assertAllowedRemotePath(resolvedWorkspacePath);
        }
        return _buildDirectorySnapshot(
          directory: Directory(resolvedWorkspacePath),
          workspaceId: workspace['id'] as String,
          rootPath: resolvedWorkspacePath,
          path: resolvedWorkspacePath,
          parentPath: null,
          maxEntries: maxEntries,
          hideInternal: managedRemote,
        );
      }
      if (managedRemote) {
        return _browseAllowedRemoteRoots(maxEntries: maxEntries);
      }
      return _browseSystemRoots(maxEntries: maxEntries);
    }

    _rejectUnsafePathString(trimmedPath);
    final requestedPath = normalizePath(trimmedPath);
    var workspacePath = '';
    var rootPath = _rootPathFor(requestedPath);
    var parentPath = _parentPathFor(requestedPath, rootPath: rootPath);

    if (managedRemote) {
      await _assertAllowedRemotePath(requestedPath);
      final allowedRoot = await _containingAllowedRoot(requestedPath);
      rootPath = allowedRoot ?? requestedPath;
      parentPath = requestedPath == rootPath
          ? null
          : _parentPathFor(requestedPath, rootPath: rootPath);
    }

    if (workspaceId != null && workspaceId.trim().isNotEmpty) {
      final workspace = _getWorkspaceRecordById(workspaceId);
      final resolvedWorkspacePath = await _resolveWorkspacePathById(
        workspaceId,
      );
      if (workspace == null || resolvedWorkspacePath == null) {
        throw StateError('Workspace not found or its folder is unavailable.');
      }
      if (!_isWithinRoot(root: resolvedWorkspacePath, target: requestedPath)) {
        throw StateError('Requested path is outside the selected workspace.');
      }
      workspacePath = workspace['id'] as String;
      rootPath = resolvedWorkspacePath;
      parentPath = _parentPathFor(
        requestedPath,
        rootPath: resolvedWorkspacePath,
      );
    }

    final directory = Directory(requestedPath);
    if (!await directory.exists()) {
      throw StateError('Requested directory does not exist.');
    }

    return _buildDirectorySnapshot(
      directory: directory,
      workspaceId: workspacePath,
      rootPath: rootPath,
      path: requestedPath,
      parentPath: parentPath,
      maxEntries: maxEntries,
      hideInternal: managedRemote,
    );
  }

  Future<Map<String, dynamic>> _browseSystemRoots({
    required int maxEntries,
  }) async {
    if (Platform.isWindows) {
      final roots = await _listWindowsRoots();
      return {
        'workspace_id': '',
        'root_path': '',
        'path': '',
        'parent_path': null,
        'entries': roots.take(maxEntries).toList(growable: false),
        'truncated': roots.length > maxEntries,
      };
    }

    return _buildDirectorySnapshot(
      directory: Directory(Platform.pathSeparator),
      workspaceId: '',
      rootPath: Platform.pathSeparator,
      path: Platform.pathSeparator,
      parentPath: null,
      maxEntries: maxEntries,
    );
  }

  Future<Map<String, dynamic>> _buildDirectorySnapshot({
    required Directory directory,
    required String workspaceId,
    required String rootPath,
    required String path,
    required String? parentPath,
    required int maxEntries,
    bool hideInternal = false,
  }) async {
    final entities = <FileSystemEntity>[];
    await for (final entity in directory.list(followLinks: false)) {
      entities.add(entity);
    }
    entities.sort((left, right) {
      final leftDir = left is Directory ? 0 : 1;
      final rightDir = right is Directory ? 0 : 1;
      if (leftDir != rightDir) {
        return leftDir.compareTo(rightDir);
      }
      return p
          .basename(left.path)
          .toLowerCase()
          .compareTo(p.basename(right.path).toLowerCase());
    });

    final items = <Map<String, dynamic>>[];
    for (final entity in entities.take(maxEntries)) {
      final entry = await _buildTreeEntry(entity, rootPath: rootPath);
      if (entry == null) {
        continue;
      }
      if (hideInternal && _isSanadInternalHidden(entry['path'] as String)) {
        continue;
      }
      items.add(entry);
    }

    return {
      'workspace_id': workspaceId,
      'root_path': rootPath,
      'path': path,
      'parent_path': parentPath,
      'entries': items,
      'truncated': entities.length > maxEntries,
    };
  }

  Future<Map<String, dynamic>?> _buildTreeEntry(
    FileSystemEntity entity, {
    required String rootPath,
  }) async {
    try {
      final stat = await entity.stat();
      final entityPath = normalizePath(entity.path);
      return {
        'name': _entryDisplayName(entityPath),
        'path': entityPath,
        'relative_path': _relativePathFor(entityPath, rootPath: rootPath),
        'type': entity is Directory ? 'directory' : 'file',
        'size': stat.size,
        'modified_at': stat.modified.toIso8601String(),
      };
    } on FileSystemException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _listWindowsRoots() async {
    final roots = <Map<String, dynamic>>[];
    for (var codeUnit = 65; codeUnit <= 90; codeUnit++) {
      final drivePath = '${String.fromCharCode(codeUnit)}:\\';
      final directory = Directory(drivePath);
      if (!await directory.exists()) {
        continue;
      }
      final entry = await _buildTreeEntry(directory, rootPath: '');
      if (entry != null) {
        roots.add(entry);
      }
    }
    return roots;
  }

  String _rootPathFor(String targetPath) {
    if (Platform.isWindows) {
      return p.rootPrefix(targetPath);
    }
    return Platform.pathSeparator;
  }

  String? _parentPathFor(String targetPath, {required String rootPath}) {
    final normalizedTarget = normalizePath(targetPath);
    if (rootPath.isNotEmpty) {
      final normalizedRoot = normalizePath(rootPath);
      if (normalizedTarget == normalizedRoot) {
        return null;
      }

      final parentPath = normalizePath(Directory(normalizedTarget).parent.path);
      if (parentPath == normalizedTarget) {
        return null;
      }
      if (parentPath == normalizedRoot) {
        return normalizedRoot;
      }
      return _isWithinRoot(root: normalizedRoot, target: parentPath)
          ? parentPath
          : normalizedRoot;
    }

    final parentPath = normalizePath(Directory(normalizedTarget).parent.path);
    return parentPath == normalizedTarget ? null : '';
  }

  String _relativePathFor(String entityPath, {required String rootPath}) {
    if (rootPath.isEmpty) {
      return entityPath;
    }
    return p.relative(entityPath, from: rootPath);
  }

  String _entryDisplayName(String entityPath) {
    final basename = p.basename(entityPath);
    if (basename.isNotEmpty) {
      return basename;
    }
    return entityPath;
  }

  bool _isWithinRoot({required String root, required String target}) {
    final normalizedRoot = normalizePath(root);
    final normalizedTarget = normalizePath(target);
    return normalizedTarget == normalizedRoot ||
        p.isWithin(normalizedRoot, normalizedTarget);
  }

  Future<String> createFolder({
    required String parentPath,
    required String name,
    bool managedRemote = false,
  }) async {
    return _serialized(() async {
      final folderName = validateFolderName(name);
      final normalizedParent = managedRemote
          ? await requireAllowedExistingDirectory(
              parentPath,
              label: 'Parent directory',
            )
          : normalizeExistingDirectory(parentPath, label: 'Parent directory');
      final targetPath = p.normalize(p.join(normalizedParent, folderName));
      if (!p.isWithin(normalizedParent, targetPath)) {
        throw const FormatException(
          'Folder name must stay within the selected parent directory.',
        );
      }
      if (await FileSystemEntity.type(targetPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('A file or folder with that name already exists.');
      }

      await Directory(targetPath).create();
      return normalizePath(targetPath);
    });
  }

  Future<String> renameFolder({
    required String path,
    required String newName,
    bool managedRemote = false,
  }) async {
    return _serialized(() async {
      final sourcePath = await _validateMutableDirectory(
        path,
        managedRemote: managedRemote,
      );
      final folderName = validateFolderName(newName);
      final targetPath = p.normalize(p.join(p.dirname(sourcePath), folderName));
      if (targetPath == sourcePath) {
        return sourcePath;
      }
      if (await FileSystemEntity.type(targetPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('A file or folder with that name already exists.');
      }
      if (managedRemote) {
        await _assertAllowedRemotePath(p.dirname(sourcePath));
      }

      final renamed = await Directory(sourcePath).rename(targetPath);
      return normalizePath(renamed.path);
    });
  }

  Future<WorkspaceMutationPreview> previewDeleteFolder(
    String path, {
    bool managedRemote = false,
  }) async {
    final targetPath = await _validateMutableDirectory(
      path,
      managedRemote: managedRemote,
    );
    final counts = await _countDirectoryEntries(Directory(targetPath));
    final name = p.basename(targetPath);
    return WorkspaceMutationPreview(
      operation: CanonicalEventTypes.deleteFolder,
      path: targetPath,
      fingerprint: fingerprint(
        operation: CanonicalEventTypes.deleteFolder,
        path: targetPath,
        extra: '${counts.count}:${counts.truncated}',
      ),
      summary:
          'Delete "$name" and ${counts.count}${counts.truncated ? '+' : ''} items inside it. This cannot be undone.',
      entryCount: counts.count,
      truncated: counts.truncated,
    );
  }

  Future<String> deleteFolder(
    String path, {
    bool managedRemote = false,
    String? expectedFingerprint,
  }) async {
    return _serialized(() async {
      if (managedRemote) {
        final preview = await previewDeleteFolder(path, managedRemote: true);
        if (expectedFingerprint != null &&
            expectedFingerprint != preview.fingerprint) {
          throw const WorkspaceCommandException(
            WorkspaceCommandErrorCodes.staleConfirmation,
            'The confirmation ticket is stale or does not match.',
          );
        }
      }
      final targetPath = await _validateMutableDirectory(
        path,
        managedRemote: managedRemote,
      );
      await Directory(targetPath).delete(recursive: true);
      return targetPath;
    });
  }

  String validateFolderName(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.contains('\u0000')) {
      throw const FormatException('Folder name must be a single path segment.');
    }
    return name;
  }

  String normalizeExistingDirectory(String value, {required String label}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw FormatException('$label path is required.');
    }
    final type = FileSystemEntity.typeSync(trimmed, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw StateError('$label does not exist or is not a directory.');
    }
    return normalizePath(trimmed);
  }

  Future<String> _validateMutableDirectory(
    String value, {
    bool managedRemote = false,
  }) async {
    _rejectUnsafePathString(value);
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Folder path is required.');
    }
    final type = await FileSystemEntity.type(trimmed, followLinks: false);
    if (type == FileSystemEntityType.link) {
      if (managedRemote) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Symbolic-link folders cannot be changed here.',
        );
      }
      throw StateError('Symbolic-link folders cannot be changed here.');
    }
    if (type != FileSystemEntityType.directory) {
      throw StateError('Folder does not exist or is not a directory.');
    }

    final normalized = normalizePath(trimmed);
    if (_isFileSystemRoot(normalized)) {
      throw StateError('Filesystem roots cannot be renamed or deleted.');
    }
    if (managedRemote) {
      await _assertAllowedRemotePath(normalized);
      if (await _isProtectedRemoteRoot(normalized)) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Protected workspace roots cannot be renamed or deleted.',
        );
      }
    }
    return normalized;
  }

  bool _isFileSystemRoot(String path) {
    final parent = normalizePath(Directory(path).parent.path);
    return parent == path;
  }

  String normalizePath(String value) {
    final directory = Directory(value);
    try {
      return directory.resolveSymbolicLinksSync();
    } catch (_) {
      return directory.absolute.path;
    }
  }

  String ensureManagedWorkspacesRoot() {
    try {
      return SanadHomeBootstrap.atRoot(
        _sanadHome,
        scope: SanadHomeScope.identity,
      ).ensureDirectoryPathSync(
        SanadHomeBootstrap.managedWorkspacesDirectoryName,
      );
    } on SanadHomeBoundaryViolation {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'The managed workspaces root is not available.',
      );
    }
  }

  Future<Map<String, dynamic>> _browseAllowedRemoteRoots({
    required int maxEntries,
  }) async {
    final roots = await _allowedRemoteRoots();
    final entries = <Map<String, dynamic>>[];
    for (final root in roots.take(maxEntries)) {
      final entry = await _buildTreeEntry(Directory(root), rootPath: '');
      if (entry != null && !_isSanadInternalHidden(root)) {
        entries.add(entry);
      }
    }
    return {
      'workspace_id': '',
      'root_path': '',
      'path': '',
      'parent_path': null,
      'entries': entries,
      'truncated': roots.length > maxEntries,
    };
  }

  Future<List<String>> _allowedRemoteRoots() async {
    final roots = <String>{};
    final managed = normalizePath(ensureManagedWorkspacesRoot());
    roots.add(managed);
    for (final workspace in await _readStoredWorkspaces()) {
      final path = workspace['path'] as String?;
      if (path == null || path.trim().isEmpty) continue;
      if (!Directory(path).existsSync()) continue;
      final normalized = normalizePath(path);
      if (_isSanadInternalHidden(normalized)) continue;
      if (_isWithinRoot(root: managed, target: normalized)) continue;
      roots.add(normalized);
    }
    return roots.toList(growable: false);
  }

  Future<String?> _containingAllowedRoot(String path) async {
    final normalized = normalizePath(path);
    for (final root in await _allowedRemoteRoots()) {
      if (_isWithinRoot(root: root, target: normalized)) {
        return root;
      }
    }
    return null;
  }

  Future<void> _assertAllowedRemotePath(String path) async {
    _rejectUnsafePathString(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'Symbolic-link folders cannot be browsed or changed here.',
      );
    }
    final normalized = normalizePath(path);
    if (_isSanadInternalHidden(normalized) || _isFileSystemRoot(normalized)) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'That path is outside the allowed workspace roots.',
      );
    }
    if (await _containingAllowedRoot(normalized) == null) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'That path is outside the allowed workspace roots.',
      );
    }
  }

  Future<String> requireAllowedExistingDirectory(
    String value, {
    required String label,
  }) async {
    _rejectUnsafePathString(value);
    final normalized = normalizeExistingDirectory(value, label: label);
    await _assertAllowedRemotePath(normalized);
    return normalized;
  }

  Future<bool> _isProtectedRemoteRoot(String path) async {
    final normalized = normalizePath(path);
    if (normalized == normalizePath(ensureManagedWorkspacesRoot())) {
      return true;
    }
    if (normalized == normalizePath(_sanadHome)) {
      return true;
    }
    final stateHome = normalizePath(getSanadStateHome());
    if (normalized == stateHome) {
      return true;
    }
    for (final workspace in await _readStoredWorkspaces()) {
      final workspacePath = workspace['path'] as String?;
      if (workspacePath == null) continue;
      if (normalizePath(workspacePath) == normalized) {
        return true;
      }
    }
    return false;
  }

  bool _isSanadInternalHidden(String path) {
    final normalized = normalizePath(path);
    final home = normalizePath(_sanadHome);
    final managed = normalizePath(
      p.join(home, SanadHomeBootstrap.managedWorkspacesDirectoryName),
    );
    if (normalized == managed ||
        _isWithinRoot(root: managed, target: normalized)) {
      return false;
    }
    if (normalized == home || _isWithinRoot(root: home, target: normalized)) {
      return true;
    }
    final stateHome = normalizePath(getSanadStateHome());
    if (stateHome != home &&
        (normalized == stateHome ||
            _isWithinRoot(root: stateHome, target: normalized))) {
      return true;
    }
    return false;
  }

  void _rejectUnsafePathString(String value) {
    if (value.contains('\u0000')) {
      throw const FormatException('Invalid path.');
    }
  }

  String fingerprint({
    required String operation,
    required String path,
    String extra = '',
  }) {
    var modified = '';
    try {
      modified = FileStat.statSync(path).modified.toUtc().toIso8601String();
    } catch (_) {}
    return '$operation|$path|$modified|$extra';
  }

  Future<({int count, bool truncated})> _countDirectoryEntries(
    Directory directory,
  ) async {
    var count = 0;
    const limit = 500;
    try {
      await for (final _ in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        count += 1;
        if (count >= limit) {
          return (count: count, truncated: true);
        }
      }
    } on FileSystemException {
      return (count: count, truncated: false);
    }
    return (count: count, truncated: false);
  }

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final previous = _mutationTail;
    final done = Completer<void>();
    _mutationTail = done.future;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }
}
