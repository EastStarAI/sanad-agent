/// Packaging-side install of the `agent-runtime` bundle for a released Agent.
///
/// The bundle is the release contract's `agent-runtime` archive: a gzip tar whose
/// members are exactly `native/<platform>-<architecture>/<library>` for the same
/// release, platform, and architecture as the Agent executable. The tag is
/// derived from the selected artifact's own metadata, so no second OS/ABI
/// catalog exists here.
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_release_contract/release_contract.dart';

/// Outcome of refreshing the packaged runtime.
enum AgentRuntimeBundleStatus {
  /// The release declares no runtime for this target: the Agent keeps whatever
  /// runtime is already on disk.
  notPublished,
  installed,

  /// Windows: the new runtime is verified and staged, and the restart-time
  /// replacement moves it while no library is loaded.
  stagedForRestart,
  downloadFailed,
  checksumFailed,
  trustFailed,
  layoutRejected,
  replaceFailed,
}

class AgentRuntimeBundleResult {
  const AgentRuntimeBundleResult(this.status, {this.message, this.stagedPath});

  final AgentRuntimeBundleStatus status;
  final String? message;

  /// Absolute directory the replacement will move, for the restart path.
  final String? stagedPath;

  bool get isTerminalSuccess =>
      status == AgentRuntimeBundleStatus.notPublished ||
      status == AgentRuntimeBundleStatus.installed ||
      status == AgentRuntimeBundleStatus.stagedForRestart;
}

class AgentRuntimeBundle {
  AgentRuntimeBundle({
    http.Client? client,
    Uri? artifactMirrorUri,
    PlatformArtifactVerifier? platformVerifier,
    PlatformArtifactDetailedVerifier? detailedPlatformVerifier,
    String? operatingSystem,
    String? architecture,
  }) : _client = client ?? http.Client(),
       _artifactMirrorUri = artifactMirrorUri,
       _platformVerifier = platformVerifier,
       _detailedPlatformVerifier = detailedPlatformVerifier,
       operatingSystem = operatingSystem ?? Platform.operatingSystem,
       architecture = architecture ?? _detectArchitecture();

  final http.Client _client;
  final Uri? _artifactMirrorUri;
  final PlatformArtifactVerifier? _platformVerifier;
  final PlatformArtifactDetailedVerifier? _detailedPlatformVerifier;
  final String operatingSystem;
  final String architecture;

  static const int maxMembers = 512;

  /// Refreshes the runtime beside [executablePath] from [manifest].
  ///
  /// Verification (size, SHA-256, declared platform trust) happens before any
  /// byte is extracted. On POSIX the directory is swapped with a `.rollback`
  /// sibling; on Windows the verified directory is left staged because a loaded
  /// DLL cannot be replaced in-process, and the restart script moves it.
  Future<AgentRuntimeBundleResult> refresh({
    required ReleaseManifest manifest,
    required String executablePath,
  }) async {
    final platform = operatingSystem == 'macos' ? 'macos' : operatingSystem;
    final artifact = manifest.findArtifact(
      component: 'agent-runtime',
      platform: platform,
      architecture: architecture,
      format: 'tar.gz',
      publicOnly: true,
    );
    if (artifact == null) {
      return const AgentRuntimeBundleResult(AgentRuntimeBundleStatus.notPublished);
    }

    final tag = '${artifact.platform}-${artifact.architecture}';
    final nativeRoot = Directory('${File(executablePath).parent.path}/native');
    final stagedArchive = File('${nativeRoot.path}/.$tag.${manifest.version}.tar.gz');
    final stagedDir = Directory('${nativeRoot.path}/.$tag.staged');
    try {
      await nativeRoot.create(recursive: true);
      if (stagedArchive.existsSync()) await stagedArchive.delete();
      if (stagedDir.existsSync()) await stagedDir.delete(recursive: true);

      final downloadUri =
          _artifactMirrorUri?.resolve(artifact.filename) ?? artifact.url;
      final response = await _client.send(http.Request('GET', downloadUri));
      if (response.statusCode != HttpStatus.ok) {
        return AgentRuntimeBundleResult(
          AgentRuntimeBundleStatus.downloadFailed,
          message: 'Runtime download failed with HTTP ${response.statusCode}.',
        );
      }
      final sink = stagedArchive.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
      if (received != artifact.size ||
          await sha256OfFile(stagedArchive) != artifact.sha256) {
        return const AgentRuntimeBundleResult(
          AgentRuntimeBundleStatus.checksumFailed,
          message: 'Downloaded runtime failed size or SHA-256 verification.',
        );
      }
      final trust = await verifyReleaseArtifactTrustDetailed(
        stagedArchive,
        artifact: artifact,
        detailedVerifier: _detailedPlatformVerifier,
        platformVerifier: _platformVerifier,
      );
      if (!trust.isTrusted) {
        return AgentRuntimeBundleResult(
          AgentRuntimeBundleStatus.trustFailed,
          message:
              'Downloaded runtime failed the declared platform trust policy '
              '(${trust.summary}).',
        );
      }

      final rejection = await _extract(stagedArchive, stagedDir, tag);
      if (rejection != null) {
        return AgentRuntimeBundleResult(
          rejection.$1,
          message: rejection.$2,
        );
      }

      final extracted = Directory('${stagedDir.path}/native/$tag');
      if (operatingSystem == 'windows') {
        // A loaded DLL cannot be replaced or deleted while this process runs, so
        // the swap is the restart script's job, not a destructive directory
        // overwrite here. The published staging name is `<tag>.staged` beside the
        // live directory, which is what the replacement script moves.
        final published = Directory('${nativeRoot.path}/$tag.staged');
        if (published.existsSync()) await published.delete(recursive: true);
        await extracted.rename(published.path);
        return AgentRuntimeBundleResult(
          AgentRuntimeBundleStatus.stagedForRestart,
          stagedPath: published.path,
          message: 'Verified runtime staged for replacement during restart.',
        );
      }

      final target = Directory('${nativeRoot.path}/$tag');
      final rollback = Directory('${nativeRoot.path}/$tag.rollback');
      if (rollback.existsSync()) await rollback.delete(recursive: true);
      final hadPrevious = target.existsSync();
      if (hadPrevious) await target.rename(rollback.path);
      try {
        await extracted.rename(target.path);
      } on Object catch (error) {
        if (target.existsSync()) await target.delete(recursive: true);
        if (hadPrevious && rollback.existsSync()) {
          await rollback.rename(target.path);
        }
        return AgentRuntimeBundleResult(
          AgentRuntimeBundleStatus.replaceFailed,
          message: 'Could not install the verified runtime: $error',
        );
      }
      if (rollback.existsSync()) await rollback.delete(recursive: true);
      return const AgentRuntimeBundleResult(AgentRuntimeBundleStatus.installed);
    } on Object catch (error) {
      return AgentRuntimeBundleResult(
        AgentRuntimeBundleStatus.downloadFailed,
        message: 'Runtime refresh failed: $error',
      );
    } finally {
      if (stagedArchive.existsSync()) await stagedArchive.delete();
      if (stagedDir.existsSync()) await stagedDir.delete(recursive: true);
    }
  }

  /// Lists, validates, and extracts [archive] into [into].
  ///
  /// Names are validated **before** extraction and the extracted tree is checked
  /// to be regular files only, so a traversal path, a dot entry, a symbolic link,
  /// a model payload, or a duplicate cannot land in the installed layout.
  Future<(AgentRuntimeBundleStatus, String)?> _extract(
    File archive,
    Directory into,
    String tag,
  ) async {
    final listing = await _tar(['-tzf', archive.path]);
    if (listing == null) {
      return (
        AgentRuntimeBundleStatus.layoutRejected,
        'Could not list the runtime archive (no usable tar on this host).',
      );
    }
    final names = listing
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        // Tar writers record the `native/` and `native/<tag>/` directory entries;
        // they hold no bytes and are the only accepted non-library names.
        .where((line) => line != 'native/' && line != 'native/$tag/')
        .toList(growable: false);
    final rejection = _memberRejection(names, tag);
    if (rejection != null) {
      return (AgentRuntimeBundleStatus.layoutRejected, rejection);
    }

    await into.create(recursive: true);
    final extracted = await _tar(['-xzf', archive.path, '-C', into.path]);
    if (extracted == null) {
      return (
        AgentRuntimeBundleStatus.layoutRejected,
        'Could not extract the runtime archive.',
      );
    }
    final root = Directory('${into.path}/native/$tag');
    if (!root.existsSync()) {
      return (
        AgentRuntimeBundleStatus.layoutRejected,
        'The runtime archive produced no native/$tag directory.',
      );
    }
    final expected = names
        .map((name) => name.substring('native/$tag/'.length))
        .toSet();
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(root.path.length + 1);
      if (entity is Directory) continue;
      if (entity is! File || !expected.contains(relative)) {
        return (
          AgentRuntimeBundleStatus.layoutRejected,
          'The runtime archive contained an unexpected member.',
        );
      }
    }
    return null;
  }

  String? _memberRejection(List<String> names, String tag) {
    if (names.isEmpty) return 'The runtime archive is empty.';
    if (names.length > maxMembers) return 'The runtime archive has too many members.';
    final prefix = 'native/$tag/';
    final seen = <String>{};
    for (final name in names) {
      if (!name.startsWith(prefix)) {
        return 'The runtime archive contains a member outside native/$tag/.';
      }
      final base = name.substring(prefix.length);
      if (base.isEmpty || base.contains('/') || base.contains('\\')) {
        return 'The runtime archive nests or escapes its layout.';
      }
      if (base == '.' || base == '..' || base.startsWith('.')) {
        return 'The runtime archive contains a hidden member.';
      }
      if (base.contains(':')) return 'The runtime archive contains a drive path.';
      if (!_isLibraryName(base)) {
        return 'The runtime archive contains a non-library member.';
      }
      if (!seen.add(base)) return 'The runtime archive repeats a member.';
    }
    return null;
  }

  static bool _isLibraryName(String name) {
    final lower = name.toLowerCase();
    for (final extension in const [
      '.bin',
      '.gguf',
      '.ggml',
      '.onnx',
      '.pt',
      '.safetensors',
      '.zip',
      '.tar',
      '.gz',
    ]) {
      if (lower.endsWith(extension)) return false;
    }
    if (lower.endsWith('.dylib') || lower.endsWith('.dll')) return true;
    if (lower.endsWith('.so')) return true;
    return RegExp(r'\.so\.\d+$').hasMatch(lower);
  }

  /// Runs the host `tar`, returning stdout, or null when it is unavailable.
  Future<String?> _tar(List<String> args) async {
    try {
      final result = await Process.run('tar', args);
      if (result.exitCode != 0) return null;
      return result.stdout?.toString() ?? '';
    } on Object {
      return null;
    }
  }

  static String _detectArchitecture() {
    final value = Abi.current().toString().toLowerCase();
    if (value.contains('arm64')) return 'arm64';
    return 'x64';
  }
}
