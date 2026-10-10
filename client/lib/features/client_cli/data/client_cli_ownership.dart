import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/models/client_cli_exceptions.dart';
import '../domain/models/client_cli_record.dart';

class ClientCliOwnership {
  final Future<bool> Function(int pid)? processAliveChecker;
  final Future<bool> Function(String host, int port, String token)? healthProber;

  const ClientCliOwnership({
    this.processAliveChecker,
    this.healthProber,
  });

  static const String runtimeDirName = 'runtime';
  static const String recordFileName = 'client_cli.json';

  String recordPath(String sanadHome) =>
      p.join(p.normalize(p.absolute(sanadHome)), runtimeDirName, recordFileName);

  String runtimeDirPath(String sanadHome) =>
      p.join(p.normalize(p.absolute(sanadHome)), runtimeDirName);

  /// Checks if a process is alive.
  Future<bool> isProcessAlive(int pid) async {
    if (processAliveChecker != null) {
      return processAliveChecker!(pid);
    }
    if (pid <= 0) return false;
    try {
      if (!Platform.isWindows) {
        // kill -0 checks process existence without sending a signal
        final result = await Process.run('kill', ['-0', '$pid']);
        return result.exitCode == 0;
      } else {
        final result = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
        return result.stdout.toString().contains('$pid');
      }
    } catch (_) {
      return false;
    }
  }

  /// Probes the loopback health endpoint to verify a live Client.
  Future<bool> probeHealth(String host, int port, String token) async {
    if (healthProber != null) {
      return healthProber!(host, port, token);
    }
    final client = http.Client();
    try {
      final uri = Uri.parse('http://$host:$port/health');
      final response = await client.get(
        uri,
        headers: {
          'x-sanad-client-token': token,
          'authorization': 'Bearer $token',
        },
      ).timeout(const Duration(milliseconds: 500));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['status'] == 'ok') {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Reads the active runtime record for the given Sanad Home.
  Future<ClientCliRecord?> readRecord(
    String sanadHome, {
    bool verifyPermissions = true,
  }) async {
    final file = File(recordPath(sanadHome));
    if (!await file.exists()) {
      return null;
    }

    if (verifyPermissions && !Platform.isWindows) {
      final stat = await file.stat();
      final mode = stat.mode & 0x1ff;
      // Must be 0600 (owner read/write only, no group or other permissions, no execute)
      if ((mode & 0x7f) != 0) {
        throw ClientCliSecurityException(
          'Runtime record has insecure permissions (${mode.toRadixString(8)}). Expected 0600.',
        );
      }
    }

    try {
      final content = (await file.readAsString()).trim();
      if (content.isEmpty) return null;
      final json = jsonDecode(content) as Map<String, dynamic>;
      return ClientCliRecord.fromJson(json);
    } on ClientCliSecurityException {
      rethrow;
    } catch (e) {
      throw ClientCliSecurityException('Failed to read runtime record: $e');
    }
  }

  /// Acquires ownership and writes the runtime record.
  /// If a stale record exists from a terminated process, it is cleaned up automatically.
  /// If another active process owns this Home, throws [ClientCliAmbiguousOwnerException].
  Future<void> acquireOwnership(ClientCliRecord record) async {
    final existing = await readRecord(record.sanadHome, verifyPermissions: false);
    if (existing != null) {
      final alive = await isProcessAlive(existing.pid);
      if (alive && existing.pid != record.pid) {
        // Probe health endpoint to be sure
        final healthy = await probeHealth('127.0.0.1', existing.port, existing.token);
        if (healthy) {
          throw ClientCliAmbiguousOwnerException(
            record.sanadHome,
            'Another live Sanad Client (PID ${existing.pid}) already owns this Home',
          );
        }
      }
      // If dead or unhealthy, stale owner cleanup!
      await releaseOwnership(record.sanadHome);
    }

    // Ensure runtime directory exists with restricted permissions
    final dir = Directory(runtimeDirPath(record.sanadHome));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _applyOwnership(dir.path, unixMode: '700');

    // Write file atomically
    await _writeAtomicSecure(recordPath(record.sanadHome), jsonEncode(record.toJson()));
  }

  /// Releases ownership by deleting the runtime record if it exists and belongs to the current PID (or any PID if null).
  Future<void> releaseOwnership(String sanadHome, {int? pid}) async {
    final file = File(recordPath(sanadHome));
    if (!await file.exists()) return;

    if (pid != null) {
      try {
        final existing = await readRecord(sanadHome, verifyPermissions: false);
        if (existing != null && existing.pid != pid) {
          return; // Owned by someone else, do not delete
        }
      } catch (_) {}
    }

    try {
      await file.delete();
    } catch (_) {}
  }

  Future<void> _writeAtomicSecure(String targetPath, String content) async {
    final destination = File(targetPath);
    final suffix = List<int>.generate(
      12,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final temporary = File('${destination.path}.tmp.$suffix');

    try {
      await temporary.create(exclusive: true);
      await _applyOwnership(temporary.path, unixMode: '600');
      await temporary.writeAsString(content, flush: true);
      await _replaceAtomically(temporary, destination);
      await _applyOwnership(destination.path, unixMode: '600');
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
  }

  Future<void> _replaceAtomically(File source, File destination) async {
    if (!Platform.isWindows) {
      await source.rename(destination.path);
      return;
    }

    // Windows atomic move script
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
      throw ClientCliSecurityException('Atomic replace failed on Windows');
    }
  }

  Future<void> _applyOwnership(String path, {required String unixMode}) async {
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', [unixMode, path]);
      if (result.exitCode != 0) {
        throw ClientCliSecurityException('chmod $unixMode failed on $path');
      }
      return;
    }

    // Windows ACL restriction using PowerShell SDDL
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
        'SANAD_SECURE_KIND': unixMode == '700' ? 'directory' : 'file',
      },
    );
    if (result.exitCode != 0) {
      throw ClientCliSecurityException('Windows ACL restriction failed on $path');
    }
  }
}
