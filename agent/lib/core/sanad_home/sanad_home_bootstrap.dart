library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../constants.dart';
import 'sanad_home_boundary.dart';

enum SanadHomeScope { identity, state }

/// Owner-only filesystem boundary for one configured Sanad runtime root.
///
/// SQLite is the only writer that cannot use [writeSecret]. Its owner must call
/// [prepareDatabase] before opening the connection and [secureDatabaseFiles]
/// immediately after opening it so the database and any WAL/SHM sidecars are
/// never left with inherited/default permissions.
class SanadHomeBootstrap {
  SanadHomeBootstrap._(this.scope, this._configuredRoot);

  final SanadHomeScope scope;
  final String _configuredRoot;

  static const int secretFileMode = 0x180; // 0600
  static const int secretDirMode = 0x1c0; // 0700
  static bool _ownerOnlyUmaskInstalled = false;

  static SanadHomeBootstrap identity() =>
      SanadHomeBootstrap._(SanadHomeScope.identity, getSanadHome());

  static SanadHomeBootstrap state() =>
      SanadHomeBootstrap._(SanadHomeScope.state, getSanadStateHome());

  static SanadHomeBootstrap atRoot(
    String path, {
    SanadHomeScope scope = SanadHomeScope.state,
  }) => SanadHomeBootstrap._(scope, path);

  /// Creates and secures both configured roots, rejecting distinct roots that
  /// overlap. Identical identity/state roots are the normal installed layout.
  static Future<void> prepareAll() async {
    _enforceOwnerOnlyProcessUmaskSync();
    final home = identity();
    final stateHome = state();
    final preflightHome = home._preflightRootPath();
    final preflightState = stateHome._preflightRootPath();
    if (!p.equals(preflightHome, preflightState) &&
        (p.isWithin(preflightHome, preflightState) ||
            p.isWithin(preflightState, preflightHome))) {
      throw const SanadHomeBoundaryViolation(
        'overlapping_roots',
        'Distinct SANAD_HOME and SANAD_STATE_HOME roots must not overlap.',
      );
    }
    final homePath = await home.prepare();
    final statePath = await stateHome.prepare();
    if (!p.equals(homePath, statePath) &&
        (p.isWithin(homePath, statePath) || p.isWithin(statePath, homePath))) {
      throw const SanadHomeBoundaryViolation(
        'overlapping_roots',
        'Distinct SANAD_HOME and SANAD_STATE_HOME roots must not overlap.',
      );
    }
  }

  String _preflightRootPath() {
    final absolute = p.normalize(p.absolute(_expandPath(_configuredRoot)));
    _rejectLink(absolute, code: 'root_symlink');
    var existing = absolute;
    final suffix = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) break;
      suffix.insert(0, p.basename(existing));
      existing = parent;
    }
    final resolved = Directory(existing).resolveSymbolicLinksSync();
    return p.normalize(p.joinAll([resolved, ...suffix]));
  }

  /// Creates the root when absent and enforces owner-only access.
  Future<String> prepare() async {
    _enforceOwnerOnlyProcessUmaskSync();
    final expanded = _expandPath(_configuredRoot);
    final absolute = p.normalize(p.absolute(expanded));
    _rejectLink(absolute, code: 'root_symlink');
    final root = Directory(absolute);
    if (!root.existsSync()) {
      root.createSync(recursive: true);
    }
    _rejectLink(absolute, code: 'root_symlink');
    await _enforceDirectoryOwnership(root);
    return root.resolveSymbolicLinksSync();
  }

  String canonicalRoot() {
    final expanded = p.normalize(p.absolute(_expandPath(_configuredRoot)));
    _rejectLink(expanded, code: 'root_symlink');
    final root = Directory(expanded);
    if (!root.existsSync()) {
      throw const SanadHomeBoundaryViolation(
        'home_unprepared',
        'The Sanad runtime root has not been prepared.',
      );
    }
    return root.resolveSymbolicLinksSync();
  }

  String child(String relative) {
    if (relative.contains('\u0000')) {
      throw const SanadHomeBoundaryViolation(
        'null_byte',
        'NUL bytes are not allowed in Sanad runtime paths.',
      );
    }
    if (relative.isEmpty) {
      throw const SanadHomeBoundaryViolation(
        'empty_path',
        'A non-empty relative child path is required.',
      );
    }
    if (p.isAbsolute(relative)) {
      throw const SanadHomeBoundaryViolation(
        'invalid_path',
        'A non-empty relative child path is required.',
      );
    }
    final normalized = p.normalize(relative);
    final parts = p.split(normalized);
    if (parts.any((part) => part == '..' || part.isEmpty)) {
      throw const SanadHomeBoundaryViolation(
        'traversal',
        'The child path escapes its Sanad runtime root.',
      );
    }
    final root = canonicalRoot();
    var current = root;
    for (final part in parts) {
      current = p.join(current, part);
      _rejectLink(current, code: 'symlink_target');
    }
    final absolute = p.normalize(p.absolute(current));
    if (!p.isWithin(root, absolute)) {
      throw const SanadHomeBoundaryViolation(
        'outside_home',
        'The child path escapes its Sanad runtime root.',
      );
    }
    return absolute;
  }

  Future<String> ensureDirectoryPath(String relative) async {
    return ensureDirectoryPathSync(relative);
  }

  String ensureDirectoryPathSync(String relative) {
    final path = child(relative);
    final directory = Directory(path);
    _secureParentsSync(directory);
    return path;
  }

  Future<void> writeSecretBytes(String relative, List<int> bytes) async {
    writeSecretBytesSync(relative, bytes);
  }

  void writeSecretBytesSync(String relative, List<int> bytes) {
    final destination = File(child(relative));
    _secureParentsSync(destination.parent);
    _atomicWriteBytesSync(destination, bytes);
  }

  Future<void> writeConfigText(String relative, String text) =>
      writeSecretBytes(relative, utf8.encode(text));

  List<int> readSecretBytes(String relative) {
    final file = File(child(relative));
    if (!file.existsSync()) {
      throw const SanadHomeBoundaryViolation(
        'missing',
        'The requested Sanad runtime file does not exist.',
      );
    }
    _assertRegularFile(file);
    _enforceSecretOwnershipSync(file);
    return file.readAsBytesSync();
  }

  bool fileExists(String relative) {
    final file = File(child(relative));
    return file.existsSync() &&
        file.statSync().type == FileSystemEntityType.file;
  }

  Future<T> runWithFileLock<T>(
    String relative,
    Future<T> Function() operation, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final lockFile = _openStableLockFileSync(relative);
    try {
      try {
        await lockFile.lock(FileLock.exclusive).timeout(timeout);
      } on TimeoutException {
        throw const SanadHomeWriteFailure(
          'lock_timeout',
          'Timed out waiting for an exclusive Sanad Home file lock.',
        );
      }
      return await operation();
    } finally {
      try {
        await lockFile.unlock();
      } catch (_) {}
      await lockFile.close();
    }
  }

  RandomAccessFile _openStableLockFileSync(String relative) {
    final file = File(child(relative));
    _secureParentsSync(file.parent);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const SanadHomeBoundaryViolation(
        'symlink_target',
        'Symbolic links are not allowed at the Sanad runtime boundary.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      try {
        file.createSync(exclusive: true);
      } on FileSystemException {
        if (!file.existsSync()) rethrow;
      }
    }
    _assertRegularFile(file);
    _enforceSecretOwnershipSync(file);
    return file.openSync(mode: FileMode.append);
  }

  Future<void> deleteFile(String relative) async {
    deleteFileSync(relative);
  }

  void deleteFileSync(String relative) {
    final file = File(child(relative));
    if (!file.existsSync()) return;
    _assertRegularFile(file);
    file.deleteSync();
  }

  Map<String, List<int>> readDirectoryBytesSync(String relative) {
    final root = Directory(child(relative));
    final type = FileSystemEntity.typeSync(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const {};
    if (type != FileSystemEntityType.directory) {
      throw const SanadHomeBoundaryViolation(
        'non_directory',
        'Sanad runtime directory access requires a directory.',
      );
    }
    final files = <String, List<int>>{};
    final entities = root.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      final entityType = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (entityType == FileSystemEntityType.link) {
        throw const SanadHomeBoundaryViolation(
          'symlink_target',
          'Symbolic links are not allowed at the Sanad runtime boundary.',
        );
      }
      if (entityType == FileSystemEntityType.directory) continue;
      if (entityType != FileSystemEntityType.file) {
        throw const SanadHomeBoundaryViolation(
          'non_regular_file',
          'Sanad runtime reads require regular files.',
        );
      }
      final file = File(entity.path);
      _enforceSecretOwnershipSync(file);
      files[p.posix.joinAll(
        p.split(p.relative(entity.path, from: root.path)),
      )] = file
          .readAsBytesSync();
    }
    return files;
  }

  void replaceDirectoryBytesSync(
    String relative,
    Map<String, List<int>> files, {
    Set<String> executablePaths = const {},
  }) {
    if (files.isEmpty) {
      throw const SanadHomeWriteFailure(
        'empty_directory',
        'A managed directory replacement requires at least one file.',
      );
    }
    final destination = Directory(child(relative));
    final parentRelative = p.dirname(relative);
    final parent = Directory(
      parentRelative == '.'
          ? canonicalRoot()
          : ensureDirectoryPathSync(parentRelative),
    );
    _secureParentsSync(parent);
    final nonce = base64Url.encode(
      List<int>.generate(18, (_) => Random.secure().nextInt(256)),
    );
    final stagingRelative = '$relative.sanad-stage-$nonce';
    final backupRelative = '$relative.sanad-backup-$nonce';
    final staging = Directory(child(stagingRelative));
    final backup = Directory(child(backupRelative));
    var movedOld = false;
    try {
      staging.createSync(recursive: true);
      _enforceDirectoryOwnershipSync(staging);
      for (final entry in files.entries) {
        final normalized = p.posix.normalize(entry.key);
        if (p.posix.isAbsolute(entry.key) ||
            normalized != entry.key ||
            p.posix
                .split(normalized)
                .any((part) => part == '..' || part.isEmpty)) {
          throw const SanadHomeBoundaryViolation(
            'invalid_path',
            'Managed directory file paths must be safe relative paths.',
          );
        }
        writeSecretBytesSync(
          p.joinAll([stagingRelative, ...p.posix.split(normalized)]),
          entry.value,
        );
        if (executablePaths.contains(normalized) && !Platform.isWindows) {
          final file = File(
            child(p.joinAll([stagingRelative, ...p.posix.split(normalized)])),
          );
          _chmodSync(file.path, '700', secretDirMode);
        }
      }
      if (FileSystemEntity.typeSync(destination.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const SanadHomeBoundaryViolation(
          'symlink_target',
          'Symbolic links are not allowed at the Sanad runtime boundary.',
        );
      }
      if (destination.existsSync()) {
        destination.renameSync(backup.path);
        movedOld = true;
      }
      staging.renameSync(destination.path);
      if (backup.existsSync()) _deleteStrictChildDirectorySync(backup);
    } on SanadHomeBoundaryViolation {
      if (movedOld && !destination.existsSync() && backup.existsSync()) {
        backup.renameSync(destination.path);
      }
      rethrow;
    } catch (_) {
      if (destination.existsSync() && movedOld && backup.existsSync()) {
        _deleteStrictChildDirectorySync(destination);
      }
      if (movedOld && backup.existsSync()) {
        backup.renameSync(destination.path);
      }
      throw const SanadHomeWriteFailure(
        'directory_replace_failed',
        'The managed directory replacement failed.',
      );
    } finally {
      if (staging.existsSync()) _deleteStrictChildDirectorySync(staging);
      if (backup.existsSync() && destination.existsSync()) {
        _deleteStrictChildDirectorySync(backup);
      }
    }
  }

  void deleteDirectorySync(String relative) {
    final directory = Directory(child(relative));
    if (!directory.existsSync()) return;
    _deleteStrictChildDirectorySync(directory);
  }

  void _deleteStrictChildDirectorySync(Directory directory) {
    final root = canonicalRoot();
    final target = p.normalize(p.absolute(directory.path));
    if (!p.isWithin(root, target) || p.equals(root, target)) {
      throw const SanadHomeBoundaryViolation(
        'delete_outside_home',
        'Managed deletion requires a strict child of Sanad Home.',
      );
    }
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const SanadHomeBoundaryViolation(
        'symlink_target',
        'Symbolic links are not allowed at the Sanad runtime boundary.',
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw const SanadHomeBoundaryViolation(
        'non_directory',
        'Managed deletion requires a directory.',
      );
    }
    directory.deleteSync(recursive: true);
  }

  /// SQLite exception boundary: call before opening `state.db`.
  Future<String> prepareDatabase() async {
    await prepare();
    final path = child('state.db');
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const SanadHomeBoundaryViolation(
        'database_symlink',
        'The state database must not be a symbolic link.',
      );
    }
    if (File(path).existsSync()) await _enforceSecretOwnership(File(path));
    return path;
  }

  String prepareDatabaseSync() {
    _enforceOwnerOnlyProcessUmaskSync();
    final expanded = p.normalize(p.absolute(_expandPath(_configuredRoot)));
    _rejectLink(expanded, code: 'root_symlink');
    final root = Directory(expanded);
    if (!root.existsSync()) root.createSync(recursive: true);
    _enforceDirectoryOwnershipSync(root);
    final path = child('state.db');
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const SanadHomeBoundaryViolation(
        'database_symlink',
        'The state database must not be a symbolic link.',
      );
    }
    if (type == FileSystemEntityType.file) {
      _enforceSecretOwnershipSync(File(path));
    }
    return path;
  }

  /// SQLite exception boundary: call immediately after open and after enabling
  /// journaling, when sidecars may have appeared.
  Future<void> secureDatabaseFiles() async {
    for (final name in const [
      'state.db',
      'state.db-wal',
      'state.db-shm',
      'state.db-journal',
    ]) {
      final path = child(name);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const SanadHomeBoundaryViolation(
          'database_symlink',
          'A state database file must not be a symbolic link.',
        );
      }
      if (type == FileSystemEntityType.file) {
        await _enforceSecretOwnership(File(path));
      }
    }
  }

  void secureDatabaseFilesSync() {
    for (final name in const [
      'state.db',
      'state.db-wal',
      'state.db-shm',
      'state.db-journal',
    ]) {
      final path = child(name);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const SanadHomeBoundaryViolation(
          'database_symlink',
          'A state database file must not be a symbolic link.',
        );
      }
      if (type == FileSystemEntityType.file) {
        _enforceSecretOwnershipSync(File(path));
      }
    }
  }

  void _secureParentsSync(Directory parent) {
    final root = canonicalRoot();
    final relative = p.relative(parent.path, from: root);
    if (relative == '.') {
      _enforceDirectoryOwnershipSync(parent);
      return;
    }
    var current = root;
    for (final part in p.split(relative)) {
      current = p.join(current, part);
      _rejectLink(current, code: 'symlink_target');
      final directory = Directory(current);
      if (!directory.existsSync()) directory.createSync();
      _enforceDirectoryOwnershipSync(directory);
    }
  }

  void _atomicWriteBytesSync(File destination, List<int> bytes) {
    if (destination.existsSync()) _assertRegularFile(destination);
    File? temporary;
    RandomAccessFile? handle;
    try {
      final random = Random.secure();
      for (var attempt = 0; attempt < 16; attempt++) {
        final suffix = List<int>.generate(18, (_) => random.nextInt(256));
        final candidate = File(
          '${destination.path}.tmp.${base64Url.encode(suffix)}',
        );
        if (FileSystemEntity.typeSync(candidate.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        try {
          candidate.createSync(exclusive: true);
          temporary = candidate;
          _rejectLink(candidate.path, code: 'temp_symlink');
          _enforceSecretOwnershipSync(candidate);
          handle = candidate.openSync(mode: FileMode.write);
          break;
        } on FileSystemException {
          continue;
        }
      }
      if (temporary == null || handle == null) {
        throw const SanadHomeWriteFailure(
          'temp_exhausted',
          'Unable to reserve a secure temporary file.',
        );
      }
      handle.writeFromSync(bytes);
      handle.flushSync();
      handle.closeSync();
      handle = null;
      _replaceAtomicallySync(temporary, destination);
      temporary = null;
      _enforceSecretOwnershipSync(destination);
    } on SanadHomeBoundaryViolation {
      rethrow;
    } on SanadHomeWriteFailure {
      rethrow;
    } catch (_) {
      throw const SanadHomeWriteFailure(
        'atomic_write_failed',
        'The secure atomic write failed.',
      );
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {}
      try {
        temporary?.deleteSync();
      } catch (_) {}
    }
  }

  void _replaceAtomicallySync(File source, File destination) {
    if (Platform.isWindows) {
      const script = r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SanadAtomicMove {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool MoveFileExW(
    string existingFile,
    string newFile,
    int flags
  );
}
'@
$source = $env:SANAD_ATOMIC_SOURCE
$destination = $env:SANAD_ATOMIC_DESTINATION
$replaceExisting = 0x1
$writeThrough = 0x8
if (-not [SanadAtomicMove]::MoveFileExW(
  $source,
  $destination,
  ($replaceExisting -bor $writeThrough)
)) {
  throw [ComponentModel.Win32Exception]::new(
    [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  )
}
''';
      final result = Process.runSync(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        environment: {
          'SANAD_ATOMIC_SOURCE': source.path,
          'SANAD_ATOMIC_DESTINATION': destination.path,
        },
      );
      if (result.exitCode != 0) {
        throw const SanadHomeWriteFailure(
          'atomic_replace_failed',
          'The Windows atomic replacement failed.',
        );
      }
      return;
    }
    source.renameSync(destination.path);
  }

  static void _assertRegularFile(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const SanadHomeBoundaryViolation(
        'non_regular_file',
        'Sanad runtime writes require a regular-file destination.',
      );
    }
  }

  static void _rejectLink(String path, {required String code}) {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw SanadHomeBoundaryViolation(
        code,
        'Symbolic links are not allowed at the Sanad runtime boundary.',
      );
    }
  }

  static Future<void> _enforceDirectoryOwnership(Directory directory) async {
    _enforceDirectoryOwnershipSync(directory);
  }

  static Future<void> _enforceSecretOwnership(File file) async {
    _enforceSecretOwnershipSync(file);
  }

  static void _enforceDirectoryOwnershipSync(Directory directory) {
    if (Platform.isWindows) {
      _enforceWindowsAclSync(directory.path, isDirectory: true);
      return;
    }
    _chmodSync(directory.path, '700', secretDirMode);
  }

  static void _enforceSecretOwnershipSync(File file) {
    if (Platform.isWindows) {
      _enforceWindowsAclSync(file.path, isDirectory: false);
      return;
    }
    _chmodSync(file.path, '600', secretFileMode);
  }

  static void _chmodSync(String path, String mode, int expected) {
    if ((FileStat.statSync(path).mode & 0x1ff) == expected) return;
    final result = Process.runSync('chmod', [mode, path]);
    if (result.exitCode != 0 ||
        (FileStat.statSync(path).mode & 0x1ff) != expected) {
      throw const SanadHomeWriteFailure(
        'ownership_enforcement_failed',
        'Owner-only Unix permissions could not be enforced.',
      );
    }
  }

  static void _enforceOwnerOnlyProcessUmaskSync() {
    if (Platform.isWindows || _ownerOnlyUmaskInstalled) return;
    try {
      final umask = DynamicLibrary.process()
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>('umask');
      umask(0x3f); // 0077: new files <= 0600 and directories <= 0700.
      _ownerOnlyUmaskInstalled = true;
    } on Object {
      throw const SanadHomeWriteFailure(
        'umask_enforcement_failed',
        'The owner-only process creation mask could not be installed.',
      );
    }
  }

  static void _enforceWindowsAclSync(String path, {required bool isDirectory}) {
    const script = r'''
$ErrorActionPreference = 'Stop'
$path = $env:SANAD_SECURE_PATH
$kind = $env:SANAD_SECURE_KIND
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ace = if ($kind -eq 'directory') { "(A;OICI;FA;;;$sid)" } else { "(A;;FA;;;$sid)" }
$sddl = "D:P${ace}"
$acl = if ($kind -eq 'directory') {
  [IO.Directory]::GetAccessControl($path)
} else {
  [IO.File]::GetAccessControl($path)
}
$acl.SetSecurityDescriptorSddlForm(
  $sddl,
  [System.Security.AccessControl.AccessControlSections]::Access
)
if ($kind -eq 'directory') {
  [IO.Directory]::SetAccessControl($path, $acl)
} else {
  [IO.File]::SetAccessControl($path, $acl)
}
''';
    final result = Process.runSync(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      environment: {
        'SANAD_SECURE_PATH': path,
        'SANAD_SECURE_KIND': isDirectory ? 'directory' : 'file',
      },
    );
    if (result.exitCode != 0) {
      throw const SanadHomeWriteFailure(
        'acl_enforcement_failed',
        'Owner-only Windows ACL enforcement failed.',
      );
    }
  }

  static String _expandPath(String value) {
    if (value == '~' || value.startsWith('~/')) {
      final userHome =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (userHome == null || userHome.isEmpty) {
        throw const SanadHomeBoundaryViolation(
          'home_environment_missing',
          'The current user home could not be resolved.',
        );
      }
      return p.join(userHome, value.substring(1));
    }
    return value;
  }

  // Compatibility surface for already-landed local-gateway callers.
  static String canonicalHome() => identity().canonicalRoot();
  static String canonicalStateHome() => state().canonicalRoot();
  static String resolveChild(String relative) => identity().child(relative);
  static Future<String> ensureDirectory(String relative) =>
      identity().ensureDirectoryPath(relative);
  static Future<void> writeSecret(String relative, List<int> bytes) =>
      identity().writeSecretBytes(relative, bytes);
  static Future<void> writeConfig(String relative, String text) =>
      identity().writeConfigText(relative, text);
  static List<int> readSecret(String relative) =>
      identity().readSecretBytes(relative);
  static bool exists(String relative) => identity().fileExists(relative);
}
