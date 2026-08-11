import 'dart:io';

import 'package:path/path.dart' as p;

class WorkspacePathResolution {
  const WorkspacePathResolution({
    required this.workspaceRoot,
    required this.resolvedPath,
  });

  final String workspaceRoot;
  final String resolvedPath;

  bool get isExternal =>
      !p.equals(workspaceRoot, resolvedPath) &&
      !p.isWithin(workspaceRoot, resolvedPath);
}

class WorkspacePathResolver {
  const WorkspacePathResolver();

  String normalizeWorkspaceRoot(String workspacePath) {
    final trimmed = workspacePath.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Workspace path is required.');
    }

    return _canonicalizeExistingPath(trimmed);
  }

  WorkspacePathResolution classifyExistingPath({
    required String workspaceRoot,
    required String inputPath,
  }) {
    final normalizedWorkspace = normalizeWorkspaceRoot(workspaceRoot);
    final candidate = _candidatePath(normalizedWorkspace, inputPath);
    final type = FileSystemEntity.typeSync(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Path does not exist.', candidate);
    }

    return WorkspacePathResolution(
      workspaceRoot: normalizedWorkspace,
      resolvedPath: _canonicalizeExistingPath(candidate),
    );
  }

  WorkspacePathResolution classifyPathAllowMissing({
    required String workspaceRoot,
    required String inputPath,
  }) {
    final normalizedWorkspace = normalizeWorkspaceRoot(workspaceRoot);
    final candidate = _candidatePath(normalizedWorkspace, inputPath);
    return WorkspacePathResolution(
      workspaceRoot: normalizedWorkspace,
      resolvedPath: _canonicalizePathAllowMissing(candidate),
    );
  }

  String resolveExistingPath({
    required String workspaceRoot,
    required String inputPath,
    String? authorizedExternalRoot,
  }) {
    final resolution = classifyExistingPath(
      workspaceRoot: workspaceRoot,
      inputPath: inputPath,
    );
    return _ensureWithinWorkspace(
      workspaceRoot: resolution.workspaceRoot,
      resolvedPath: resolution.resolvedPath,
      authorizedExternalRoot: authorizedExternalRoot,
    );
  }

  String resolvePathAllowMissing({
    required String workspaceRoot,
    required String inputPath,
    String? authorizedExternalRoot,
  }) {
    final resolution = classifyPathAllowMissing(
      workspaceRoot: workspaceRoot,
      inputPath: inputPath,
    );
    return _ensureWithinWorkspace(
      workspaceRoot: resolution.workspaceRoot,
      resolvedPath: resolution.resolvedPath,
      authorizedExternalRoot: authorizedExternalRoot,
    );
  }

  String displayPath({
    required String workspaceRoot,
    required String resolvedPath,
  }) {
    final normalizedWorkspace = normalizeWorkspaceRoot(workspaceRoot);
    final normalizedPath = p.normalize(resolvedPath);
    if (p.equals(normalizedWorkspace, normalizedPath)) {
      return '.';
    }
    if (p.isWithin(normalizedWorkspace, normalizedPath)) {
      return p.relative(normalizedPath, from: normalizedWorkspace);
    }
    return normalizedPath;
  }

  String relativeToWorkspace({
    required String workspaceRoot,
    required String resolvedPath,
  }) => displayPath(workspaceRoot: workspaceRoot, resolvedPath: resolvedPath);

  String _candidatePath(String workspaceRoot, String inputPath) {
    final trimmed = inputPath.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Tool path is required.');
    }

    return p.normalize(
      p.isAbsolute(trimmed) ? trimmed : p.join(workspaceRoot, trimmed),
    );
  }

  String _canonicalizeExistingPath(String rawPath) {
    try {
      final type = FileSystemEntity.typeSync(rawPath, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        return Directory(rawPath).resolveSymbolicLinksSync();
      }
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        return File(rawPath).resolveSymbolicLinksSync();
      }
    } catch (_) {}
    return p.normalize(p.absolute(rawPath));
  }

  String _canonicalizePathAllowMissing(String rawPath) {
    final absolute = p.normalize(p.absolute(rawPath));
    final existingAncestor = _nearestExistingAncestor(absolute);
    if (existingAncestor == null) {
      return absolute;
    }

    final ancestorCanonical = _canonicalizeExistingPath(existingAncestor.path);
    final relativeRemainder = p.relative(absolute, from: existingAncestor.path);
    if (relativeRemainder == '.') {
      return ancestorCanonical;
    }
    return p.normalize(p.join(ancestorCanonical, relativeRemainder));
  }

  FileSystemEntity? _nearestExistingAncestor(String absolutePath) {
    var cursor = absolutePath;
    while (true) {
      final type = FileSystemEntity.typeSync(cursor, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        return type == FileSystemEntityType.directory
            ? Directory(cursor)
            : File(cursor);
      }

      final parent = p.dirname(cursor);
      if (parent == cursor) {
        return null;
      }
      cursor = parent;
    }
  }

  String _ensureWithinWorkspace({
    required String workspaceRoot,
    required String resolvedPath,
    String? authorizedExternalRoot,
  }) {
    final normalizedWorkspace = p.normalize(workspaceRoot);
    final normalizedPath = p.normalize(resolvedPath);
    if (p.equals(normalizedWorkspace, normalizedPath) ||
        p.isWithin(normalizedWorkspace, normalizedPath)) {
      return normalizedPath;
    }

    if (authorizedExternalRoot != null) {
      final normalizedAuthorizedRoot = _canonicalizePathAllowMissing(
        authorizedExternalRoot,
      );
      if (p.equals(normalizedAuthorizedRoot, normalizedPath) ||
          p.isWithin(normalizedAuthorizedRoot, normalizedPath)) {
        return normalizedPath;
      }
    }

    throw FileSystemException(
      'Path escapes the current workspace without authorization.',
      normalizedPath,
    );
  }
}
