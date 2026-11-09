part of '../../../sanad_dev_cli.dart';

/// Prepares the native dictation runtime before the daemon starts.
///
/// `agent/native/<platform>-<architecture>/` is not tracked: the whisper shim and
/// its ggml libraries are per-platform build products. A fresh clone therefore
/// has none, and `tool/ensure_native_stt.dart` verifies, downloads or builds
/// them. This runs the script once per machine; a failure only leaves dictation
/// unavailable (the daemon reports `native_runtime_missing`), never blocks run.
///
/// The probe is architecture-qualified: after the runtime moved to
/// `native/<platform>-<architecture>/` an unqualified probe never saw it and
/// started a background installer on every run. The Apple Silicon directory is
/// the one bounded legacy alias the loader still accepts.
Future<bool> prepareNativeDictation(
  String agentDirectory, {
  Future<void> Function(String command, String workingDirectory)? starter,
}) async {
  final tag = nativeRuntimeTag();
  if (tag == null) return false;
  final shimName = Platform.isMacOS
      ? 'libsanad_whisper.dylib'
      : (Platform.isWindows ? 'sanad_whisper.dll' : 'libsanad_whisper.so');
  final candidates = <String>[
    '$agentDirectory/native/$tag/$shimName',
    if (tag == 'macos-arm64') '$agentDirectory/native/macos/$shimName',
  ];
  if (candidates.any((path) => File(path).existsSync())) return false;

  stdout.writeln(
    'Preparing the native dictation runtime in the background '
    '(dictation works as soon as it finishes)…',
  );
  // Detached on purpose: `sanad-dev run` exits as soon as the daemon is
  // published, so an awaited child would be killed mid-build. The shell form
  // keeps the log next to the marker the daemon watches.
  final logFile = Platform.isWindows ? 'NUL' : 'native/.stt-prepare.log';
  final command = Platform.isWindows
      ? 'fvm dart run tool\\ensure_native_stt.dart > $logFile 2>&1'
      : 'fvm dart run tool/ensure_native_stt.dart > $logFile 2>&1';
  try {
    if (starter != null) {
      await starter(command, agentDirectory);
    } else {
      await Process.start(
        Platform.isWindows ? 'cmd' : '/bin/sh',
        Platform.isWindows ? ['/c', command] : ['-c', command],
        workingDirectory: agentDirectory,
        mode: ProcessStartMode.detached,
      );
    }
    return true;
  } on Object catch (error) {
    stderr.writeln(
      'Could not start the native dictation build ($error). '
      'Run `fvm dart run tool/ensure_native_stt.dart` in the agent folder.',
    );
    return false;
  }
}

/// Directory name the loader searches: `native/<platform>-<architecture>`.
///
/// The per-platform library table lives in the Agent; this only mirrors the
/// layout the two sides agree on, so the launcher never guesses a slice. A host
/// pair outside the table returns null and the probe stays out of the way.
String? nativeRuntimeTag({String? operatingSystem, String? architecture}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final abi = architecture ?? _hostArchitecture();
  if (abi == null) return null;
  const supported = {'macos', 'linux', 'windows'};
  if (!supported.contains(os)) return null;
  // A pair outside the table has no `native/<tag>` directory to find, so the
  // probe stays out of the way instead of starting an installer for a directory
  // the loader would never search.
  const supportedArchitectures = {'arm64', 'x64'};
  if (!supportedArchitectures.contains(abi)) return null;
  return '$os-$abi';
}

/// `arm64` or `x64` from the Dart ABI, matching the Agent's own mapping source.
String? _hostArchitecture() {
  final value = Abi.current().toString().toLowerCase();
  if (value.contains('arm64')) return 'arm64';
  if (value.contains('x64')) return 'x64';
  return null;
}
