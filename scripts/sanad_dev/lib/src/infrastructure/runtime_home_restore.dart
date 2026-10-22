import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'runtime_home_fixture.dart';

/// Matches a Windows drive-qualified path, which is absolute even for `p.posix`.
final RegExp _windowsDrivePattern = RegExp(r'^[A-Za-z]:');

/// One validated fixture entry: a captured relative path and its bytes.
class _ValidatedEntry {
  _ValidatedEntry({required this.relativePath, required this.bytes});

  final String relativePath;
  final List<int> bytes;
}

class _SwapRecord {
  _SwapRecord(this.group);

  final String group;
  final List<String> displaced = [];
  final List<String> placed = [];
}

/// Restores a saved fixture into [homePath].
///
/// The restore is fail-closed and two-phase:
///
/// 1. Every manifest entry is re-validated against the capture allowlist and
///    resolved inside the canonical Home. Absolute paths, `..` traversal, and
///    any symbolic link in an intermediate directory are refused before a
///    single Home path is touched.
/// 2. The whole fixture is staged beside the Home, then swapped per top-level
///    entry group with a rollback journal. The `state.db` family is one group,
///    so a database is never published with mismatched `-wal`/`-shm` sidecars.
///
/// Files outside the captured set (secrets, journals, logs, media, `dev/`) are
/// preserved untouched: they are never read, moved, or deleted.
Future<HomeFixtureRestoreReport> restoreHomeFixture({
  required String workspaceRoot,
  required String homePath,
  required String name,
}) async {
  final manifest = await readHomeFixtureManifest(
    workspaceRoot: workspaceRoot,
    name: name,
  );
  final requestedHome = Directory(homePath);
  if (!requestedHome.existsSync()) {
    throw StateError('The Sanad Home does not exist: $homePath');
  }
  // Resolve once and use the canonical Home for validation and for every write,
  // so no later step can follow a different path to the same inode.
  final canonicalHome = _canonicalDirectory(
    requestedHome.path,
    description: 'Sanad Home',
  );
  final fixtureDirectory = Directory(sanadDevFixturePath(workspaceRoot, name));
  if (!fixtureDirectory.existsSync()) {
    throw StateError('Unknown Sanad fixture "$name" for this worktree.');
  }
  final canonicalFixture = _canonicalDirectory(
    fixtureDirectory.path,
    description: 'Sanad fixture "$name"',
  );
  final includeMcpConfig = manifest.includeMcpConfig;

  final entries = <_ValidatedEntry>[];
  for (final entry in manifest.entries) {
    final relative = _validatedRelativePath(
      entry.relativePath,
      fixtureName: name,
    );
    if (!isFixtureCapturedPath(relative, includeMcpConfig: includeMcpConfig)) {
      throw _unsafeRestore(
        name,
        entry.relativePath,
        'is not a captured fixture path',
      );
    }
    // Resolve the Home target first: it is the security check, and it refuses a
    // traversal, an absolute path, and any symlinked parent before the fixture
    // bytes are even read.
    _resolveInsideRoot(
      canonicalHome,
      relative,
      fixtureName: name,
      role: 'Home',
    );
    final source = _resolveInsideRoot(
      canonicalFixture,
      relative,
      fixtureName: name,
      role: 'fixture',
    );
    if (FileSystemEntity.typeSync(source, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError(
        'Sanad fixture "$name" is incomplete: ${entry.relativePath} is missing.',
      );
    }
    final bytes = File(source).readAsBytesSync();
    if (entry.size != bytes.length ||
        sha256.convert(bytes).toString() != entry.sha256) {
      throw StateError(
        'Sanad fixture "$name" is corrupt: ${entry.relativePath} does not '
        'match its manifest.',
      );
    }
    entries.add(_ValidatedEntry(relativePath: relative, bytes: bytes));
  }

  final stagingRoot = p.join(
    p.dirname(canonicalHome),
    fixtureRestoreStagingDirectoryName,
  );
  final stagedRoot = p.join(stagingRoot, 'new');
  final backupRoot = p.join(stagingRoot, 'backup');
  // A crashed restore leaves displaced originals beside the Home; put them back
  // before doing anything else so the Home is never left short an entry.
  await _recoverLeftoverStaging(
    canonicalHome: canonicalHome,
    stagingRoot: stagingRoot,
  );

  final before = listFixtureSourcePaths(
    canonicalHome,
    includeMcpConfig: includeMcpConfig,
  ).toSet();
  final manifestPaths = entries.map((entry) => entry.relativePath).toSet();
  final removedFiles = before.where((path) => !manifestPaths.contains(path)).length;

  try {
    await sanadDevCreateOwnerOnlyDirectory(stagingRoot);
    await sanadDevCreateOwnerOnlyDirectory(stagedRoot);
    await sanadDevCreateOwnerOnlyDirectory(backupRoot);
    for (final entry in entries) {
      final staged = File(p.join(stagedRoot, entry.relativePath));
      Directory(staged.parent.path).createSync(recursive: true);
      staged.writeAsBytesSync(entry.bytes, flush: true);
      await sanadDevRestrictOwnerOnly(staged.path);
    }

    final strayPath = await _firstUnexpectedStagingPath(
      stagedRoot: stagedRoot,
      expected: manifestPaths,
    );
    if (strayPath != null) {
      throw _unsafeRestore(
        name,
        strayPath,
        'is not declared by the fixture manifest',
      );
    }

    final groups = <String, Set<String>>{};
    for (final path in {...before, ...manifestPaths}) {
      groups.putIfAbsent(_restoreGroupKey(path), () => <String>{}).add(path);
    }
    final orderedGroups = groups.keys.toList()
      ..sort((left, right) {
        final rank = _restoreGroupRank(left).compareTo(_restoreGroupRank(right));
        return rank != 0 ? rank : left.compareTo(right);
      });

    final journal = <_SwapRecord>[];
    try {
      for (final group in orderedGroups) {
        final members = groups[group]!.toList()..sort();
        final record = _SwapRecord(group);
        journal.add(record);
        for (final relative in members) {
          final current = p.join(canonicalHome, relative);
          final type = FileSystemEntity.typeSync(current, followLinks: false);
          if (type == FileSystemEntityType.notFound) continue;
          if (type != FileSystemEntityType.file) {
            throw _unsafeRestore(
              name,
              relative,
              'is a symbolic link or not a regular file in the Home',
            );
          }
          final backup = p.join(backupRoot, relative);
          Directory(p.dirname(backup)).createSync(recursive: true);
          File(current).renameSync(backup);
          record.displaced.add(relative);
        }
        for (final relative in members) {
          if (!manifestPaths.contains(relative)) continue;
          final staged = p.join(stagedRoot, relative);
          if (!File(staged).existsSync()) continue;
          final destination = p.join(canonicalHome, relative);
          Directory(p.dirname(destination)).createSync(recursive: true);
          File(staged).renameSync(destination);
          record.placed.add(relative);
        }
      }
    } on Object catch (error) {
      final rollback = _rollback(
        journal: journal,
        canonicalHome: canonicalHome,
        backupRoot: backupRoot,
      );
      throw StateError(
        'Sanad fixture "$name" could not be restored: $error. $rollback',
      );
    }

    _removeEmptyIncludedDirectories(canonicalHome);
    return HomeFixtureRestoreReport(
      restoredFiles: journal.fold(
        0,
        (total, record) => total + record.placed.length,
      ),
      removedFiles: removedFiles,
      preservedPaths: fixtureExcludedPaths.toList(growable: false),
    );
  } finally {
    _deleteTree(stagingRoot);
  }
}

/// Group key for the swap: the database family moves as one unit.
String _restoreGroupKey(String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  return fixtureDatabaseFamily.contains(normalized)
      ? 'state.db'
      : normalized;
}

/// Order groups so the database family is swapped first and files precede
/// directories (a directory member must never be confused with a file member).
int _restoreGroupRank(String group) {
  if (group == 'state.db') return 0;
  return group.contains('/') || fixtureIncludedDirectories.contains(group)
      ? 2
      : 1;
}

String _validatedRelativePath(String value, {required String fixtureName}) {
  final normalized = value.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) {
    throw _unsafeRestore(fixtureName, value, 'is an empty path');
  }
  if (normalized.startsWith('/') ||
      p.posix.isAbsolute(normalized) ||
      _windowsDrivePattern.hasMatch(normalized)) {
    throw _unsafeRestore(fixtureName, value, 'is an absolute path');
  }
  final segments = normalized.split('/');
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') {
      throw _unsafeRestore(
        fixtureName,
        value,
        'contains an empty, "." or ".." segment',
      );
    }
  }
  return segments.join('/');
}

/// Resolves [relativePath] below [canonicalRoot], refusing any symbolic link in
/// any intermediate directory and any lexical escape.
String _resolveInsideRoot(
  String canonicalRoot,
  String relativePath, {
  required String fixtureName,
  required String role,
}) {
  final segments = relativePath.split('/');
  var current = canonicalRoot;
  for (var index = 0; index < segments.length; index++) {
    current = p.join(current, segments[index]);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw _unsafeRestore(
        fixtureName,
        relativePath,
        'crosses a symbolic link in the $role path',
      );
    }
    if (index < segments.length - 1 &&
        type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw _unsafeRestore(
        fixtureName,
        relativePath,
        'has a non-directory parent in the $role path',
      );
    }
  }
  if (!p.isWithin(canonicalRoot, current)) {
    throw _unsafeRestore(
      fixtureName,
      relativePath,
      'resolves outside the $role root',
    );
  }
  return current;
}

StateError _unsafeRestore(String fixtureName, String path, String reason) =>
    StateError(
      'Refusing to restore Sanad fixture "$fixtureName": path "$path" $reason. '
      'No Home file was changed.',
    );

String _canonicalDirectory(String path, {required String description}) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException catch (error) {
    throw StateError('Could not resolve the $description $path: $error');
  }
}

/// Puts displaced originals back when a previous restore was interrupted.
Future<void> _recoverLeftoverStaging({
  required String canonicalHome,
  required String stagingRoot,
}) async {
  final backupRoot = p.join(stagingRoot, 'backup');
  if (Directory(backupRoot).existsSync()) {
    for (final entity in Directory(
      backupRoot,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: backupRoot);
      final destination = p.join(canonicalHome, relative);
      Directory(p.dirname(destination)).createSync(recursive: true);
      if (File(destination).existsSync()) {
        File(destination).deleteSync();
      }
      entity.renameSync(destination);
    }
  }
  _deleteTree(stagingRoot);
}

String? _firstUnexpectedStagingPath({
  required String stagedRoot,
  required Set<String> expected,
}) {
  final root = Directory(stagedRoot);
  if (!root.existsSync()) return null;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final relative = p
        .relative(entity.path, from: stagedRoot)
        .replaceAll('\\', '/');
    if (entity is! File || !expected.contains(relative)) return relative;
  }
  return null;
}

String _rollback({
  required List<_SwapRecord> journal,
  required String canonicalHome,
  required String backupRoot,
}) {
  for (final record in journal.reversed) {
    for (final relative in record.placed.reversed) {
      final destination = p.join(canonicalHome, relative);
      if (File(destination).existsSync()) {
        File(destination).deleteSync();
      }
    }
    for (final relative in record.displaced.reversed) {
      final backup = p.join(backupRoot, relative);
      if (!File(backup).existsSync()) continue;
      final destination = p.join(canonicalHome, relative);
      Directory(p.dirname(destination)).createSync(recursive: true);
      if (File(destination).existsSync()) {
        File(destination).deleteSync();
      }
      File(backup).renameSync(destination);
    }
  }
  return 'The Home was rolled back to its previous state.';
}

void _deleteTree(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else {
    File(path).deleteSync();
  }
}

void _removeEmptyIncludedDirectories(String homePath) {
  for (final name in fixtureIncludedDirectories) {
    final directory = Directory(p.join(homePath, name));
    if (!directory.existsSync()) continue;
    final remaining = directory.listSync(recursive: true, followLinks: false);
    if (remaining.isNotEmpty) continue;
    directory.deleteSync();
  }
}
