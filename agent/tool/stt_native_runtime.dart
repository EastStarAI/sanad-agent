/// Verification and staging of the native dictation runtime.
///
/// `tool/ensure_native_stt.dart` is the CLI around this library. Keeping the
/// rules here means the same checks run in a developer checkout, in PR CI, and
/// in Agent release staging, and that they can be exercised without building
/// whisper.cpp or opening a dylib.
///
/// Two evidence classes are deliberately separate:
///
///   * a **fresh build from the pinned whisper.cpp source tag** is proven by the
///     required files existing with the right machine architecture (and, on
///     macOS, a deployment target no newer than the shipped Client's floor).
///     Its bytes are new, so pinned per-file hashes are advisory there;
///   * a **published binary download** is proven by the pinned `_archive`
///     sha256 and the pinned per-file hashes. A download without a pinned
///     archive hash fails closed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_stt_sherpa/sanad_stt_sherpa.dart';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';

/// Manifest file name inside the agent's `native/` directory.
const String sttRuntimeManifestFileName = 'checksums.json';

/// Marker for the artifact entries that only declare provenance.
const String sttManifestStatusKey = '_status';
const String sttManifestArchiveKey = '_archive';

/// How trustworthy the recorded hashes of one platform artifact are.
enum SttRuntimePinState {
  /// Per-file hashes exist and are authoritative for a published artifact.
  pinned,

  /// Hashes were derived from one local build; no producing pipeline exists
  /// yet, so they are not independently reproducible from CI.
  locallyBuilt,

  /// No per-file hashes are recorded. The artifact is produced by the staging
  /// build and its hashes stay pending an authorized producer run.
  unpinned,

  /// The manifest has no entry for the platform at all.
  missing,
}

/// `agent/native/checksums.json`, with provenance.
class SttRuntimeManifest {
  SttRuntimeManifest({
    required this.whisperCppVersion,
    required this.artifacts,
  });

  factory SttRuntimeManifest.fromJson(Object? json) {
    if (json is! Map) {
      return SttRuntimeManifest(whisperCppVersion: '', artifacts: const {});
    }
    final version = json['whisper_cpp_version'];
    final rawArtifacts = json['artifacts'];
    final artifacts = <String, Map<String, Object?>>{};
    if (rawArtifacts is Map) {
      for (final entry in rawArtifacts.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! Map) continue;
        final fields = <String, Object?>{};
        for (final field in value.entries) {
          final fieldKey = field.key;
          if (fieldKey is String) fields[fieldKey] = field.value;
        }
        artifacts[key] = fields;
      }
    }
    return SttRuntimeManifest(
      whisperCppVersion: version is String ? version : '',
      artifacts: artifacts,
    );
  }

  /// Loads the manifest, treating a missing or unreadable file as empty.
  factory SttRuntimeManifest.load(File file) {
    if (!file.existsSync()) {
      return SttRuntimeManifest(whisperCppVersion: '', artifacts: const {});
    }
    try {
      return SttRuntimeManifest.fromJson(jsonDecode(file.readAsStringSync()));
    } on FormatException {
      return SttRuntimeManifest(whisperCppVersion: '', artifacts: const {});
    }
  }

  final String whisperCppVersion;
  final Map<String, Map<String, Object?>> artifacts;

  Map<String, Object?>? entryFor(SttNativeTarget target) =>
      artifacts[target.tag];

  /// Pin state declared by the platform entry.
  SttRuntimePinState pinStateFor(SttNativeTarget target) {
    final entry = entryFor(target);
    if (entry == null) return SttRuntimePinState.missing;
    return switch (entry[sttManifestStatusKey]) {
      'unpinned' => SttRuntimePinState.unpinned,
      'locally-built' => SttRuntimePinState.locallyBuilt,
      _ => SttRuntimePinState.pinned,
    };
  }

  /// Pinned archive hash for the download path, or null when unpinned.
  String? archiveHashFor(SttNativeTarget target) {
    final value = entryFor(target)?[sttManifestArchiveKey];
    return value is String && value.length == 64 ? value : null;
  }
}

/// Result of checking one directory against a target and the manifest.
class SttRuntimeVerification {
  const SttRuntimeVerification({
    required this.target,
    required this.directory,
    required this.pinState,
    required this.problems,
    required this.warnings,
    required this.missing,
    required this.unpinned,
    required this.hashes,
  });

  final SttNativeTarget target;
  final String directory;
  final SttRuntimePinState pinState;

  /// Hard failures. [ok] is false whenever this is not empty.
  final List<String> problems;

  /// Conditions that do not block a local or staged build but must be stated.
  final List<String> warnings;

  /// Required library names that are absent.
  final List<String> missing;

  /// Required libraries whose bytes have no pinned hash.
  final List<String> unpinned;

  /// sha256 of every library that was read, keyed by file name.
  final Map<String, String> hashes;

  bool get ok => problems.isEmpty;

  /// True when this build is byte-identical to a published, pinned artifact.
  ///
  /// A failed pin comparison is reported as a warning on a fresh build, so the
  /// state must look at the comparison too: claiming "pinned" while every file
  /// differs would be exactly the kind of unproven claim this gate exists to
  /// prevent.
  bool get pinned =>
      pinState == SttRuntimePinState.pinned &&
      unpinned.isEmpty &&
      !warnings.any((warning) => warning.startsWith('checksum_differs_from_pinned'));
}

/// Checks the runtime directory against [target] and [manifest].
///
/// [nativeRoot] is the agent's `native/` directory and [directoryPath]
/// overrides the checked directory (a build staging directory, for example).
/// Only the canonical architecture-qualified directory is checked by default:
/// staging and verification must never accept the bounded Apple Silicon legacy
/// alias as a build output.
///
/// [requireSherpa] additionally demands the sherpa-onnx libraries that the
/// packaged runtime ships under `sherpa/`. It is on for staging and archiving —
/// the only paths that produce a payload a released Agent loads — and off for a
/// developer checkout, where those libraries come from the pub cache and the
/// build never copies them into `agent/native/`.
Future<SttRuntimeVerification> verifySttRuntime({
  required Directory nativeRoot,
  required SttNativeTarget target,
  required SttRuntimeManifest manifest,
  bool requireManifestEntry = true,
  bool requirePinnedHashes = false,
  bool comparePinnedHashes = true,
  bool requireSherpa = false,
  String? directoryPath,
}) async {
  final directory =
      directoryPath ?? '${nativeRoot.path}/${target.nativeDirectory}';
  final entry = manifest.entryFor(target);
  final pinState = manifest.pinStateFor(target);
  final problems = <String>[];
  final warnings = <String>[];
  final missing = <String>[];
  final unpinned = <String>[];
  final hashes = <String, String>{};

  if (entry == null && requireManifestEntry) {
    problems.add('manifest_entry_missing:${target.tag}');
  }

  /// The whisper libraries and the sherpa libraries are verified the same way;
  /// only their directory and their manifest key differ.
  void verifyLibrary(String path, String manifestKey) {
    final file = File(path);
    if (!file.existsSync()) {
      missing.add(manifestKey);
      problems.add('missing_library:$manifestKey');
      return;
    }
    // The whole file is read so the macOS deployment target can be checked as
    // well; native libraries are a few megabytes at most.
    final info = inspectNativeLibraryFile(path);
    if (!info.isRecognized) {
      problems.add('unrecognized_native_binary:$manifestKey');
      return;
    }
    if (!info.supports(target.cpu)) {
      problems.add('architecture_mismatch:$manifestKey');
    }
    final minimum = info.minimumMacOsVersion;
    final ceiling = target.macosDeploymentTarget;
    if (ceiling != null) {
      if (minimum == null) {
        warnings.add('deployment_target_unknown:$manifestKey');
      } else if (compareVersions(minimum, ceiling) > 0) {
        problems.add(
          'deployment_target_too_high:$manifestKey:$minimum>$ceiling',
        );
      }
    }
    final digest = sha256OfFileSync(file);
    hashes[manifestKey] = digest;
    final want = entry?[manifestKey];
    if (want is! String || want.length != 64) {
      unpinned.add(manifestKey);
      // A strict gate that accepts a missing pin is not strict. The download
      // path sets [requirePinnedHashes], so an entry without per-file hashes
      // must fail there instead of degrading to a warning.
      if (requirePinnedHashes) {
        problems.add('pinned_hash_missing:$manifestKey');
      }
      return;
    }
    if (comparePinnedHashes && digest != want) {
      if (requirePinnedHashes) {
        problems.add('checksum_mismatch:$manifestKey');
      } else {
        warnings.add('checksum_differs_from_pinned:$manifestKey');
      }
    }
  }

  for (final name in target.requiredLibraries) {
    verifyLibrary('$directory/$name', name);
  }

  // A build that links the sherpa engine must ship its libraries; a build
  // without it ships none, and its archive simply has no `sherpa/` subtree.
  if (sherpaEngineAvailable) {
    final sherpaRoot = '$directory/${target.sherpaNativeSubdirectory}';
    for (final relative in target.sherpaLibraries) {
      final key = '${target.sherpaNativeSubdirectory}/$relative';
      if (!requireSherpa && !File('$sherpaRoot/$relative').existsSync()) {
        // A source checkout legitimately has no packaged copy.
        continue;
      }
      verifyLibrary('$sherpaRoot/$relative', key);
    }
  }

  if (requirePinnedHashes &&
      pinState == SttRuntimePinState.unpinned &&
      unpinned.isNotEmpty) {
    // Name the state explicitly: a known-unpinned entry can never pass the
    // download layer as a pinned artifact.
    problems.add('pin_state_unpinned:${target.tag}');
  }

  if (unpinned.isNotEmpty) {
    warnings.add('unpinned_hashes:${unpinned.length}');
  }

  return SttRuntimeVerification(
    target: target,
    directory: directory,
    pinState: pinState,
    problems: List.unmodifiable(problems),
    warnings: List.unmodifiable(warnings),
    missing: List.unmodifiable(missing),
    unpinned: List.unmodifiable(unpinned),
    hashes: Map.unmodifiable(hashes),
  );
}

/// One staged runtime directory ready to ship beside a packaged Agent.
class SttRuntimeStage {
  const SttRuntimeStage({
    required this.target,
    required this.directory,
    required this.hashes,
    required this.whisperCppVersion,
  });

  final SttNativeTarget target;

  /// `<stageRoot>/native/<tag>`.
  final String directory;
  final Map<String, String> hashes;
  final String whisperCppVersion;
}

/// Copies exactly the required libraries into `<stageRoot>/native/<tag>/`.
///
/// The copy is an allowlist, never a directory copy: model files and build
/// leftovers (`*.bin`, `ggml-model-*`, markers, logs) can never be bundled with
/// the Agent. An unverified or foreign-architecture runtime is refused.
///
/// The whisper libraries come from `agent/native/<tag>/`; the sherpa-onnx
/// libraries come from the engine package's own resolution (the pub cache), which
/// is why [sherpaSource] is asked for rather than guessed. They are copied into
/// `native/<tag>/sherpa/` with their loader-relative paths preserved.
Future<SttRuntimeStage> stageSttRuntime({
  required Directory nativeRoot,
  required SttNativeTarget target,
  required Directory stageRoot,
  required SttRuntimeManifest manifest,
  required SttRuntimeVerification verification,
  String? sherpaSource,
}) async {
  if (!verification.ok) {
    throw SttRuntimeStageException(
      'refusing to stage an unverified runtime: '
      '${verification.problems.join(', ')}',
    );
  }
  final source = Directory('${nativeRoot.path}/${target.nativeDirectory}');
  final destination = Directory('${stageRoot.path}/native/${target.nativeDirectory}');
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  destination.createSync(recursive: true);
  final hashes = <String, String>{};
  for (final name in target.requiredLibraries) {
    final from = File('${source.path}/$name');
    final to = File('${destination.path}/$name');
    await from.copy(to.path);
    hashes[name] = verification.hashes[name] ?? await sha256OfFile(to);
  }
  if (sherpaEngineAvailable) {
    if (sherpaSource == null || sherpaSource.isEmpty) {
      throw const SttRuntimeStageException(
        'the sherpa engine is part of this build but its libraries were not '
        'found; a packaged runtime must ship them',
      );
    }
    for (final relative in target.sherpaLibraries) {
      final from = File('$sherpaSource/$relative');
      if (!from.existsSync()) {
        throw SttRuntimeStageException(
          'the sherpa engine is missing $relative in $sherpaSource',
        );
      }
      final key = '${target.sherpaNativeSubdirectory}/$relative';
      final to = File(
        '${destination.path}/${target.sherpaNativeSubdirectory}/$relative',
      );
      await to.parent.create(recursive: true);
      await from.copy(to.path);
      hashes[key] = verification.hashes[key] ?? await sha256OfFile(to);
    }
  }
  return SttRuntimeStage(
    target: target,
    directory: destination.path,
    hashes: Map.unmodifiable(hashes),
    whisperCppVersion: manifest.whisperCppVersion,
  );
}

/// Builds the deterministic stage manifest written next to the staged runtime.
///
/// The document carries only values derived from produced bytes: no timestamp,
/// no build host, sorted keys. It is a workflow artifact that a human reviews
/// before any value is copied into `agent/native/checksums.json`.
Map<String, Object?> buildStageManifest({
  required SttRuntimeStage stage,
  required SttRuntimeVerification verification,
  required Map<String, Object?>? archive,
}) {
  final files = <String, Object?>{};
  final names = stage.hashes.keys.toList()..sort();
  for (final name in names) {
    files[name] = {
      'sha256': stage.hashes[name],
      'size': File('${stage.directory}/$name').lengthSync(),
    };
  }
  return {
    'schema': 1,
    'target': stage.target.tag,
    'native_directory': stage.target.nativeDirectory,
    'whisper_cpp_version': stage.whisperCppVersion,
    'pin_state': verification.pinState.name,
    'pinned': verification.pinned,
    'files': files,
    'archive': ?archive,
  };
}

/// Writes [manifest] as canonical, newline-terminated JSON.
///
/// Key order comes from the insertion order [buildStageManifest] fixes, so the
/// document is byte-stable across runs.
Future<File> writeStageManifest({
  required Directory stageRoot,
  required SttNativeTarget target,
  required Map<String, Object?> manifest,
}) async {
  final file = File('${stageRoot.path}/stt-runtime-${target.tag}.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    flush: true,
  );
  return file;
}

/// Thrown when staging refuses an unverified runtime.
class SttRuntimeStageException implements Exception {
  const SttRuntimeStageException(this.message);

  final String message;

  @override
  String toString() => 'SttRuntimeStageException: $message';
}

/// Streaming sha256 of [file].
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// sha256 of [file], read in one pass.
///
/// Used inside the verification closure, where an await would force the whole
/// check to be async per file for no benefit: the largest library here is tens
/// of megabytes.
String sha256OfFileSync(File file) =>
    sha256.convert(file.readAsBytesSync()).toString();

/// Compares dotted versions such as `12.0` and `10.15.7`.
int compareVersions(String a, String b) {
  final left = a.split('.').map(_versionPart).toList(growable: false);
  final right = b.split('.').map(_versionPart).toList(growable: false);
  final length = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    final l = index < left.length ? left[index] : 0;
    final r = index < right.length ? right[index] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

int _versionPart(String value) => int.tryParse(value) ?? 0;

/// Arguments the tool hands to `tool/build_whispercpp.sh`.
///
/// The script takes the **tag-style** architecture (`x64` / `arm64`) and maps it
/// to the CMake spelling itself, so this must never forward
/// [SttNativeTarget.cmakeArchitecture]: passing `x86_64` used to fail the
/// script's own architecture check and left Intel unable to build at all. The
/// deployment target is macOS-only, so Linux and Windows get exactly four
/// arguments.
List<String> sttPosixBuilderArguments({
  required SttNativeTarget target,
  required String whisperSource,
  required String outputDirectory,
}) {
  return <String>[
    'tool/build_whispercpp.sh',
    whisperSource,
    outputDirectory,
    target.cpuName,
    if (target.macosDeploymentTarget != null) target.macosDeploymentTarget!,
  ];
}

/// Arguments the tool hands to `tool/build_whispercpp.ps1`.
///
/// `-Arch` takes the same tag-style value (`x64` / `arm64`) the POSIX script
/// takes, and the script validates it against the host CPU.
List<String> sttWindowsBuilderArguments({
  required SttNativeTarget target,
  required String whisperSource,
  required String outputDirectory,
}) {
  return <String>[
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'tool/build_whispercpp.ps1',
    whisperSource,
    outputDirectory,
    '-Arch',
    target.cpuName,
  ];
}

/// One archive download request for the binary-only fallback.
class SttArchiveRequest {
  const SttArchiveRequest({
    required this.url,
    required this.fileName,
    required this.sha256,
  });

  final String url;
  final String fileName;

  /// Pinned `_archive` hash the downloaded bytes must match.
  final String sha256;
}

/// Resolves exactly one archive URL and file name for the download fallback.
///
/// The published artifact carries the **release** version
/// (`sanad-agent-runtime-<release>-<platform>-<arch>.tar.gz`), which the tool
/// cannot infer from the whisper.cpp version, so a caller passes either the
/// published asset URL (preferred) or an explicit name beside a base URL. The
/// whisper-version default stays only for a locally produced archive.
///
/// Returns null when the request cannot be formed safely: no pinned `_archive`
/// hash, no location, a name that is not a plain `*.tar.gz` file, or a URL that
/// is not HTTPS. A null result is a hard failure at the call site — there is no
/// unverified or cleartext fallback.
SttArchiveRequest? sttArchiveRequest({
  required SttNativeTarget target,
  required SttRuntimeManifest manifest,
  required String whisperVersion,
  String? baseUrl,
  String? archiveName,
  String? archiveUrl,
}) {
  final pin = manifest.archiveHashFor(target);
  if (pin == null) return null;
  final explicitUrl = archiveUrl?.trim() ?? '';
  final location = baseUrl?.trim() ?? '';
  final String fileName;
  final String url;
  if (explicitUrl.isNotEmpty) {
    final parsed = Uri.tryParse(explicitUrl);
    if (parsed == null || !parsed.hasScheme || parsed.pathSegments.isEmpty) {
      return null;
    }
    fileName = parsed.pathSegments.last;
    url = explicitUrl;
  } else {
    final explicitName = archiveName?.trim() ?? '';
    fileName = explicitName.isNotEmpty
        ? explicitName
        : 'sanad-stt-${target.tag}-v$whisperVersion.tar.gz';
    if (location.isEmpty) return null;
    url = '${location.replaceAll(RegExp(r'/$'), '')}/$fileName';
  }
  if (!fileName.endsWith('.tar.gz') || fileName.contains('/')) return null;
  // A product binary is only ever fetched over HTTPS with a pinned hash. Local
  // `file://` fixtures belong to the injected installer harness, which has its
  // own explicit test-only seam, not to the product download path.
  final resolved = Uri.tryParse(url);
  if (resolved == null ||
      resolved.scheme != 'https' ||
      resolved.host.isEmpty) {
    return null;
  }
  return SttArchiveRequest(url: url, fileName: fileName, sha256: pin);
}
