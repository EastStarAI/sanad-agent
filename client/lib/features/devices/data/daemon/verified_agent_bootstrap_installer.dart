import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/devices/data/daemon/agent_runtime_archive.dart';
import 'package:sanad_client/infrastructure/platform/release_trust_http_client.dart';
import 'package:sanad_release_contract/release_contract.dart';

enum AgentBootstrapStatus {
  installed,
  networkFailed,

  /// The release host's chain could not be verified on this computer.
  ///
  /// Distinct from [networkFailed] because the transport worked and the
  /// certificate was refused: the cause is the machine's trust set (antivirus
  /// or proxy TLS inspection, a partial root store, or a skewed clock), not
  /// reachability, and no automatic retry can fix it.
  tlsTrustFailed,
  manifestInvalid,
  targetMismatch,
  unsupportedTarget,
  downloadFailed,
  checksumFailed,
  trustFailed,
  replacementFailed,
}

/// Outcome of the packaged runtime step that follows a verified Agent install.
///
/// The runtime is a dictation companion, not part of the Agent payload's
/// contract: a published runtime that cannot be installed disables dictation and
/// is recorded beside the runtime, and it never turns a verified Agent install
/// into a failed one.
enum AgentRuntimeBundleStatus {
  /// The manifest declares no `agent-runtime` for this target.
  notPublished,
  installed,
  downloadFailed,
  checksumFailed,
  trustFailed,
  layoutRejected,
  replaceFailed;

  /// True when this status has to be reported as a dictation problem.
  bool get isFailure => switch (this) {
    notPublished || installed => false,
    downloadFailed ||
    checksumFailed ||
    trustFailed ||
    layoutRejected ||
    replaceFailed => true,
  };

  /// The machine-readable cause recorded beside the runtime, or null when this
  /// status is not a failure.
  String? get failureCause => switch (this) {
    downloadFailed => NativeRuntimeInstall.downloadFailed,
    checksumFailed => NativeRuntimeInstall.checksumFailed,
    trustFailed => NativeRuntimeInstall.trustFailed,
    layoutRejected => NativeRuntimeInstall.layoutRejected,
    replaceFailed => NativeRuntimeInstall.replaceFailed,
    notPublished || installed => null,
  };
}

class AgentBootstrapResult {
  const AgentBootstrapResult(
    this.status, {
    this.message,
    this.runtimeStatus = AgentRuntimeBundleStatus.notPublished,
    this.runtimeMessage,
  });

  final AgentBootstrapStatus status;
  final String? message;
  final AgentRuntimeBundleStatus runtimeStatus;
  final String? runtimeMessage;

  bool get isSuccess => status == AgentBootstrapStatus.installed;

  /// The recorded dictation-only failure, or null when the runtime installed or
  /// the release publishes none. It never affects [isSuccess].
  String? get runtimeFailureCause => runtimeStatus.failureCause;
}

class VerifiedAgentBootstrapInstaller {
  static final _logger = Logger('VerifiedAgentBootstrapInstaller');

  VerifiedAgentBootstrapInstaller({
    required this.targetPath,
    http.Client? client,
    Uri? manifestUri,
    String? operatingSystem,
    String? architecture,
    PlatformArtifactVerifier? platformVerifier,
    PlatformArtifactDetailedVerifier? detailedPlatformVerifier,
    Uri? artifactMirrorUri,
    Object? fallbackManifestUri = _unsetFallbackManifest,
  }) : _client = client ?? createReleaseTrustHttpClient(),
       manifestUri = manifestUri ?? Uri.parse(AppConfig.releaseManifestUrl),
       operatingSystem = operatingSystem ?? Platform.operatingSystem,
       architecture = architecture ?? _architecture(),
       _platformVerifier = platformVerifier,
       _detailedPlatformVerifier = detailedPlatformVerifier,
       _artifactMirrorUri =
           artifactMirrorUri ??
           (AppConfig.releaseArtifactMirrorUrl.trim().isEmpty ? null : Uri.parse(AppConfig.releaseArtifactMirrorUrl)),
       fallbackManifestUri = identical(fallbackManifestUri, _unsetFallbackManifest)
           ? _configuredFallbackManifest()
           : fallbackManifestUri as Uri?;

  final String targetPath;
  final Uri manifestUri;

  /// The project's own published copy of the same manifest, used only when the
  /// primary release host cannot be verified on this computer.
  final Uri? fallbackManifestUri;

  final String operatingSystem;
  final String architecture;
  final http.Client _client;
  final PlatformArtifactVerifier? _platformVerifier;
  final PlatformArtifactDetailedVerifier? _detailedPlatformVerifier;
  final Uri? _artifactMirrorUri;

  Future<AgentBootstrapResult> install({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    final primary = await _loadManifest(manifestUri);
    ReleaseManifest manifest;
    if (primary.manifest != null) {
      manifest = primary.manifest!;
    } else if (primary.refusedChain && _fallbackApplies) {
      // GitHub's chain is not verifiable here while our own host's is, so the
      // identical published copy is fetched instead. Verification below is
      // unchanged: version, size, SHA-256, and platform trust still decide.
      final fallback = await _loadManifest(fallbackManifestUri!);
      if (fallback.manifest == null) {
        return fallback.failure ??
            const AgentBootstrapResult(AgentBootstrapStatus.tlsTrustFailed);
      }
      _logger.info(
        'Used the hosted release manifest because the primary release host '
        'could not be verified on this computer.',
      );
      manifest = fallback.manifest!;
    } else {
      return primary.failure ??
          const AgentBootstrapResult(AgentBootstrapStatus.tlsTrustFailed);
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
      final downloadUri = _artifactMirrorUri?.resolve(artifact.filename) ?? artifact.url;
      final response = await _client.send(http.Request('GET', downloadUri));
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
      final trust = await verifyReleaseArtifactTrustDetailed(
        staged,
        artifact: artifact,
        detailedVerifier: _detailedPlatformVerifier,
        platformVerifier: _platformVerifier,
      );
      if (!trust.isTrusted) {
        return AgentBootstrapResult(
          AgentBootstrapStatus.trustFailed,
          message: 'The downloaded agent failed platform trust verification (${trust.summary}).',
        );
      }

      final backup = File('$targetPath.rollback');
      if (backup.existsSync()) await backup.delete();
      if (target.existsSync()) await target.rename(backup.path);
      try {
        await staged.rename(target.path);
        if (operatingSystem != 'windows' && !Platform.isWindows) {
          final chmod = await Process.run('chmod', ['700', target.path]);
          if (chmod.exitCode != 0) throw const FileSystemException('chmod');
        }
        // Only after the executable itself is verified and in place: the runtime
        // is paired to that exact release, platform, and architecture.
        final runtime = await _installRuntime(manifest: manifest, platform: platform);
        return AgentBootstrapResult(
          AgentBootstrapStatus.installed,
          runtimeStatus: runtime.status,
          runtimeMessage: runtime.message,
        );
      } catch (error) {
        if (target.existsSync()) await target.delete();
        if (backup.existsSync()) await backup.rename(target.path);
        return AgentBootstrapResult(
          AgentBootstrapStatus.replacementFailed,
          message: 'Could not install the verified agent: $error',
        );
      }
    } on TlsException catch (error) {
      return _tlsTrustFailure('agent artifact', error);
    } catch (error) {
      return AgentBootstrapResult(
        AgentBootstrapStatus.downloadFailed,
        message: 'Agent download failed: $error',
      );
    } finally {
      if (staged.existsSync()) await staged.delete();
    }
  }

  static const Object _unsetFallbackManifest = Object();

  /// True when a fallback manifest host is configured and differs from the
  /// primary one; otherwise a refused chain is reported as such.
  bool get _fallbackApplies {
    final fallback = fallbackManifestUri;
    return fallback != null && fallback != manifestUri;
  }

  static Uri? _configuredFallbackManifest() {
    final configured = AppConfig.releaseManifestFallbackUrl.trim();
    return configured.isEmpty ? null : Uri.parse(configured);
  }

  /// Fetches and parses one manifest candidate.
  ///
  /// [refusedChain] is separate from [failure] so the caller can decide whether
  /// another host is worth trying: a refused certificate is host-specific, while
  /// an HTTP error, unparseable body, or unreachable network is not.
  Future<({ReleaseManifest? manifest, AgentBootstrapResult? failure, bool refusedChain})>
  _loadManifest(Uri uri) async {
    try {
      final response = await _client.get(
        uri,
        headers: const {'User-Agent': 'sanad-client'},
      );
      if (response.statusCode != HttpStatus.ok) {
        return (
          manifest: null,
          failure: AgentBootstrapResult(
            AgentBootstrapStatus.networkFailed,
            message: 'Manifest request failed with HTTP ${response.statusCode}.',
          ),
          refusedChain: false,
        );
      }
      return (
        manifest: ReleaseManifest.fromJsonString(response.body),
        failure: null,
        refusedChain: false,
      );
    } on FormatException catch (error) {
      return (
        manifest: null,
        failure: AgentBootstrapResult(
          AgentBootstrapStatus.manifestInvalid,
          message: error.message,
        ),
        refusedChain: false,
      );
    } on TlsException catch (error) {
      return (
        manifest: null,
        failure: _tlsTrustFailure('release manifest', error),
        refusedChain: true,
      );
    } catch (error) {
      return (
        manifest: null,
        failure: AgentBootstrapResult(
          AgentBootstrapStatus.networkFailed,
          message: 'Unable to fetch the release manifest: $error',
        ),
        refusedChain: false,
      );
    }
  }

  /// Installs the packaged native runtime beside the verified executable.
  ///
  /// The archive is untrusted input: size, SHA-256, and platform trust are all
  /// verified **before** extraction, the member layout is validated against the
  /// tag derived from the artifact's own metadata, and the previous directory is
  /// kept as `.rollback` until the new one is in place. Nothing here runs for a
  /// manifest that publishes no runtime for this target.
  ///
  /// A failure is recorded beside the runtime (so the daemon's dictation
  /// readiness names it) and returned as an outcome: the Agent is already
  /// verified and installed, and an optional dictation artifact must not undo it.
  Future<_RuntimeOutcome> _installRuntime({
    required ReleaseManifest manifest,
    required String platform,
  }) async {
    final executableDir = File(targetPath).parent;
    final nativeRoot = Directory('${executableDir.path}/native');
    final outcome = await _installRuntimeArchive(
      manifest: manifest,
      platform: platform,
      nativeRoot: nativeRoot,
    );
    final cause = outcome.status.failureCause;
    if (cause != null) {
      await NativeRuntimeInstall.record(nativeRoot, cause);
    } else {
      await NativeRuntimeInstall.clear(nativeRoot);
    }
    return outcome;
  }

  Future<_RuntimeOutcome> _installRuntimeArchive({
    required ReleaseManifest manifest,
    required String platform,
    required Directory nativeRoot,
  }) async {
    final artifact = manifest.findArtifact(
      component: 'agent-runtime',
      platform: platform,
      architecture: architecture,
      format: AgentRuntimeArchive.format,
      publicOnly: true,
    );
    if (artifact == null) {
      return const _RuntimeOutcome(AgentRuntimeBundleStatus.notPublished, null);
    }

    final tag = AgentRuntimeArchive.tagFor(
      platform: artifact.platform,
      architecture: artifact.architecture,
    );
    final stagedArchive = File('${nativeRoot.path}/.$tag.bootstrap.tar.gz');
    final stagedDir = Directory('${nativeRoot.path}/.$tag.staged');
    try {
      await nativeRoot.create(recursive: true);
      if (stagedArchive.existsSync()) await stagedArchive.delete();
      if (stagedDir.existsSync()) await stagedDir.delete(recursive: true);

      final downloadUri =
          _artifactMirrorUri?.resolve(artifact.filename) ?? artifact.url;
      final response = await _client.send(http.Request('GET', downloadUri));
      if (response.statusCode != HttpStatus.ok) {
        return _RuntimeOutcome(
          AgentRuntimeBundleStatus.downloadFailed,
          'Runtime download failed with HTTP ${response.statusCode}.',
        );
      }
      final sink = stagedArchive.openWrite();
      var downloaded = 0;
      await for (final chunk in response.stream) {
        downloaded += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
      if (downloaded != artifact.size ||
          await sha256OfFile(stagedArchive) != artifact.sha256) {
        return const _RuntimeOutcome(
          AgentRuntimeBundleStatus.checksumFailed,
          'The downloaded runtime failed size or SHA-256 verification.',
        );
      }
      final trust = await verifyReleaseArtifactTrustDetailed(
        stagedArchive,
        artifact: artifact,
        detailedVerifier: _detailedPlatformVerifier,
        platformVerifier: _platformVerifier,
      );
      if (!trust.isTrusted) {
        return _RuntimeOutcome(
          AgentRuntimeBundleStatus.trustFailed,
          'The downloaded runtime failed platform trust verification '
          '(${trust.summary}).',
        );
      }

      final rejection = await AgentRuntimeArchive.extract(
        bytes: await stagedArchive.readAsBytes(),
        tag: tag,
        into: stagedDir,
      );
      if (rejection != null) {
        return _RuntimeOutcome(
          AgentRuntimeBundleStatus.layoutRejected,
          'The runtime archive was refused: $rejection.',
        );
      }

      final target = Directory('${nativeRoot.path}/$tag');
      final rollback = Directory('${nativeRoot.path}/$tag.rollback');
      if (rollback.existsSync()) await rollback.delete(recursive: true);
      final hadPrevious = target.existsSync();
      if (hadPrevious) await target.rename(rollback.path);
      try {
        await Directory('${stagedDir.path}/native/$tag').rename(target.path);
      } on Object catch (error) {
        if (target.existsSync()) await target.delete(recursive: true);
        if (hadPrevious && rollback.existsSync()) {
          await rollback.rename(target.path);
        }
        return _RuntimeOutcome(
          AgentRuntimeBundleStatus.replaceFailed,
          'Could not install the verified runtime: $error',
        );
      }
      if (rollback.existsSync()) await rollback.delete(recursive: true);
      return const _RuntimeOutcome(AgentRuntimeBundleStatus.installed, null);
    } on Object catch (error) {
      return _RuntimeOutcome(
        AgentRuntimeBundleStatus.downloadFailed,
        'Runtime install failed: $error',
      );
    } finally {
      if (stagedArchive.existsSync()) await stagedArchive.delete();
      if (stagedDir.existsSync()) await stagedDir.delete(recursive: true);
    }
  }

  /// Reports an untrusted release chain without echoing the BoringSSL text.
  ///
  /// The exception stays in the log because it names the refused certificate
  /// stage; the outcome stays actionable because every caller can render a
  /// localized cause and remedy for [AgentBootstrapStatus.tlsTrustFailed].
  static AgentBootstrapResult _tlsTrustFailure(
    String surface,
    TlsException error,
  ) {
    _logger.warning(
      'TLS trust verification failed for the $surface '
      '(${error.runtimeType}).',
    );
    return const AgentBootstrapResult(AgentBootstrapStatus.tlsTrustFailed);
  }

  static String _architecture() {
    return Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
  }
}

class _RuntimeOutcome {
  const _RuntimeOutcome(this.status, this.message);

  final AgentRuntimeBundleStatus status;
  final String? message;
}
