import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_release_contract/release_contract.dart';

enum AgentBootstrapStatus {
  installed,
  networkFailed,
  manifestInvalid,
  targetMismatch,
  unsupportedTarget,
  downloadFailed,
  checksumFailed,
  trustFailed,
  replacementFailed,
}

class AgentBootstrapResult {
  const AgentBootstrapResult(this.status, {this.message});

  final AgentBootstrapStatus status;
  final String? message;

  bool get isSuccess => status == AgentBootstrapStatus.installed;
}

class VerifiedAgentBootstrapInstaller {
  VerifiedAgentBootstrapInstaller({
    required this.targetPath,
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
       architecture = architecture ?? _architecture(),
       _platformVerifier = platformVerifier ?? verifyPlatformCodeSignature;

  final String targetPath;
  final Uri manifestUri;
  final String operatingSystem;
  final String architecture;
  final http.Client _client;
  final PlatformArtifactVerifier _platformVerifier;

  Future<AgentBootstrapResult> install({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    ReleaseManifest manifest;
    try {
      final response = await _client.get(
        manifestUri,
        headers: const {'User-Agent': 'sanad-client'},
      );
      if (response.statusCode != HttpStatus.ok) {
        return AgentBootstrapResult(
          AgentBootstrapStatus.networkFailed,
          message: 'Manifest request failed with HTTP ${response.statusCode}.',
        );
      }
      manifest = ReleaseManifest.fromJsonString(response.body);
    } on FormatException catch (error) {
      return AgentBootstrapResult(
        AgentBootstrapStatus.manifestInvalid,
        message: error.message,
      );
    } catch (error) {
      return AgentBootstrapResult(
        AgentBootstrapStatus.networkFailed,
        message: 'Unable to fetch the release manifest: $error',
      );
    }

    final requested = ReleaseVersion.parse(targetVersion);
    if (manifest.version.compareTo(requested) != 0) {
      return AgentBootstrapResult(
        AgentBootstrapStatus.targetMismatch,
        message: 'Release manifest ${manifest.version} does not match required agent $requested.',
      );
    }
    final platform = operatingSystem == 'macos' ? 'macos' : operatingSystem;
    final artifact = manifest.findArtifact(
      component: 'agent',
      platform: platform,
      architecture: architecture,
      publicOnly: true,
    );
    if (artifact == null) {
      return const AgentBootstrapResult(AgentBootstrapStatus.unsupportedTarget);
    }

    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final staged = File('$targetPath.bootstrap-staged');
    try {
      if (staged.existsSync()) await staged.delete();
      final response = await _client.send(http.Request('GET', artifact.url));
      if (response.statusCode != HttpStatus.ok) {
        return AgentBootstrapResult(
          AgentBootstrapStatus.downloadFailed,
          message: 'Agent download failed with HTTP ${response.statusCode}.',
        );
      }
      final sink = staged.openWrite();
      var downloaded = 0;
      await for (final chunk in response.stream) {
        downloaded += chunk.length;
        sink.add(chunk);
        if (artifact.size > 0) {
          onProgress?.call((downloaded / artifact.size).clamp(0, 1));
        }
      }
      await sink.close();
      if (downloaded != artifact.size || await sha256OfFile(staged) != artifact.sha256) {
        return const AgentBootstrapResult(AgentBootstrapStatus.checksumFailed);
      }
      if (!await verifyReleaseArtifactTrust(
        staged,
        artifact: artifact,
        platformVerifier: _platformVerifier,
      )) {
        return const AgentBootstrapResult(AgentBootstrapStatus.trustFailed);
      }

      final backup = File('$targetPath.rollback');
      if (backup.existsSync()) await backup.delete();
      if (target.existsSync()) await target.rename(backup.path);
      try {
        await staged.rename(target.path);
        if (operatingSystem != 'windows') {
          final chmod = await Process.run('chmod', ['700', target.path]);
          if (chmod.exitCode != 0) throw const FileSystemException('chmod');
        }
        return const AgentBootstrapResult(AgentBootstrapStatus.installed);
      } catch (error) {
        if (target.existsSync()) await target.delete();
        if (backup.existsSync()) await backup.rename(target.path);
        return AgentBootstrapResult(
          AgentBootstrapStatus.replacementFailed,
          message: 'Could not install the verified agent: $error',
        );
      }
    } catch (error) {
      return AgentBootstrapResult(
        AgentBootstrapStatus.downloadFailed,
        message: 'Agent download failed: $error',
      );
    } finally {
      if (staged.existsSync()) await staged.delete();
    }
  }

  static String _architecture() {
    return Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
  }
}
