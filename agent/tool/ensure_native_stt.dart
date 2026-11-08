/// Makes the native whisper.cpp runtime available for the current platform.
///
/// The binaries are deliberately **not** tracked in git: they are per-platform
/// build products and every rebuild would add a few megabytes to history
/// forever. This script is what a fresh clone runs before the daemon can
/// dictate, and what packaging runs before bundling:
///
///   1. If `agent/native/<platform>/` already holds the exact files (and their
///      checksums match `agent/native/checksums.json`), do nothing.
///   2. Else, if a release base URL is known, download the pinned archive and
///      verify its sha256 before extracting.
///   3. Else, build from a whisper.cpp source tree when cmake is available.
///   4. Else, fail with an actionable message (`engine_missing` at runtime).
///
/// Usage:
///   fvm dart run tool/ensure_native_stt.dart [--force]
///       [--base-url https://…] [--whisper-src /path/to/whisper.cpp]
///
/// Environment fallbacks: `SANAD_STT_BASE_URL`, `WHISPER_CPP_SRC`.
library;

import 'dart:convert';
import 'dart:io';

const String _defaultWhisperCppVersion = '1.9.5';

/// Files the daemon needs at runtime, per platform.
List<String> _requiredFiles(String platform, {required bool metal}) {
  switch (platform) {
    case 'macos-arm64':
      return [
        'libsanad_whisper.dylib',
        'libwhisper.1.dylib',
        'libggml.0.dylib',
        'libggml-base.0.dylib',
        'libggml-cpu.0.dylib',
        'libggml-blas.0.dylib',
        if (metal) 'libggml-metal.0.dylib',
      ];
    case 'windows-x64':
    case 'windows-arm64':
      return [
        'sanad_whisper.dll',
        'whisper.dll',
        'ggml.dll',
        'ggml-base.dll',
        'ggml-cpu.dll',
      ];
    default:
      return [
        'libsanad_whisper.so',
        'libwhisper.so.1',
        'libggml.so.0',
        'libggml-base.so.0',
        'libggml-cpu.so.0',
      ];
  }
}

String _platformTag() {
  final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
  if (Platform.isMacOS) return 'macos-$arch';
  if (Platform.isWindows) return 'windows-$arch';
  return 'linux-$arch';
}

String _nativeDir(String platform) => 'native/${platform.split('-').first}';

/// Marker the daemon reads to show "preparing" instead of "missing".
final File _preparingMarker = File('native/.stt-preparing');

void _clearMarker() {
  if (_preparingMarker.existsSync()) {
    try {
      _preparingMarker.deleteSync();
    } on Object {
      // Leftover markers expire by age (see DictationService.readiness).
    }
  }
}

void main(List<String> args) {
  // Tell the daemon a build/download is in progress, so the UI can say
  // "preparing" instead of "missing" while this runs. Removed on exit.
  try {
    _preparingMarker.writeAsStringSync(
      DateTime.now().toUtc().toIso8601String(),
      flush: true,
    );
  } on Object {
    // A read-only checkout simply skips the marker; the daemon then reports
    // `native_runtime_missing` for the few minutes this takes.
  }
  try {
    _run(args);
  } finally {
    _clearMarker();
  }
}

void _run(List<String> args) {
  final force = args.contains('--force');
  final baseUrl =
      _flag(args, '--base-url') ?? Platform.environment['SANAD_STT_BASE_URL'];
  final whisperSrc = _flag(args, '--whisper-src') ??
      Platform.environment['WHISPER_CPP_SRC'];

  final platform = _platformTag();
  final metal = platform.startsWith('macos');
  final dir = _nativeDir(platform);
  final required = _requiredFiles(platform, metal: metal);

  final manifest = _readManifest();
  final version = manifest['whisper_cpp_version'] as String? ??
      _defaultWhisperCppVersion;
  final expected =
      (manifest['artifacts'] as Map?)?[platform] as Map<String, dynamic>?;

  final missing = required
      .where((name) => !File('$dir/$name').existsSync())
      .toList(growable: false);

  if (!force && missing.isEmpty) {
    final bad = _checksumMismatches(required, expected, dir);
    if (bad.isEmpty) {
      stdout.writeln('native stt ready: $dir (whisper.cpp $version, $platform)');
      return;
    }
    stdout.writeln('checksum mismatch: ${bad.join(', ')} — reinstalling');
  }

  stdout.writeln(
    'native stt missing for $platform in $dir: '
    '${missing.isEmpty ? '(checksums only)' : missing.join(', ')}',
  );

  if (baseUrl != null && baseUrl.isNotEmpty) {
    if (_download(baseUrl, version, platform, dir, expected)) return;
  }

  if (whisperSrc != null && whisperSrc.isNotEmpty) {
    if (_build(whisperSrc, platform)) return;
  }

  // A dev checkout usually has the whisper.cpp tree next to the agent folder;
  // discovering it keeps `sanad-dev run` self-healing after a fresh clone or a
  // `git clean`, instead of leaving dictation dead until someone reads docs.
  final discovered = _discoverWhisperSource();
  if (discovered != null && _build(discovered, platform)) return;

  stderr.writeln('''
Could not prepare the native dictation runtime.

Fix one of these and re-run:
  * download:  fvm dart run tool/ensure_native_stt.dart --base-url <release-url>
  * build:     fvm dart run tool/ensure_native_stt.dart --whisper-src <whisper.cpp>
  * or drop a whisper.cpp checkout at ../refrence_projects/whisper.cpp,
               .whisper.cpp or ~/whisper.cpp and re-run this script
  * or run the packaged binary, which ships the libraries beside the executable
               (native/$platformName/) so nothing needs to be built.

Without it the agent still runs; dictation reports `native_runtime_missing`.''');
  _clearMarker();
  exit(2);
}

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

String get platformName => _platformTag().split('-').first;

Map<String, dynamic> _readManifest() {
  final file = File('native/checksums.json');
  if (!file.existsSync()) return const {};
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map<String, dynamic> ? decoded : const {};
  } on Object {
    return const {};
  }
}

List<String> _checksumMismatches(
  List<String> files,
  Map<String, dynamic>? expected,
  String dir,
) {
  if (expected == null) return [];
  final bad = <String>[];
  for (final name in files) {
    final want = expected[name] as String?;
    if (want == null) continue;
    final file = File('$dir/$name');
    if (!file.existsSync()) continue;
    if (_sha256(file) != want) bad.add(name);
  }
  return bad;
}

String _sha256(File file) {
  final result = Process.runSync('shasum', ['-a', '256', file.path]);
  if (result.exitCode != 0) {
    final certUtil = Process.runSync('certutil', ['-hashfile', file.path, 'SHA256']);
    return (certUtil.stdout as String).split(RegExp(r'\s+')).first.toLowerCase();
  }
  return (result.stdout as String).split(' ').first;
}

bool _download(
  String baseUrl,
  String version,
  String platform,
  String dir,
  Map<String, dynamic>? expected,
) {
  final archive = 'sanad-stt-$platform-v$version.tar.gz';
  final url = '${baseUrl.replaceAll(RegExp(r'/$'), '')}/$archive';
  final tmp = File('${Directory.systemTemp.path}/$archive');
  stdout.writeln('downloading $url');
  final curl = Process.runSync('curl', ['-fL', url, '-o', tmp.path]);
  if (curl.exitCode != 0) {
    stderr.writeln('download failed: ${curl.stderr}');
    return false;
  }
  if (expected != null && expected['_archive'] is String) {
    final want = expected['_archive'] as String;
    if (_sha256(tmp) != want) {
      stderr.writeln('archive checksum mismatch');
      return false;
    }
  }
  Directory(dir).createSync(recursive: true);
  final staging = '$dir.tmp';
  final stagingDir = Directory(staging);
  if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
  stagingDir.createSync(recursive: true);
  final tar = Process.runSync('tar', ['-xzf', tmp.path, '-C', staging]);
  if (tar.exitCode != 0) {
    stderr.writeln('extract failed: ${tar.stderr}');
    return false;
  }
  // Publish atomically: a daemon that starts a session mid-build must never open
  // a half-written library.
  _publish(staging, dir);
  stdout.writeln('extracted into $dir');
  return true;
}

void _publish(String staging, String dir) {
  final target = Directory(dir);
  if (target.existsSync()) target.deleteSync(recursive: true);
  Directory(staging).renameSync(dir);
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
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  if (home.isNotEmpty) {
    final candidate = Directory('$home/whisper.cpp');
    if (candidate.existsSync() &&
        File('${candidate.path}/CMakeLists.txt').existsSync()) {
      return candidate.path;
    }
  }
  return null;
}

bool _build(String whisperSrc, String platform) {
  if (!Directory(whisperSrc).existsSync()) {
    stderr.writeln('whisper source not found at $whisperSrc');
    return false;
  }
  final cmake = Process.runSync('cmake', ['--version']);
  if (cmake.exitCode != 0) {
    stderr.writeln('cmake is not installed');
    return false;
  }
  stdout.writeln('building whisper.cpp from $whisperSrc (this takes a few minutes)');
  final staging = '${_nativeDir(_platformTag())}.tmp';
  final stagingDir = Directory(staging);
  if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
  final ProcessResult result;
  if (Platform.isWindows) {
    result = Process.runSync('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      'tool/build_whispercpp.ps1',
      whisperSrc,
      staging,
    ]);
  } else {
    result = Process.runSync(
      'bash',
      ['tool/build_whispercpp.sh', whisperSrc, staging],
      environment: {'GGML_METAL': platform.startsWith('macos') ? 'ON' : 'OFF'},
    );
  }
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) return false;
  // A partially built folder would be published as "ready" and then fail to
  // load in the daemon, so refuse to swap it in.
  final missing = _requiredFiles(
    platform,
    metal: platform.startsWith('macos'),
  ).where((name) => !File('$staging/$name').existsSync()).toList(growable: false);
  if (missing.isNotEmpty) {
    stderr.writeln('build produced an incomplete runtime: ${missing.join(', ')}');
    return false;
  }
  // Swap the finished build in at once so dictation never opens a partial file.
  _publish(staging, _nativeDir(platform));
  return true;
}
