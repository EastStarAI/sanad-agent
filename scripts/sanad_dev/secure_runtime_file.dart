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
    await _restrictRuntimePath(destination.path);
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
if ([IO.File]::Exists($args[1])) {
  [IO.File]::Replace($args[0], $args[1], $null, $true)
} else {
  [IO.File]::Move($args[0], $args[1])
}
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
    source.path,
    destination.path,
  ]);
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
      (rootType != FileSystemEntityType.notFound &&
          rootType != FileSystemEntityType.directory)) {
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
  final relative = configuredRoot == absolute
      ? ''
      : absolute.substring(rootPrefix.length);
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
  final whoami = await Process.run('whoami', const []);
  final owner = whoami.stdout.toString().trim();
  if (whoami.exitCode != 0 || owner.isEmpty) {
    throw const SecureRuntimeFileException('owner_unavailable');
  }
  final securityType = directory ? 'DirectorySecurity' : 'FileSecurity';
  final inheritance = directory ? 'ContainerInherit,ObjectInherit' : 'None';
  const script = r'''
$ErrorActionPreference = 'Stop'
$owner = New-Object System.Security.Principal.NTAccount($args[1])
$acl = New-Object ("System.Security.AccessControl." + $args[2])
$acl.SetOwner($owner)
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($owner, 'FullControl', $args[3], 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $args[0] -AclObject $acl
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
    path,
    owner,
    securityType,
    inheritance,
  ]);
  if (result.exitCode != 0) {
    throw const SecureRuntimeFileException('ownership_failed');
  }
}
