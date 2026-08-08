import 'dart:io';
import 'dart:math';

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
  final result = await Process.run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    environment: {
      'SANAD_ATOMIC_SOURCE': source.path,
      'SANAD_ATOMIC_DESTINATION': destination.path,
    },
  );
  if (result.exitCode != 0) {
    throw const SecureRuntimeFileException('atomic_replace_failed');
  }
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
  final root = Directory(sanadHome).absolute;
  final rootType = await FileSystemEntity.type(root.path, followLinks: false);
  if (rootType == FileSystemEntityType.link ||
      (rootType != FileSystemEntityType.notFound && rootType != FileSystemEntityType.directory)) {
    throw const SecureRuntimeFileException('unsafe_home');
  }
  if (rootType == FileSystemEntityType.notFound) {
    await root.create(recursive: true);
  }
  await _restrictRuntimePath(root.path, directory: true);
  final canonicalRoot = await root.resolveSymbolicLinks();
  final absolute = Directory(path).absolute.path;
  final configuredRoot = root.path;
  final rootPrefix = configuredRoot.endsWith(Platform.pathSeparator)
      ? configuredRoot
      : '$configuredRoot${Platform.pathSeparator}';
  if (configuredRoot != absolute && !absolute.startsWith(rootPrefix)) {
    throw const SecureRuntimeFileException('outside_home');
  }
  var current = canonicalRoot;
  final relative = configuredRoot == absolute ? '' : absolute.substring(rootPrefix.length);
  if (relative.isNotEmpty) {
    for (final segment in relative.split(Platform.pathSeparator)) {
      current = '$current${Platform.pathSeparator}$segment';
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory)) {
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
      (type != FileSystemEntityType.file && (!allowMissing || type != FileSystemEntityType.notFound))) {
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
  final result = await Process.run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    environment: {
      'SANAD_SECURE_PATH': path,
      'SANAD_SECURE_KIND': directory ? 'directory' : 'file',
    },
  );
  if (result.exitCode != 0) {
    throw const SecureRuntimeFileException('ownership_failed');
  }
}
