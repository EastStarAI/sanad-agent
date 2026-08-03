import 'dart:io';
import 'dart:math';

class SecureSanadHomeViolation implements Exception {
  const SecureSanadHomeViolation(this.code);

  final String code;

  @override
  String toString() => 'SecureSanadHomeViolation($code)';
}

class SecureSanadHomeWriter {
  const SecureSanadHomeWriter(this.sanadHomePath);

  final String sanadHomePath;

  Future<File> resolveFile(String relativeName) async {
    if (relativeName.isEmpty ||
        relativeName.contains('\u0000') ||
        relativeName == '..' ||
        relativeName.contains('/') ||
        relativeName.contains('\\')) {
      throw const SecureSanadHomeViolation('invalid_relative_path');
    }
    final home = await _secureHome();
    final file = File('${home.path}${Platform.pathSeparator}$relativeName');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file)) {
      throw const SecureSanadHomeViolation('unsafe_target');
    }
    return file;
  }

  Future<void> writeText(String relativeName, String content) async {
    final destination = await resolveFile(relativeName);
    final suffix = List<int>.generate(
      12,
      (_) => Random.secure().nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final temporary = File('${destination.path}.tmp.$suffix');
    RandomAccessFile? handle;
    try {
      await temporary.create(exclusive: true);
      await _secureFile(temporary);
      handle = await temporary.open(mode: FileMode.writeOnly);
      await handle.writeString(content);
      await handle.flush();
      await handle.close();
      handle = null;
      await _replaceAtomically(temporary, destination);
      await _secureFile(destination);
    } on SecureSanadHomeViolation {
      rethrow;
    } on Object {
      throw const SecureSanadHomeViolation('atomic_write_failed');
    } finally {
      try {
        await handle?.close();
      } on Object {
        // Best-effort cleanup after a failed secure write.
      }
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // Best-effort cleanup after a failed secure write.
      }
    }
  }

  Future<void> _replaceAtomically(File source, File destination) async {
    if (!Platform.isWindows) {
      await source.rename(destination.path);
      return;
    }
    const script = r'''
$ErrorActionPreference = 'Stop'
$source = $env:SANAD_ATOMIC_SOURCE
$destination = $env:SANAD_ATOMIC_DESTINATION
if ([IO.File]::Exists($destination)) {
  [IO.File]::Replace($source, $destination, $null, $true)
} else {
  [IO.File]::Move($source, $destination)
}
''';
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ],
      environment: {
        'SANAD_ATOMIC_SOURCE': source.path,
        'SANAD_ATOMIC_DESTINATION': destination.path,
      },
    );
    if (result.exitCode != 0) {
      throw const SecureSanadHomeViolation('atomic_replace_failed');
    }
  }

  Future<void> delete(String relativeName) async {
    final file = await resolveFile(relativeName);
    if (await file.exists()) await file.delete();
  }

  Future<Directory> _secureHome() async {
    final raw = Directory(sanadHomePath).absolute;
    final existingType = await FileSystemEntity.type(
      raw.path,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.link ||
        (existingType != FileSystemEntityType.notFound && existingType != FileSystemEntityType.directory)) {
      throw const SecureSanadHomeViolation('unsafe_home');
    }
    if (existingType == FileSystemEntityType.notFound) {
      await raw.create(recursive: true);
    }
    await _secureDirectory(raw);
    final resolved = Directory(await raw.resolveSymbolicLinks());
    return resolved;
  }

  Future<void> _secureDirectory(Directory directory) async {
    await _applyOwnership(directory.path, unixMode: '700');
  }

  Future<void> _secureFile(File file) async {
    await _applyOwnership(file.path, unixMode: '600');
  }

  Future<void> _applyOwnership(
    String path, {
    required String unixMode,
  }) async {
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', [unixMode, path]);
      if (result.exitCode != 0) {
        throw const SecureSanadHomeViolation('ownership_failed');
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
$acl = Get-Acl -LiteralPath $path
$acl.SetSecurityDescriptorSddlForm(
  $sddl,
  [System.Security.AccessControl.AccessControlSections]::Access
)
Set-Acl -LiteralPath $path -AclObject $acl
''';
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ],
      environment: {
        'SANAD_SECURE_PATH': path,
        'SANAD_SECURE_KIND': unixMode == '700' ? 'directory' : 'file',
      },
    );
    if (result.exitCode != 0) {
      throw const SecureSanadHomeViolation('ownership_failed');
    }
  }
}
