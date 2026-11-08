/// Makes the native whisper.cpp runtime available for the current platform.
///
/// The binaries are deliberately **not** tracked in git: they are per-platform
/// build products and every rebuild would add a few megabytes to history
/// forever. This script is what a fresh clone runs before the daemon can
/// dictate, and what packaging runs before bundling:
///
///   1. If `agent/native/<tag>/` already holds the exact files for this OS and
///      CPU architecture (and their checksums match `agent/native/checksums.json`
///      when it pins them), do nothing.
///   2. Else, if a release base URL is known and the manifest pins the archive
///      hash, download the archive and verify it before extracting.
///   3. Else, build from a whisper.cpp source tree when cmake is available.
///   4. Else, fail with an actionable message (`engine_missing` at runtime).
///
/// `<tag>` is `<os>-<cpu>` (`macos-arm64`, `macos-x64`, `windows-x64`, …) and
/// comes from the shared mapping in
/// `lib/infrastructure/stt/stt_native_platform.dart`, so the daemon loader and
/// this tool can never disagree about where the runtime lives.
///
/// Usage:
///   fvm dart run tool/ensure_native_stt.dart [--force]
///       [--verify] [--stage <dir>] [--archive <dir>]
///       [--base-url https://…] [--whisper-src /path/to/whisper.cpp]
///
///   --verify            check the installed runtime and the manifest entry
///                       without building, downloading, or mutating anything
///   `--stage <dir>`     copy the verified runtime into `<dir>/native/<tag>/`
///                       (the packaged Agent layout) plus a stage manifest
///   `--archive <dir>`   write the reproducible archive
///                       `sanad-stt-<tag>-v<version>.tar.gz` into `<dir>` and
///                       record its real sha256
///
/// Environment fallbacks: `SANAD_STT_BASE_URL`, `WHISPER_CPP_SRC`,
/// `SOURCE_DATE_EPOCH` (archive timestamps; default `0`).
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';

import 'stt_native_archive.dart';
import 'stt_native_runtime.dart';

const String _defaultWhisperCppVersion = '1.9.5';
const String _nativeRoot = 'native';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.error != null) {
    stderr.writeln(options.error);
    exit(2);
  }
  final nativeRoot = Directory(_nativeRoot);
  // Tell the daemon an install is in progress, so the UI can say "preparing"
  // instead of "missing" while this runs. Pure inspection never marks.
  final marker = File('${nativeRoot.path}/$sttPreparingMarkerName');
  if (!options.inspectsOnly) _writeMarker(marker);
  var code = 0;
  try {
    code = await _run(options, nativeRoot);
  } finally {
    if (!options.inspectsOnly) _clearMarker(marker);
  }
  if (code != 0) exit(code);
}

Future<int> _run(_Options options, Directory nativeRoot) async {
  final target = SttNativeTarget.tryCurrent();
  if (target == null) {
    stderr.writeln('''
This machine has no native dictation runtime target.

The local engine is built for macOS (arm64, x64), Windows (x64, arm64), and
Linux (x64, arm64). The agent keeps running without it; dictation reports
`unsupported_platform`.''');
    return 2;
  }

  final expectedTarget = options.expectTarget;
  if (expectedTarget != null && expectedTarget != target.tag) {
    // The release matrix labels a runner by the payload it must produce; a
    // silent mismatch would stage one architecture into another's payload.
    stderr.writeln(
      'native_stt_target_mismatch: expected $expectedTarget but this host is '
      '${target.tag}',
    );
    return 2;
  }

  final manifestFile = File(
    '${nativeRoot.path}/$sttRuntimeManifestFileName',
  );
  final manifest = SttRuntimeManifest.load(manifestFile);
  final version = manifest.whisperCppVersion.isEmpty
      ? _defaultWhisperCppVersion
      : manifest.whisperCppVersion;
  final directory = '${nativeRoot.path}/${target.nativeDirectory}';

  if (options.verify) {
    final verification = await verifySttRuntime(
      nativeRoot: nativeRoot,
      target: target,
      manifest: manifest,
    );
    _printVerification(verification, version);
    if (!verification.ok) return 1;
    if (options.stageDirectory == null && options.archiveDirectory == null) {
      return 0;
    }
    // `--verify` composes with staging so one command both gates and packages
    // the same bytes; the verification is reused, never recomputed.
    return _stageAndArchive(
      options: options,
      target: target,
      manifest: manifest,
      nativeRoot: nativeRoot,
      version: version,
      verification: verification,
    );
  }

  final state = await _localState(directory, target, manifest);
  if (!options.force && state.isReady) {
    if (state.checksumMismatches.isEmpty) {
      stdout.writeln(
        'native stt ready: $directory (whisper.cpp $version, ${target.tag})',
      );
    } else {
      // Pinned hashes describe a published artifact; a local rebuild is
      // expected to differ. Rebuilding on every invocation would be worse than
      // stating the difference, and `--verify` is the explicit gate.
      stdout.writeln(
        'native stt ready: $directory (whisper.cpp $version, ${target.tag}); '
        'pinned checksums differ for ${state.checksumMismatches.join(', ')} '
        '— run --verify to compare',
      );
    }
  } else {
    stdout.writeln(
      'native stt missing for ${target.tag} in $directory: ${state.describe()}',
    );
    final installed = await _install(
      options: options,
      target: target,
      manifest: manifest,
      nativeRoot: nativeRoot,
      version: version,
    );
    if (!installed) return 2;
  }

  final prepared = await verifySttRuntime(
    nativeRoot: nativeRoot,
    target: target,
    manifest: manifest,
    requireManifestEntry: false,
  );
  if (!prepared.ok) {
    stderr.writeln(
      'native stt runtime is not usable: ${prepared.problems.join(', ')}',
    );
    return 2;
  }

  if (options.stageDirectory == null && options.archiveDirectory == null) {
    return 0;
  }
  return _stageAndArchive(
    options: options,
    target: target,
    manifest: manifest,
    nativeRoot: nativeRoot,
    version: version,
  );
}

/// Installs the runtime through the first available channel.
Future<bool> _install({
  required _Options options,
  required SttNativeTarget target,
  required SttRuntimeManifest manifest,
  required Directory nativeRoot,
  required String version,
}) async {
  final wantsDownload =
      (options.baseUrl?.isNotEmpty ?? false) ||
      (options.archiveUrl?.isNotEmpty ?? false);
  if (wantsDownload) {
    if (await _download(
      options: options,
      version: version,
      target: target,
      manifest: manifest,
      nativeRoot: nativeRoot,
    )) {
      return true;
    }
  }

  final requested = options.whisperSrc;
  if (requested != null && requested.isNotEmpty) {
    final built = await _build(
      requested,
      target: target,
      manifest: manifest,
      nativeRoot: nativeRoot,
      version: version,
    );
    if (built) return true;
  }

  // A dev checkout usually has the whisper.cpp tree next to the agent folder;
  // discovering it keeps `sanad-dev run` self-healing after a fresh clone or a
  // `git clean`, instead of leaving dictation dead until someone reads docs.
  final discovered = _discoverWhisperSource();
  if (discovered != null) {
    final built = await _build(
      discovered,
      target: target,
      manifest: manifest,
      nativeRoot: nativeRoot,
      version: version,
    );
    if (built) return true;
  }

  stderr.writeln('''
Could not prepare the native dictation runtime for ${target.tag}.

Fix one of these and re-run:
  * download:  fvm dart run tool/ensure_native_stt.dart --archive-url <url of
               sanad-agent-runtime-<release>-${target.tag}.tar.gz from the release>
               (the manifest must already pin that archive as _archive; an
               unverified download is refused)
  * build:     fvm dart run tool/ensure_native_stt.dart --whisper-src <whisper.cpp>
  * or drop a whisper.cpp checkout at ../refrence_projects/whisper.cpp,
               .whisper.cpp or ~/whisper.cpp and re-run this script
  * or run the packaged binary, which ships the libraries beside the executable
               (native/${target.nativeDirectory}/) so nothing needs to be built.

Without it the agent still runs; dictation reports `native_runtime_missing`.''');
  return false;
}

/// Prints the verified runtime and optionally stages/archives it.
Future<int> _stageAndArchive({
  required _Options options,
  required SttNativeTarget target,
  required SttRuntimeManifest manifest,
  required Directory nativeRoot,
  required String version,
  SttRuntimeVerification? verification,
}) async {
  final checked =
      verification ??
      await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifest,
      );
  if (verification == null) _printVerification(checked, version);
  if (!checked.ok) return 1;

  final stageRootPath = options.stageDirectory;
  final SttRuntimeStage? stage;
  if (stageRootPath == null) {
    stage = null;
  } else {
    try {
      stage = await stageSttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        stageRoot: Directory(stageRootPath),
        manifest: manifest,
        verification: checked,
      );
    } on SttRuntimeStageException catch (error) {
      stderr.writeln(error.message);
      return 1;
    }
    stdout.writeln('native_stt_stage=${stage.directory}');
  }

  final sourceDirectory = stage == null
      ? '${nativeRoot.path}/${target.nativeDirectory}'
      : stage.directory;
  Map<String, Object?>? archiveJson;
  final archiveDirectory = options.archiveDirectory;
  if (archiveDirectory != null) {
    final archiveName =
        options.archiveName ?? 'sanad-stt-${target.tag}-v$version.tar.gz';
    final archivePath =
        '${archiveDirectory.replaceAll(RegExp(r'/$'), '')}/$archiveName';
    final archive = await _writeArchive(
      archivePath: archivePath,
      sourceDirectory: sourceDirectory,
      target: target,
    );
    archiveJson = {
      // A relative name keeps the record portable; the workflow already knows
      // the directory it asked for.
      'file': File(archivePath).uri.pathSegments.last,
      'format': 'tar.gz',
      'sha256': archive.sha256,
      'size': archive.size,
    };
    stdout.writeln('native_stt_archive=$archivePath');
    stdout.writeln('native_stt_archive_sha256=${archive.sha256}');
    stdout.writeln('native_stt_archive_size=${archive.size}');
  }

  if (stage != null) {
    final stageManifest = buildStageManifest(
      stage: stage,
      verification: checked,
      archive: archiveJson,
    );
    final file = await writeStageManifest(
      stageRoot: Directory(stageRootPath!),
      target: target,
      manifest: stageManifest,
    );
    stdout.writeln('native_stt_manifest=${file.path}');
  }
  return 0;
}

/// Writes the reproducible archive of [sourceDirectory] to [archivePath].
Future<SttRuntimeArchive> _writeArchive({
  required String archivePath,
  required String sourceDirectory,
  required SttNativeTarget target,
}) async {
  final entries = <String, List<int>>{};
  for (final name in target.requiredLibraries) {
    entries['native/${target.nativeDirectory}/$name'] =
        await File('$sourceDirectory/$name').readAsBytes();
  }
  final bytes = buildDeterministicTarGz(
    entries,
    epochSeconds: _sourceDateEpoch(),
  );
  final file = File(archivePath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  // The recorded hash is derived from the bytes that were just written.
  return SttRuntimeArchive(
    path: file.path,
    sha256: sha256.convert(bytes).toString(),
    size: bytes.length,
    entries: entries.keys.toList()..sort(),
  );
}

int _sourceDateEpoch() {
  final raw = Platform.environment['SOURCE_DATE_EPOCH'];
  if (raw == null) return 0;
  final value = int.tryParse(raw);
  return value == null || value < 0 ? 0 : value;
}

void _printVerification(SttRuntimeVerification verification, String version) {
  final problems = verification.problems.isEmpty
      ? 'none'
      : verification.problems.join(',');
  stdout.writeln('native_stt_target=${verification.target.tag}');
  stdout.writeln('native_stt_dir=${verification.directory}');
  stdout.writeln('native_stt_pin_state=${verification.pinState.name}');
  stdout.writeln('native_stt_pinned=${verification.pinned}');
  stdout.writeln('native_stt_problems=$problems');
  if (verification.warnings.isNotEmpty) {
    stdout.writeln('native_stt_warnings=${verification.warnings.join(',')}');
  }
  if (verification.ok) {
    final pin = verification.pinned ? 'pinned' : verification.pinState.name;
    stdout.writeln(
      'native stt verified: ${verification.directory} '
      '(whisper.cpp $version, ${verification.target.tag}, $pin)',
    );
  } else {
    stderr.writeln(
      'native stt verification failed for ${verification.target.tag}: '
      '${verification.problems.join(', ')}',
    );
  }
}

/// What the local architecture directory currently contains.
class _LocalState {
  const _LocalState({
    required this.missing,
    required this.foreignArchitecture,
    required this.checksumMismatches,
  });

  final List<String> missing;
  final List<String> foreignArchitecture;
  final List<String> checksumMismatches;

  bool get isReady => missing.isEmpty && foreignArchitecture.isEmpty;

  String describe() {
    if (!isReady) {
      if (missing.isNotEmpty) return missing.join(', ');
      return 'wrong architecture: ${foreignArchitecture.join(', ')}';
    }
    return 'checksums only';
  }
}

Future<_LocalState> _localState(
  String directory,
  SttNativeTarget target,
  SttRuntimeManifest manifest,
) async {
  final missing = <String>[];
  final foreign = <String>[];
  final mismatches = <String>[];
  final entry = manifest.entryFor(target);
  for (final name in target.requiredLibraries) {
    final path = '$directory/$name';
    final file = File(path);
    if (!file.existsSync()) {
      missing.add(name);
      continue;
    }
    // A leftover build for the other CPU architecture would be reported as
    // "ready" and then fail inside the daemon; treat it as absent.
    if (!nativeLibraryMatchesTarget(path, target)) {
      foreign.add(name);
      continue;
    }
    final want = entry?[name];
    if (want is! String || want.length != 64) continue;
    if (await sha256OfFile(file) != want) mismatches.add(name);
  }
  return _LocalState(
    missing: missing,
    foreignArchitecture: foreign,
    checksumMismatches: mismatches,
  );
}

/// Downloads and extracts the pinned archive for [target].
///
/// Fails closed when the manifest does not pin the archive hash: an unverified
/// download would defeat the only check a binary-only install can offer.
Future<bool> _download({
  required _Options options,
  required String version,
  required SttNativeTarget target,
  required SttRuntimeManifest manifest,
  required Directory nativeRoot,
}) async {
  final request = sttArchiveRequest(
    target: target,
    manifest: manifest,
    whisperVersion: version,
    baseUrl: options.baseUrl,
    archiveName: options.archiveName,
    archiveUrl: options.archiveUrl,
  );
  if (request == null) {
    // One explicit message per precondition: a missing pin is a different
    // problem from an unusable URL, and both fail closed.
    if (manifest.archiveHashFor(target) == null) {
      stderr.writeln(
        'the manifest records no pinned archive hash for ${target.tag}; '
        'refusing to install an unverified download '
        '(record _archive in native/$sttRuntimeManifestFileName first)',
      );
    } else {
      stderr.writeln(
        'pass an HTTPS --archive-url with the published '
        'sanad-agent-runtime-*.tar.gz asset, or an HTTPS --base-url together '
        'with --archive-name; neither is inferred from the whisper.cpp version',
      );
    }
    return false;
  }
  final workspace = Directory.systemTemp.createTempSync('sanad-stt-download-');
  final tmp = File('${workspace.path}/${request.fileName}');
  try {
    stdout.writeln('downloading ${request.url}');
    final curl = Process.runSync('curl', ['-fL', request.url, '-o', tmp.path]);
    if (curl.exitCode != 0) {
      stderr.writeln('download failed: ${curl.stderr}');
      return false;
    }
    if (await sha256OfFile(tmp) != request.sha256) {
      stderr.writeln('archive checksum mismatch for ${request.fileName}');
      return false;
    }
    final staging = Directory('${nativeRoot.path}/${target.nativeDirectory}.tmp');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final tar = Process.runSync('tar', ['-xzf', tmp.path, '-C', staging.path]);
    if (tar.exitCode != 0) {
      stderr.writeln('extract failed: ${tar.stderr}');
      staging.deleteSync(recursive: true);
      return false;
    }
    // Archives carry the `native/<tag>/` prefix; accept a flat layout too so an
    // older hand-made archive still installs into the right directory.
    final extracted = Directory('${staging.path}/native/${target.nativeDirectory}');
    final source = extracted.existsSync() ? extracted.path : staging.path;
    final checked = await verifySttRuntime(
      nativeRoot: nativeRoot,
      target: target,
      manifest: manifest,
      requireManifestEntry: false,
      requirePinnedHashes: true,
      directoryPath: source,
    );
    if (!checked.ok) {
      stderr.writeln(
        'downloaded runtime failed verification: ${checked.problems.join(', ')}',
      );
      staging.deleteSync(recursive: true);
      return false;
    }
    if (!_publish(source, '${nativeRoot.path}/${target.nativeDirectory}')) {
      staging.deleteSync(recursive: true);
      return false;
    }
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    stdout.writeln('installed into ${nativeRoot.path}/${target.nativeDirectory}');
    return true;
  } finally {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  }
}

/// Swaps [staging] into [directory] with a recoverable two-rename exchange.
///
/// The old directory is renamed aside and the new one renamed in, so this is a
/// two-syscall swap rather than one atomic exchange: `native/<tag>` is briefly
/// absent between the renames, and a true windowless swap would need a
/// platform-specific primitive such as `renameatx_np(RENAME_SWAP)`. A failure
/// puts the previous directory back, so the daemon never keeps a half-published
/// runtime; every step that can throw is inside the handler, which is what
/// turns an unexpected filesystem error into a bounded failure instead of an
/// uncaught stack trace with a leftover `.tmp` directory.
bool _publish(String staging, String directory) {
  final target = Directory(directory);
  final previous = Directory('$directory.old');
  final hadPrevious = target.existsSync();
  try {
    if (previous.existsSync()) previous.deleteSync(recursive: true);
    if (hadPrevious) target.renameSync(previous.path);
    Directory(staging).renameSync(directory);
  } on FileSystemException catch (error) {
    var restored = true;
    if (hadPrevious && !target.existsSync() && previous.existsSync()) {
      try {
        previous.renameSync(directory);
      } on FileSystemException catch (restoreError) {
        restored = false;
        stderr.writeln('restoring $directory failed: ${restoreError.message}');
      }
    }
    stderr.writeln(
      'publishing $directory failed: ${error.message}'
      '${restored ? '' : '; the previous runtime is kept at ${previous.path}'}',
    );
    return false;
  }
  try {
    if (previous.existsSync()) previous.deleteSync(recursive: true);
  } on FileSystemException catch (error) {
    // The swap already committed; a stale `.old` directory is not a failure.
    stderr.writeln('removing ${previous.path} failed: ${error.message}');
  }
  return true;
}

/// First usable whisper.cpp checkout near the agent folder, if any.
///
/// Walks up from the agent folder because a dev checkout may live in the main
/// repository while the agent runs from a worktree.
String? _discoverWhisperSource() {
  const names = [
    'refrence_projects/whisper.cpp',
    'reference_projects/whisper.cpp',
    '.whisper.cpp',
    'whisper.cpp',
  ];
  var dir = Directory.current.absolute;
  for (var depth = 0; depth < 5; depth++) {
    for (final name in names) {
      final candidate = Directory('${dir.path}/$name');
      if (candidate.existsSync() &&
          File('${candidate.path}/CMakeLists.txt').existsSync()) {
        return candidate.path;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (home.isNotEmpty) {
    final candidate = Directory('$home/whisper.cpp');
    if (candidate.existsSync() &&
        File('${candidate.path}/CMakeLists.txt').existsSync()) {
      return candidate.path;
    }
  }
  return null;
}

/// Builds whisper.cpp for [target] and publishes the result atomically.
Future<bool> _build(
  String whisperSrc, {
  required SttNativeTarget target,
  required SttRuntimeManifest manifest,
  required Directory nativeRoot,
  required String version,
}) async {
  if (!Directory(whisperSrc).existsSync()) {
    stderr.writeln('whisper source not found at $whisperSrc');
    return false;
  }
  final cmake = Process.runSync('cmake', ['--version']);
  if (cmake.exitCode != 0) {
    stderr.writeln('cmake is not installed');
    return false;
  }
  stdout.writeln(
    'building whisper.cpp for ${target.tag} from $whisperSrc '
    '(this takes a few minutes)',
  );
  final staging = '${nativeRoot.path}/${target.nativeDirectory}.tmp';
  final stagingDir = Directory(staging);
  if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
  final ProcessResult result;
  if (Platform.isWindows) {
    result = Process.runSync(
      'powershell',
      sttWindowsBuilderArguments(
        target: target,
        whisperSource: whisperSrc,
        outputDirectory: staging,
      ),
    );
  } else {
    result = Process.runSync(
      'bash',
      sttPosixBuilderArguments(
        target: target,
        whisperSource: whisperSrc,
        outputDirectory: staging,
      ),
      environment: {'GGML_METAL': target.usesMetal ? 'ON' : 'OFF'},
    );
  }
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    _discard(stagingDir);
    return false;
  }
  // A partially built or cross-architecture folder would be published as
  // "ready" and then fail to load in the daemon, so refuse to swap it in.
  final built = await verifySttRuntime(
    nativeRoot: nativeRoot,
    target: target,
    manifest: manifest,
    requireManifestEntry: false,
    directoryPath: staging,
  );
  if (!built.ok) {
    stderr.writeln(
      'build produced an unusable runtime for ${target.tag}: '
      '${built.problems.join(', ')}',
    );
    _discard(stagingDir);
    return false;
  }
  if (built.warnings.isNotEmpty) {
    stdout.writeln('build warnings: ${built.warnings.join(', ')}');
  }
  if (!_publish(staging, '${nativeRoot.path}/${target.nativeDirectory}')) {
    _discard(stagingDir);
    return false;
  }
  stdout.writeln(
    'built: ${nativeRoot.path}/${target.nativeDirectory} '
    '(whisper.cpp $version, ${target.tag})',
  );
  return true;
}

void _discard(Directory staging) {
  if (staging.existsSync()) staging.deleteSync(recursive: true);
}

void _writeMarker(File marker) {
  try {
    marker
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        DateTime.now().toUtc().toIso8601String(),
        flush: true,
      );
  } on Object {
    // A read-only checkout simply skips the marker; the daemon then reports
    // `native_runtime_missing` for the few minutes this takes.
  }
}

void _clearMarker(File marker) {
  try {
    if (marker.existsSync()) marker.deleteSync();
  } on Object {
    // Leftover markers expire by age (see DictationService.readiness).
  }
}

class _Options {
  const _Options({
    required this.force,
    required this.verify,
    required this.baseUrl,
    required this.whisperSrc,
    required this.stageDirectory,
    required this.archiveDirectory,
    required this.archiveName,
    required this.archiveUrl,
    required this.expectTarget,
    required this.error,
  });

  factory _Options.parse(List<String> args) {
    var force = false;
    var verify = false;
    String? baseUrl;
    String? whisperSrc;
    String? stageDirectory;
    String? archiveDirectory;
    String? archiveName;
    String? archiveUrl;
    String? expectTarget;
    String? error;
    const valueFlags = {
      '--base-url',
      '--whisper-src',
      '--stage',
      '--archive',
      '--archive-name',
      '--archive-url',
      '--expect-target',
    };
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      String? value;
      if (valueFlags.contains(argument)) {
        if (index + 1 >= args.length) {
          error = 'missing value for $argument\n$_usage';
          break;
        }
        value = args[++index];
      }
      switch (argument) {
        case '--force':
          force = true;
        case '--verify':
          verify = true;
        case '--base-url':
          baseUrl = value;
        case '--whisper-src':
          whisperSrc = value;
        case '--stage':
          stageDirectory = value;
        case '--archive':
          archiveDirectory = value;
        case '--archive-name':
          if (value == null ||
              value.isEmpty ||
              value.contains('/') ||
              value.contains('\\')) {
            error = 'invalid value for --archive-name\n$_usage';
          } else {
            archiveName = value;
          }
        case '--archive-url':
          final parsed = value == null ? null : Uri.tryParse(value);
          if (value == null ||
              !value.endsWith('.tar.gz') ||
              parsed == null ||
              parsed.scheme != 'https' ||
              parsed.host.isEmpty) {
            error =
                'invalid value for --archive-url '
                '(an HTTPS *.tar.gz URL is required)\n$_usage';
          } else {
            archiveUrl = value;
          }
        case '--expect-target':
          expectTarget = value;
        default:
          error = 'unknown option: $argument\n$_usage';
      }
      if (error != null) break;
    }
    return _Options(
      force: force,
      verify: verify,
      baseUrl: baseUrl ?? Platform.environment['SANAD_STT_BASE_URL'],
      whisperSrc: whisperSrc ?? Platform.environment['WHISPER_CPP_SRC'],
      stageDirectory: stageDirectory,
      archiveDirectory: archiveDirectory,
      archiveName: archiveName,
      archiveUrl: archiveUrl,
      expectTarget: expectTarget,
      error: error,
    );
  }

  final bool force;
  final bool verify;
  final String? baseUrl;
  final String? whisperSrc;
  final String? stageDirectory;
  final String? archiveDirectory;
  final String? archiveName;
  final String? archiveUrl;
  final String? expectTarget;
  final String? error;

  /// True when the run only inspects or packages an existing runtime.
  bool get inspectsOnly =>
      verify || stageDirectory != null || archiveDirectory != null;
}

const String _usage = 'usage: fvm dart run tool/ensure_native_stt.dart '
    '[--force] [--verify] [--expect-target <platform-arch>] [--stage <dir>] '
    '[--archive <dir>] [--archive-name <file.tar.gz>] [--base-url <url>] '
    '[--archive-url <url>] [--whisper-src <whisper.cpp>]';
