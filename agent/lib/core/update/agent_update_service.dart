import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_release_contract/release_contract.dart';

const _defaultReleaseManifestUrl = String.fromEnvironment(
  'SANAD_RELEASE_MANIFEST_URL',
  defaultValue:
      'https://github.com/EastStarAI/sanad-agent/releases/latest/download/release-manifest.json',
);
const _defaultReleaseArtifactMirrorUrl = String.fromEnvironment(
  'SANAD_RELEASE_ARTIFACT_MIRROR_URL',
);

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
    this.manifestTag,
    this.manifestCommit,
  });

  final AgentUpdateStatus status;
  final String currentVersion;
  final String? availableVersion;
  final String? message;
  final String? stagedPath;
  final String? manifestTag;
  final String? manifestCommit;

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
    manifestTag: manifestTag,
    manifestCommit: manifestCommit,
  );

  Map<String, dynamic> toJson() => {
    'success': isSuccess,
    'status': status.wireName,
    'current_version': currentVersion,
    if (availableVersion != null) 'available_version': availableVersion,
    if (message != null) 'message': message,
    if (manifestTag != null) 'manifest_revision': manifestTag,
    if (manifestCommit != null) 'manifest_fingerprint': manifestCommit,
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
    Future<bool> Function(String script)? replacementScheduler,
    Uri? artifactMirrorUri,
  }) : _client = client ?? http.Client(),
       manifestUri = manifestUri ?? Uri.parse(_defaultReleaseManifestUrl),
       operatingSystem = operatingSystem ?? Platform.operatingSystem,
       architecture = architecture ?? _detectArchitecture(),
       _platformVerifier = platformVerifier ?? verifyPlatformCodeSignature,
       _replacementScheduler = replacementScheduler,
       _artifactMirrorUri =
           artifactMirrorUri ??
           (_defaultReleaseArtifactMirrorUrl.trim().isEmpty
               ? null
               : Uri.parse(_defaultReleaseArtifactMirrorUrl));

  final String currentVersion;
  final String executablePath;
  final bool isSourceManaged;
  final Uri manifestUri;
  final String operatingSystem;
  final String architecture;
  final http.Client _client;
  final PlatformArtifactVerifier _platformVerifier;
  final Future<bool> Function(String script)? _replacementScheduler;
  final Uri? _artifactMirrorUri;

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
          manifestTag: manifest.tag,
          manifestCommit: manifest.commit,
        );
      }
      if (_selectArtifact(manifest) == null) {
        return _result(
          AgentUpdateStatus.unsupportedTarget,
          available,
          manifestTag: manifest.tag,
          manifestCommit: manifest.commit,
        );
      }
      return _result(
        AgentUpdateStatus.updateAvailable,
        available,
        manifestTag: manifest.tag,
        manifestCommit: manifest.commit,
      );
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

  Future<AgentUpdateResult> update({
    String? targetVersion,
    String? expectedManifestTag,
    String? expectedManifestCommit,
  }) async {
    final existing = _inFlightUpdates[executablePath];
    if (existing != null) return existing;
    final operation = _update(
      targetVersion: targetVersion,
      expectedManifestTag: expectedManifestTag,
      expectedManifestCommit: expectedManifestCommit,
    );
    _inFlightUpdates[executablePath] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlightUpdates[executablePath], operation)) {
        _inFlightUpdates.remove(executablePath);
      }
    }
  }

  Future<AgentUpdateResult> _update({
    String? targetVersion,
    String? expectedManifestTag,
    String? expectedManifestCommit,
  }) async {
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
      final revisionMismatch = _manifestRevisionGate(
        manifest,
        expectedTag: expectedManifestTag,
        expectedCommit: expectedManifestCommit,
      );
      if (revisionMismatch != null) return revisionMismatch;
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
      final downloadUri =
          _artifactMirrorUri?.resolve(artifact.filename) ?? artifact.url;
      final response = await _client.send(http.Request('GET', downloadUri));
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
        if (!Platform.isWindows) {
          final chmod = await Process.run('chmod', ['700', executable.path]);
          if (chmod.exitCode != 0) {
            throw const FileSystemException(
              'Unable to mark update executable.',
            );
          }
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
    } on http.ClientException catch (error) {
      return _error(AgentUpdateStatus.networkFailed, error.message);
    } on SocketException catch (error) {
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

  AgentUpdateResult? _manifestRevisionGate(
    ReleaseManifest manifest, {
    String? expectedTag,
    String? expectedCommit,
  }) {
    if (expectedTag == null && expectedCommit == null) return null;
    if (manifest.tag == expectedTag && manifest.commit == expectedCommit) {
      return null;
    }
    return AgentUpdateResult(
      status: AgentUpdateStatus.targetMismatch,
      currentVersion: currentVersion,
      availableVersion: manifest.version.toString(),
      message:
          'The release manifest changed after confirmation. Check for updates again.',
      manifestTag: manifest.tag,
      manifestCommit: manifest.commit,
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
    String? manifestTag,
    String? manifestCommit,
  }) => AgentUpdateResult(
    status: status,
    currentVersion: currentVersion,
    availableVersion: availableVersion,
    message: message,
    manifestTag: manifestTag,
    manifestCommit: manifestCommit,
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
    final script = buildWindowsReplacementScript(
      target: escapedExecutable,
      staged: escapedStaged,
    );
    final scheduler = _replacementScheduler;
    if (scheduler != null) {
      final accepted = await scheduler(script);
      if (!accepted) await _deleteIfPresent(File(stagedPath));
      return accepted;
    }
    final readyMarker = File('$stagedPath.replacement-ready');
    final scriptFile = File('$stagedPath.replace.ps1');
    await _deleteIfPresent(readyMarker);
    await scriptFile.writeAsString(script, flush: true);
    try {
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ],
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        if (await readyMarker.exists()) {
          await _deleteIfPresent(readyMarker);
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await _writeWindowsUpdateResult(
        status: 'schedule_failed',
        message:
            'PowerShell did not acknowledge the replacement schedule within 10 seconds.',
      );
    } catch (error) {
      await _writeWindowsUpdateResult(
        status: 'schedule_failed',
        message: 'PowerShell spawn failed: $error',
      );
    }
    await _deleteIfPresent(readyMarker);
    await _deleteIfPresent(scriptFile);
    await _deleteIfPresent(File(stagedPath));
    return false;
  }

  Future<void> _writeWindowsUpdateResult({
    required String status,
    required String message,
  }) async {
    final safeMessage = message.isEmpty
        ? 'PowerShell exited before accepting the replacement schedule.'
        : message.substring(0, message.length.clamp(0, 1000));
    try {
      await File('$executablePath.update-result.json').writeAsString(
        jsonEncode({
          'status': status,
          'message': safeMessage,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } on FileSystemException {
      // The typed HTTP result remains authoritative if diagnostics cannot write.
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cleanup is best effort; the running executable remains untouched.
    }
  }

  /// Detached Windows replacement script. `target` and `staged` must already
  /// be PowerShell single-quote escaped. On start failure the previous
  /// executable is restored AND started before the script exits, so the
  /// machine never ends up without a working agent after a failed update.
  static String buildWindowsReplacementScript({
    required String target,
    required String staged,
  }) =>
      r'''
$ErrorActionPreference = 'Stop'
$target = '__TARGET__'
$staged = '__STAGED__'
$backup = "$target.rollback"
$readyMarker = "$staged.replacement-ready"
$resultPath = "$target.update-result.json"
$scriptPath = $PSCommandPath
function Exit-Replacement([int]$code) {
  if (Test-Path $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force }
  exit $code
}
function Write-UpdateResult([string]$status, [string]$message) {
  @{
    status = $status
    message = $message
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
if (Test-Path $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
Set-Content -LiteralPath $readyMarker -Value 'accepted' -Encoding ASCII
$deadline = (Get-Date).AddSeconds(120)
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
if (-not $ready) {
  Write-UpdateResult 'replacement_failed' 'The running executable did not unlock before the replacement deadline.'
  if (Test-Path $staged) { Remove-Item -LiteralPath $staged -Force }
  Exit-Replacement 1
}
try {
  Move-Item -LiteralPath $staged -Destination $target -Force
  & $target service start | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Service restart failed.' }
  Write-UpdateResult 'started' 'The replacement was installed and its Scheduled Task was started.'
  Exit-Replacement 0
} catch {
  if (Test-Path $target) { Remove-Item -LiteralPath $target -Force }
  $rollbackStarted = $false
  if (Test-Path $backup) {
    Move-Item -LiteralPath $backup -Destination $target -Force
    & $target service start | Out-Null
    $rollbackStarted = $LASTEXITCODE -eq 0
  }
  if (Test-Path $staged) { Remove-Item -LiteralPath $staged -Force }
  if ($rollbackStarted) {
    Write-UpdateResult 'rollback_completed' 'The previous executable was restored and its Scheduled Task was started.'
  } else {
    Write-UpdateResult 'rollback_start_failed' 'The previous executable could not be restarted after rollback.'
  }
  Exit-Replacement 1
}
'''
          .replaceFirst('__TARGET__', target)
          .replaceFirst('__STAGED__', staged);

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
