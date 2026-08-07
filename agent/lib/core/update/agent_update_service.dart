import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sanad_release_contract/release_contract.dart';

enum AgentUpdateStatus {
  upToDate('up_to_date'),
  updateAvailable('update_available'),
  restartRequired('restart_required'),
  sourceManaged('source_managed'),
  networkFailed('network_failed'),
  manifestInvalid('manifest_invalid'),
  targetMismatch('target_mismatch'),
  downgradeRejected('downgrade_rejected'),
  unsupportedTarget('unsupported_target'),
  trustFailed('trust_failed'),
  checksumFailed('checksum_failed'),
  scheduleFailed('schedule_failed'),
  replacementFailed('replacement_failed'),
  rollbackCompleted('rollback_completed'),
  startFailed('start_failed'),
  healthFailed('health_failed'),
  versionFailed('version_failed'),
  authFailed('auth_failed'),
  failed('failed');

  const AgentUpdateStatus(this.wireName);
  final String wireName;
}

class AgentUpdateResult {
  const AgentUpdateResult({
    required this.status,
    required this.currentVersion,
    this.availableVersion,
    this.message,
    this.stagedPath,
  });

  final AgentUpdateStatus status;
  final String currentVersion;
  final String? availableVersion;
  final String? message;
  final String? stagedPath;

  bool get isSuccess => switch (status) {
    AgentUpdateStatus.upToDate ||
    AgentUpdateStatus.updateAvailable ||
    AgentUpdateStatus.restartRequired ||
    AgentUpdateStatus.sourceManaged => true,
    _ => false,
  };

  AgentUpdateResult copyWith({
    AgentUpdateStatus? status,
    String? message,
    String? stagedPath,
  }) => AgentUpdateResult(
    status: status ?? this.status,
    currentVersion: currentVersion,
    availableVersion: availableVersion,
    message: message ?? this.message,
    stagedPath: stagedPath ?? this.stagedPath,
  );

  Map<String, dynamic> toJson() => {
    'success': isSuccess,
    'status': status.wireName,
    'current_version': currentVersion,
    if (availableVersion != null) 'available_version': availableVersion,
    if (message != null) 'message': message,
  };
}

class AgentUpdateService {
  static final Map<String, Future<AgentUpdateResult>> _inFlightUpdates = {};

  AgentUpdateService({
    required this.currentVersion,
    required this.executablePath,
    required this.isSourceManaged,
    http.Client? client,
    Uri? manifestUri,
    String? operatingSystem,
    String? architecture,
    PlatformArtifactVerifier? platformVerifier,
  }) : _client = client ?? http.Client(),
       manifestUri =
           manifestUri ??
           Uri.parse(
             'https://github.com/EastStarAI/sanad-agent/releases/latest/download/release-manifest.json',
           ),
       operatingSystem = operatingSystem ?? Platform.operatingSystem,
       architecture = architecture ?? _detectArchitecture(),
       _platformVerifier = platformVerifier ?? verifyPlatformCodeSignature;

  final String currentVersion;
  final String executablePath;
  final bool isSourceManaged;
  final Uri manifestUri;
  final String operatingSystem;
  final String architecture;
  final http.Client _client;
  final PlatformArtifactVerifier _platformVerifier;

  Future<AgentUpdateResult> check({String? targetVersion}) async {
    if (isSourceManaged) return _sourceManaged();
    final targetGate = _targetGate(targetVersion);
    if (targetGate != null) return targetGate;
    try {
      final manifest = await _fetchManifest();
      final mismatch = _manifestTargetGate(manifest, targetVersion);
      if (mismatch != null) return mismatch;
      final available = manifest.version.toString();
      final current = ReleaseVersion.parse(currentVersion);
      if (manifest.version.compareTo(current) <= 0) {
        return AgentUpdateResult(
          status: AgentUpdateStatus.upToDate,
          currentVersion: currentVersion,
          availableVersion: available,
        );
      }
      if (_selectArtifact(manifest) == null) {
        return _result(AgentUpdateStatus.unsupportedTarget, available);
      }
      return _result(AgentUpdateStatus.updateAvailable, available);
    } on FormatException catch (error) {
      return _error(AgentUpdateStatus.manifestInvalid, error.message);
    } on HttpException catch (error) {
      return _error(AgentUpdateStatus.networkFailed, error.message);
    } catch (error) {
      return _error(
        AgentUpdateStatus.networkFailed,
        'Unable to check for updates: $error',
      );
    }
  }

  Future<AgentUpdateResult> update({String? targetVersion}) async {
    final existing = _inFlightUpdates[executablePath];
    if (existing != null) return existing;
    final operation = _update(targetVersion: targetVersion);
    _inFlightUpdates[executablePath] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlightUpdates[executablePath], operation)) {
        _inFlightUpdates.remove(executablePath);
      }
    }
  }

  Future<AgentUpdateResult> _update({String? targetVersion}) async {
    if (isSourceManaged) return _sourceManaged();
    final targetGate = _targetGate(targetVersion);
    if (targetGate != null) return targetGate;
    RandomAccessFile? lockHandle;
    File? stagedFile;
    var preserveStagedFile = false;
    try {
      final manifest = await _fetchManifest();
      final mismatch = _manifestTargetGate(manifest, targetVersion);
      if (mismatch != null) return mismatch;
      final available = manifest.version.toString();
      final current = ReleaseVersion.parse(currentVersion);
      if (manifest.version.compareTo(current) <= 0) {
        return _result(AgentUpdateStatus.upToDate, available);
      }
      final artifact = _selectArtifact(manifest);
      if (artifact == null) {
        return _result(AgentUpdateStatus.unsupportedTarget, available);
      }

      final executable = File(executablePath);
      await executable.parent.create(recursive: true);
      lockHandle = await File(
        '$executablePath.update.lock',
      ).open(mode: FileMode.write);
      await lockHandle.lock(FileLock.exclusive);

      final staged = File('$executablePath.${manifest.version}.staged');
      stagedFile = staged;
      if (staged.existsSync()) await staged.delete();
      final response = await _client.send(http.Request('GET', artifact.url));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Artifact download failed with HTTP ${response.statusCode}.',
        );
      }
      final sink = staged.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
      }
      await sink.close();

      if (received != artifact.size ||
          await sha256OfFile(staged) != artifact.sha256) {
        return _result(
          AgentUpdateStatus.checksumFailed,
          available,
          message: 'Downloaded artifact failed size or SHA-256 verification.',
        );
      }
      if (!await verifyReleaseArtifactTrust(
        staged,
        artifact: artifact,
        platformVerifier: _platformVerifier,
      )) {
        return _result(
          AgentUpdateStatus.trustFailed,
          available,
          message:
              'Downloaded artifact failed the declared platform trust policy.',
        );
      }

      if (operatingSystem == 'windows') {
        preserveStagedFile = true;
        return AgentUpdateResult(
          status: AgentUpdateStatus.restartRequired,
          currentVersion: currentVersion,
          availableVersion: available,
          message: 'Verified update staged for replacement during restart.',
          stagedPath: staged.path,
        );
      }

      final backup = File('$executablePath.rollback');
      if (backup.existsSync()) await backup.delete();
      if (executable.existsSync()) await executable.rename(backup.path);
      try {
        await staged.rename(executable.path);
        final chmod = await Process.run('chmod', ['700', executable.path]);
        if (chmod.exitCode != 0) {
          throw const FileSystemException('Unable to mark update executable.');
        }
      } catch (error) {
        if (executable.existsSync()) await executable.delete();
        if (backup.existsSync()) await backup.rename(executable.path);
        return _result(
          AgentUpdateStatus.rollbackCompleted,
          available,
          message:
              'Replacement failed; the previous executable was restored: $error',
        );
      }

      return _result(
        AgentUpdateStatus.restartRequired,
        available,
        message: 'Verified update installed. Restart the Sanad service.',
      );
    } on FormatException catch (error) {
      return _error(AgentUpdateStatus.manifestInvalid, error.message);
    } on HttpException catch (error) {
      return _error(AgentUpdateStatus.networkFailed, error.message);
    } catch (error) {
      return _error(AgentUpdateStatus.failed, 'Update failed: $error');
    } finally {
      if (!preserveStagedFile && stagedFile?.existsSync() == true) {
        await stagedFile!.delete();
      }
      if (lockHandle != null) {
        await lockHandle.unlock();
        await lockHandle.close();
      }
    }
  }

  AgentUpdateResult? _targetGate(String? targetVersion) {
    if (targetVersion == null) return null;
    final target = ReleaseVersion.parse(targetVersion);
    final current = ReleaseVersion.parse(currentVersion);
    final comparison = current.compareTo(target);
    if (comparison > 0) {
      return AgentUpdateResult(
        status: AgentUpdateStatus.downgradeRejected,
        currentVersion: currentVersion,
        availableVersion: target.toString(),
        message: 'Automatic downgrade from $current to $target is not allowed.',
      );
    }
    if (comparison == 0) {
      return AgentUpdateResult(
        status: AgentUpdateStatus.upToDate,
        currentVersion: currentVersion,
        availableVersion: target.toString(),
      );
    }
    return null;
  }

  AgentUpdateResult? _manifestTargetGate(
    ReleaseManifest manifest,
    String? targetVersion,
  ) {
    if (targetVersion == null) return null;
    final target = ReleaseVersion.parse(targetVersion);
    if (manifest.version.compareTo(target) == 0) return null;
    return AgentUpdateResult(
      status: AgentUpdateStatus.targetMismatch,
      currentVersion: currentVersion,
      availableVersion: manifest.version.toString(),
      message:
          'Manifest ${manifest.version} does not match requested target $target.',
    );
  }

  AgentUpdateResult _sourceManaged() => AgentUpdateResult(
    status: AgentUpdateStatus.sourceManaged,
    currentVersion: currentVersion,
    message: 'This agent runs from source and remains developer-managed.',
  );

  AgentUpdateResult _result(
    AgentUpdateStatus status,
    String availableVersion, {
    String? message,
  }) => AgentUpdateResult(
    status: status,
    currentVersion: currentVersion,
    availableVersion: availableVersion,
    message: message,
  );

  AgentUpdateResult _error(AgentUpdateStatus status, String message) =>
      AgentUpdateResult(
        status: status,
        currentVersion: currentVersion,
        message: message,
      );

  Future<bool> scheduleWindowsReplacement(AgentUpdateResult result) async {
    final stagedPath = result.stagedPath;
    if (stagedPath == null || operatingSystem != 'windows') return false;
    final escapedExecutable = executablePath.replaceAll("'", "''");
    final escapedStaged = stagedPath.replaceAll("'", "''");
    final script =
        r'''
$ErrorActionPreference = 'Stop'
$target = '__TARGET__'
$staged = '__STAGED__'
$backup = "$target.rollback"
$deadline = (Get-Date).AddSeconds(60)
$ready = $false
while ((Get-Date) -lt $deadline) {
  try {
    if (Test-Path $backup) { Remove-Item -LiteralPath $backup -Force }
    if (Test-Path $target) { Move-Item -LiteralPath $target -Destination $backup -Force }
    $ready = $true
    break
  } catch {
    Start-Sleep -Milliseconds 500
  }
}
if (-not $ready) { exit 1 }
try {
  Move-Item -LiteralPath $staged -Destination $target -Force
  & $target service start
  if ($LASTEXITCODE -ne 0) { throw 'Service restart failed.' }
  exit 0
} catch {
  if (Test-Path $target) { Remove-Item -LiteralPath $target -Force }
  if (Test-Path $backup) {
    Move-Item -LiteralPath $backup -Destination $target -Force
    & $target service start
  }
  exit 1
}
'''
            .replaceFirst('__TARGET__', escapedExecutable)
            .replaceFirst('__STAGED__', escapedStaged);
    final bytes = BytesBuilder(copy: false);
    for (final codeUnit in script.codeUnits) {
      bytes.add([codeUnit & 0xff, codeUnit >> 8]);
    }
    try {
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          base64Encode(bytes.takeBytes()),
        ],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<ReleaseManifest> _fetchManifest() async {
    final response = await _client.get(
      manifestUri,
      headers: const {'User-Agent': 'sanad-agent'},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Manifest request failed with HTTP ${response.statusCode}.',
      );
    }
    return ReleaseManifest.fromJsonString(utf8.decode(response.bodyBytes));
  }

  ReleaseArtifact? _selectArtifact(ReleaseManifest manifest) =>
      manifest.findArtifact(
        component: 'agent',
        platform: operatingSystem == 'macos' ? 'macos' : operatingSystem,
        architecture: architecture,
        publicOnly: true,
      );

  static String _detectArchitecture() {
    final value = Abi.current().toString().toLowerCase();
    return value.contains('arm64') ? 'arm64' : 'x64';
  }
}
