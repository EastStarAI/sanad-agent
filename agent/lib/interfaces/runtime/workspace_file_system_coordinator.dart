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
    if (managedRemote) {
      return _browseManaged(
        workspaceId: workspaceId,
        path: path,
        maxEntries: maxEntries,
      );
    }
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
        return _buildDirectorySnapshot(
          directory: Directory(resolvedWorkspacePath),
          workspaceId: workspace['id'] as String,
          rootPath: resolvedWorkspacePath,
          path: resolvedWorkspacePath,
          parentPath: null,
          maxEntries: maxEntries,
        );
      }
      return _browseSystemRoots(maxEntries: maxEntries);
    }

    _rejectUnsafePathString(trimmedPath);
    final requestedPath = normalizePath(trimmedPath);
    var workspacePath = '';
    var rootPath = _rootPathFor(requestedPath);
    var parentPath = _parentPathFor(requestedPath, rootPath: rootPath);

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
    );
  }

  /// Managed-remote browse: confined to the managed workspaces root.
  ///
  /// An empty path opens the root itself. A `workspace_id` scope is allowed
  /// only for a workspace that resolves inside the root.
  Future<Map<String, dynamic>> _browseManaged({
    required String? workspaceId,
    required String? path,
    required int maxEntries,
  }) async {
    final hasPath = path != null && path.trim().isNotEmpty;
    var rootPath = managedRootPath();
    var scopedWorkspaceId = '';
    if (workspaceId != null && workspaceId.trim().isNotEmpty) {
      final workspace = _getWorkspaceRecordById(workspaceId);
      final resolvedWorkspacePath = await _resolveWorkspacePathById(
        workspaceId,
      );
      if (workspace == null || resolvedWorkspacePath == null) {
        throw StateError('Workspace not found or its folder is unavailable.');
      }
      rootPath = await resolveManagedDirectory(resolvedWorkspacePath);
      scopedWorkspaceId = workspace['id'] as String;
    }
    final target = hasPath ? await resolveManagedDirectory(path) : rootPath;
    if (!_isWithinRoot(root: rootPath, target: target)) {
      throw StateError('Requested path is outside the selected workspace.');
    }
    return _buildDirectorySnapshot(
      directory: Directory(target),
      workspaceId: scopedWorkspaceId,
      rootPath: rootPath,
      path: target,
      parentPath: p.equals(target, rootPath) ? null : p.dirname(target),
      maxEntries: maxEntries,
      managed: true,
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
    bool managed = false,
  }) async {
    final entities = <FileSystemEntity>[];
    await for (final entity in directory.list(followLinks: false)) {
      // Managed listings never report links, so no target is disclosed.
      if (managed && entity is Link) continue;
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
      final entry = await _buildTreeEntry(
        entity,
        rootPath: rootPath,
        // Managed entry paths are lexical children of the validated listing.
        lexicalPath: managed ? p.join(path, p.basename(entity.path)) : null,
      );
      if (entry == null) {
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
    String? lexicalPath,
  }) async {
    try {
      final stat = await entity.stat();
      final entityPath = lexicalPath ?? normalizePath(entity.path);
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
          ? await resolveManagedDirectory(parentPath)
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
    if (managedRemote) {
      final resolved = await resolveManagedDirectory(value);
      if (p.equals(resolved, managedRootPath())) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'The managed workspaces root cannot be renamed or deleted.',
        );
      }
      final stateHome = _stateHomeInside(managedRootPath());
      if (stateHome != null &&
          _isWithinRoot(root: resolved, target: stateHome)) {
        throw _notAllowed('This folder contains Sanad state.');
      }
      await _assertNoWorkspaceInside(resolved);
      return resolved;
    }
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
    await _assertNoWorkspaceInside(normalized);
    return normalized;
  }

  /// Refuses a rename/delete target that is, or contains, a registered
  /// workspace, so a workspace path is never broken behind its record.
  Future<void> _assertNoWorkspaceInside(String target) async {
    for (final workspace in await _readStoredWorkspaces()) {
      final workspacePath = workspace['path'] as String?;
      if (workspacePath == null || workspacePath.trim().isEmpty) continue;
      if (_isWithinRoot(root: target, target: workspacePath)) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.workspaceInUse,
          'This folder is or contains a workspace. Remove the workspace first.',
        );
      }
    }
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

  /// The managed workspaces root of the runtime Home, as a real path.
  ///
  /// Derived from the injected Home on every call, never from a fixed
  /// directory name, so a custom or test Home moves the root with it.
  String managedRootPath() => normalizePath(ensureManagedWorkspacesRoot());

  /// Validates a managed-remote (cloud) path and returns its real path.
  ///
  /// The path must be absolute, NUL-free, free of raw `..` segments, and
  /// resolve to an existing directory inside the managed workspaces root
  /// without crossing a symbolic link at any component below that root.
  /// Every rejection is a coded [WorkspaceCommandErrorCodes.pathNotAllowed],
  /// except a missing folder, which is a not-found [StateError].
  Future<String> resolveManagedDirectory(
    String value, {
    bool allowRoot = true,
  }) async {
    if (value.contains('\u0000')) {
      throw _notAllowed('The path contains an invalid character.');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) {
      throw _notAllowed('The path must be absolute.');
    }
    if (p.split(trimmed).contains('..')) {
      throw _notAllowed('The path must not contain "..".');
    }
    final lexical = p.normalize(trimmed);
    final rootLexical = p.normalize(ensureManagedWorkspacesRoot());
    final rootReal = normalizePath(rootLexical);
    String? relative;
    for (final base in {rootReal, rootLexical}) {
      if (p.equals(base, lexical)) {
        relative = '';
        break;
      }
      if (p.isWithin(base, lexical)) {
        relative = p.relative(lexical, from: base);
        break;
      }
    }
    if (relative == null) {
      throw _notAllowed('That path is outside the managed workspaces root.');
    }
    var current = rootReal;
    if (relative.isNotEmpty) {
      for (final segment in p.split(relative)) {
        current = p.join(current, segment);
        final type = await FileSystemEntity.type(current, followLinks: false);
        if (type == FileSystemEntityType.link) {
          throw _notAllowed('Symbolic links cannot be used here.');
        }
        if (type == FileSystemEntityType.notFound) {
          throw StateError('That folder does not exist.');
        }
        if (type != FileSystemEntityType.directory) {
          throw _notAllowed('That path is not a folder.');
        }
      }
    }
    if (!allowRoot && p.equals(current, rootReal)) {
      throw _notAllowed('Choose a folder inside the workspaces root.');
    }
    final stateHome = _stateHomeInside(rootReal);
    if (stateHome != null && _isWithinRoot(root: stateHome, target: current)) {
      throw _notAllowed('That path is outside the managed workspaces root.');
    }
    return current;
  }

  /// A folder strictly inside the managed root that may become, or be
  /// relocated to as, a workspace.
  Future<String> requireManagedWorkspaceDirectory(String value) =>
      resolveManagedDirectory(value, allowRoot: false);

  /// The state home when it is configured inside the managed root, an
  /// unusual layout; `null` for the normal layout where it lies outside.
  String? _stateHomeInside(String rootReal) {
    final stateHome = normalizePath(getSanadStateHome());
    return p.isWithin(rootReal, stateHome) ? stateHome : null;
  }

  WorkspaceCommandException _notAllowed(String message) =>
      WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        message,
      );

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
