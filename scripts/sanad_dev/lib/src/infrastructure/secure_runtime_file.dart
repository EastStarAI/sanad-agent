import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'windows_secure_runtime_backend.dart';

WindowsSecureRuntimeBackend? _windowsBackendInstance;
WindowsSecureRuntimeBackend get _windowsBackend =>
    _windowsBackendInstance ??= WindowsSecureRuntimeBackend();

class SecureRuntimeFileException implements Exception {
  const SecureRuntimeFileException(this.code);

  final String code;

  @override
  String toString() => 'SecureRuntimeFileException($code)';
}

Future<void> secureRuntimeDirectory(String sanadHome, String path) async {
  final directory = await _validatedDirectory(sanadHome, path);
  await _restrictRuntimePath(directory.path, directory: true);
}

Future<void> secureRuntimeAtomicWrite(
  String sanadHome,
  String path,
  String contents,
) async {
  final destination = await _validatedFile(sanadHome, path, allowMissing: true);
  final suffix = List<int>.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final temporary = File('${destination.path}.tmp.$suffix');
  RandomAccessFile? handle;
  try {
    await temporary.create(exclusive: true);
    await _restrictRuntimePath(temporary.path);
    handle = await temporary.open(mode: FileMode.writeOnly);
    await handle.writeString(contents);
    await handle.flush();
    await handle.close();
    handle = null;
    await _replaceRuntimeFile(temporary, destination);
    // POSIX rename preserves the already-restricted temporary inode. Avoid a
    // second chmod after publication because a waiting consumer may delete the
    // completed request immediately after the atomic rename.
    if (Platform.isWindows) {
      await _restrictRuntimePath(destination.path);
    }
  } on SecureRuntimeFileException {
    rethrow;
  } on Object {
    throw const SecureRuntimeFileException('atomic_write_failed');
  } finally {
    try {
      await handle?.close();
    } on Object {}
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {}
  }
}

Future<void> _replaceRuntimeFile(File source, File destination) async {
  if (!Platform.isWindows) {
    await source.rename(destination.path);
    return;
  }
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      _windowsBackend.replaceFile(source.path, destination.path);
      return;
    } catch (_) {
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }
  throw const SecureRuntimeFileException('atomic_replace_failed');
}

Future<File> secureRuntimeAppendFile(String sanadHome, String path) async {
  final file = await _validatedFile(sanadHome, path, allowMissing: true);
  if (!await file.exists()) {
    await file.create(exclusive: true);
    await _restrictRuntimePath(file.path);
    final handle = await file.open(mode: FileMode.writeOnly);
    await handle.flush();
    await handle.close();
  } else {
    await _restrictRuntimePath(file.path);
  }
  return file;
}

Future<String> secureRuntimeReadText(String root, String path) async {
  final file = await _validatedFile(root, path, allowMissing: false);
  await _restrictRuntimePath(file.path);
  return file.readAsString();
}

Future<Directory> _validatedDirectory(String sanadHome, String path) async {
  final root = Directory(p.normalize(p.absolute(sanadHome)));
  final rootType = await FileSystemEntity.type(root.path, followLinks: false);
  if (rootType == FileSystemEntityType.link ||
      (rootType != FileSystemEntityType.notFound &&
          rootType != FileSystemEntityType.directory)) {
    throw const SecureRuntimeFileException('unsafe_home');
  }
  if (rootType == FileSystemEntityType.notFound) {
    await root.create(recursive: true);
  }
  await _restrictRuntimePath(root.path, directory: true);
  final canonicalRoot = await root.resolveSymbolicLinks();
  final absolute = p.normalize(p.absolute(path));
  final configuredRoot = root.path;
  final isRoot = p.equals(configuredRoot, absolute);
  if (!isRoot && !p.isWithin(configuredRoot, absolute)) {
    throw const SecureRuntimeFileException('outside_home');
  }
  var current = canonicalRoot;
  final relative = isRoot ? '' : p.relative(absolute, from: configuredRoot);
  if (relative.isNotEmpty) {
    for (final segment in relative.split(Platform.pathSeparator)) {
      current = '$current${Platform.pathSeparator}$segment';
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory)) {
        throw const SecureRuntimeFileException('unsafe_directory');
      }
      final directory = Directory(current);
      if (type == FileSystemEntityType.notFound) await directory.create();
      await _restrictRuntimePath(directory.path, directory: true);
    }
  }
  return Directory(current);
}

Future<File> _validatedFile(
  String sanadHome,
  String path, {
  required bool allowMissing,
}) async {
  final requested = File(path).absolute;
  final parent = await _validatedDirectory(sanadHome, requested.parent.path);
  final file = File(
    '${parent.path}${Platform.pathSeparator}${requested.uri.pathSegments.last}',
  );
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.link ||
      (type != FileSystemEntityType.file &&
          (!allowMissing || type != FileSystemEntityType.notFound))) {
    throw const SecureRuntimeFileException('unsafe_file');
  }
  return file;
}

Future<void> _restrictRuntimePath(String path, {bool directory = false}) async {
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', [
      directory ? '700' : '600',
      path,
    ]);
    if (result.exitCode != 0) {
      throw const SecureRuntimeFileException('ownership_failed');
    }
    return;
  }
  try {
    _windowsBackend.restrictPath(path, directory: directory);
  } catch (_) {
    throw const SecureRuntimeFileException('ownership_failed');
  }
}
