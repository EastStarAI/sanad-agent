import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Coordinates directory tree browsing, folder creation, renaming, previewing,
/// deletion, safe path validation, and managed remote boundaries for workspaces.
class WorkspaceFileSystemCoordinator {
  WorkspaceFileSystemCoordinator({
    required String Function() getSanadHome,
    required Map<String, dynamic>? Function(String workspaceId)
    getWorkspaceRecordById,
    required Future<String?> Function(String workspaceId)
    resolveWorkspacePathById,
    required Future<List<Map<String, dynamic>>> Function() readStoredWorkspaces,
  })  : _getSanadHome = getSanadHome,
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
          await assertAllowedRemotePath(resolvedWorkspacePath);
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

    rejectUnsafePathString(trimmedPath);
    final requestedPath = normalizePath(trimmedPath);
    var workspacePath = '';
    var rootPath = _rootPathFor(requestedPath);
    var parentPath = _parentPathFor(requestedPath, rootPath: rootPath);

    if (managedRemote) {
      await assertAllowedRemotePath(requestedPath);
      final allowedRoot = await containingAllowedRoot(requestedPath);
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
      if (!isWithinRoot(root: resolvedWorkspacePath, target: requestedPath)) {
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
      final sourcePath = await validateMutableDirectory(
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
        await assertAllowedRemotePath(p.dirname(sourcePath));
      }

      final renamed = await Directory(sourcePath).rename(targetPath);
      return normalizePath(renamed.path);
    });
  }

  Future<WorkspaceMutationPreview> previewDeleteFolder(
    String path, {
    bool managedRemote = false,
  }) async {
    final targetPath = await validateMutableDirectory(
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
      final targetPath = await validateMutableDirectory(
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

  Future<String> validateMutableDirectory(
    String value, {
    bool managedRemote = false,
  }) async {
    rejectUnsafePathString(value);
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
    if (isFileSystemRoot(normalized)) {
      throw StateError('Filesystem roots cannot be renamed or deleted.');
    }
    if (managedRemote) {
      await assertAllowedRemotePath(normalized);
      if (await isProtectedRemoteRoot(normalized)) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Protected workspace roots cannot be renamed or deleted.',
        );
      }
    }
    return normalized;
  }

  bool isFileSystemRoot(String path) {
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
    final home = normalizePath(_sanadHome);
    final root = p.join(
      home,
      SanadHomeBootstrap.managedWorkspacesDirectoryName,
    );
    final directory = Directory(root);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return normalizePath(root);
  }

  Future<Map<String, dynamic>> _browseAllowedRemoteRoots({
    required int maxEntries,
  }) async {
    final roots = await allowedRemoteRoots();
    final entries = <Map<String, dynamic>>[];
    for (final root in roots) {
      final directory = Directory(root);
      if (!await directory.exists()) continue;
      entries.add({
        'name': _entryDisplayName(root),
        'path': root,
        'type': 'directory',
        'is_directory': true,
        'is_symlink': false,
        'is_hidden': false,
        'is_readable': true,
      });
      if (entries.length >= maxEntries) break;
    }
    return {
      'workspace_id': '',
      'root_path': '',
      'path': '',
      'parent_path': null,
      'entries': entries,
      'truncated': entries.length >= maxEntries,
    };
  }

  Future<List<String>> allowedRemoteRoots() async {
    final roots = <String>{};
    final managed = normalizePath(ensureManagedWorkspacesRoot());
    roots.add(managed);
    for (final workspace in await _readStoredWorkspaces()) {
      final path = workspace['path'] as String?;
      if (path == null || path.trim().isEmpty) continue;
      final normalized = normalizePath(path);
      if (isSanadInternalHidden(normalized)) continue;
      if (await Directory(normalized).exists()) {
        roots.add(normalized);
      }
    }
    return roots.toList(growable: false);
  }

  Future<void> assertAllowedRemotePath(String targetPath) async {
    final normalized = normalizePath(targetPath);
    if (isSanadInternalHidden(normalized)) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'Sanad configuration and internal storage cannot be browsed.',
      );
    }
    final allowed = await containingAllowedRoot(normalized);
    if (allowed == null) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'Remote navigation is restricted to registered workspaces and managed storage.',
      );
    }
  }

  Future<String?> containingAllowedRoot(String targetPath) async {
    final normalizedTarget = normalizePath(targetPath);
    for (final root in await allowedRemoteRoots()) {
      final normalizedRoot = normalizePath(root);
      if (normalizedTarget == normalizedRoot ||
          p.isWithin(normalizedRoot, normalizedTarget)) {
        return normalizedRoot;
      }
    }
    return null;
  }

  Future<String> requireAllowedExistingDirectory(
    String value, {
    required String label,
  }) async {
    final normalized = normalizeExistingDirectory(value, label: label);
    await assertAllowedRemotePath(normalized);
    return normalized;
  }

  Future<bool> isProtectedRemoteRoot(String path) async {
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

  bool isSanadInternalHidden(String path) {
    final normalized = normalizePath(path);
    final home = normalizePath(_sanadHome);
    final managed = normalizePath(
      p.join(home, SanadHomeBootstrap.managedWorkspacesDirectoryName),
    );
    if (normalized == managed || p.isWithin(managed, normalized)) {
      return false;
    }
    if (normalized == home || p.isWithin(home, normalized)) {
      return true;
    }
    final stateHome = normalizePath(getSanadStateHome());
    if (normalized == stateHome || p.isWithin(stateHome, normalized)) {
      return true;
    }
    return false;
  }

  void rejectUnsafePathString(String value) {
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

  bool isWithinRoot({required String root, required String target}) {
    final normalizedRoot = normalizePath(root);
    final normalizedTarget = normalizePath(target);
    return normalizedRoot == normalizedTarget ||
        p.isWithin(normalizedRoot, normalizedTarget);
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
        'entries': roots,
        'truncated': false,
      };
    }

    final rootDir = Directory('/');
    return _buildDirectorySnapshot(
      directory: rootDir,
      workspaceId: '',
      rootPath: '/',
      path: '/',
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
    final entries = <Map<String, dynamic>>[];
    var truncated = false;
    try {
      final children = await directory.list(followLinks: false).toList();
      children.sort((left, right) {
        final leftIsDir = left is Directory ? 0 : 1;
        final rightIsDir = right is Directory ? 0 : 1;
        if (leftIsDir != rightIsDir) {
          return leftIsDir.compareTo(rightIsDir);
        }
        return p
            .basename(left.path)
            .toLowerCase()
            .compareTo(p.basename(right.path).toLowerCase());
      });

      for (final child in children) {
        if (hideInternal && isSanadInternalHidden(child.path)) {
          continue;
        }
        if (entries.length >= maxEntries) {
          truncated = true;
          break;
        }
        final entry = await _buildTreeEntry(
          child,
          rootPath: rootPath,
          hideInternal: hideInternal,
        );
        if (entry != null) {
          entries.add(entry);
        }
      }
    } catch (_) {
      // Permission or unreadable directories return an empty entries list.
    }

    return {
      'workspace_id': workspaceId,
      'root_path': rootPath,
      'path': path,
      'parent_path': parentPath,
      'entries': entries,
      'truncated': truncated,
    };
  }

  Future<Map<String, dynamic>?> _buildTreeEntry(
    FileSystemEntity entity, {
    required String rootPath,
    bool hideInternal = false,
  }) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    final isDirectory = type == FileSystemEntityType.directory;
    final isSymlink = type == FileSystemEntityType.link;
    final name = _entryDisplayName(entity.path);
    final isHidden = name.startsWith('.');
    if (hideInternal && (isSanadInternalHidden(entity.path) || isHidden)) {
      return null;
    }

    return {
      'name': name,
      'path': normalizePath(entity.path),
      'relative_path': _relativePathFor(entity.path, rootPath: rootPath),
      'type': isDirectory ? 'directory' : (isSymlink ? 'symlink' : 'file'),
      'is_directory': isDirectory,
      'is_symlink': isSymlink,
      'is_hidden': isHidden,
      'is_readable': true,
    };
  }

  Future<List<Map<String, dynamic>>> _listWindowsRoots() async {
    final roots = <Map<String, dynamic>>[];
    for (var code = 65; code <= 90; code++) {
      final drive = '${String.fromCharCode(code)}:\\';
      if (await Directory(drive).exists()) {
        roots.add({
          'name': drive,
          'path': drive,
          'relative_path': drive,
          'type': 'directory',
          'is_directory': true,
          'is_symlink': false,
          'is_hidden': false,
          'is_readable': true,
        });
      }
    }
    return roots;
  }

  String _rootPathFor(String targetPath) {
    if (Platform.isWindows) {
      final root = p.rootPrefix(targetPath);
      return root.isNotEmpty ? normalizePath(root) : normalizePath(targetPath);
    }
    return '/';
  }

  String? _parentPathFor(String targetPath, {required String rootPath}) {
    final normalizedTarget = normalizePath(targetPath);
    final normalizedRoot = normalizePath(rootPath);
    if (normalizedTarget == normalizedRoot) {
      return null;
    }
    final parent = normalizePath(Directory(normalizedTarget).parent.path);
    return parent == normalizedTarget ? null : parent;
  }

  String _relativePathFor(String entityPath, {required String rootPath}) {
    final normalizedRoot = normalizePath(rootPath);
    final normalizedEntity = normalizePath(entityPath);
    if (normalizedRoot == normalizedEntity) return '.';
    return p.relative(normalizedEntity, from: normalizedRoot);
  }

  String _entryDisplayName(String entityPath) {
    final base = p.basename(entityPath);
    if (base.isNotEmpty) return base;
    return entityPath;
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

  Future<T> serialized<T>(Future<T> Function() operation) =>
      _serialized(operation);

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
