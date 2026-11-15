part of '../../../sanad_dev_cli.dart';

/// Name of the marker `tool/ensure_native_stt.dart` writes while it works.
///
/// The daemon reads the same file to report `native_runtime_preparing`, so the
/// launcher and readiness cannot disagree about whether an attempt is running.
const String nativeSttPreparingMarkerName = '.stt-preparing';

/// Durable, bounded attempt log, relative to the agent folder.
///
/// It is the only record a failed or interrupted preparation leaves behind, so
/// it is written on every platform — the null device would delete exactly the diagnostics
/// a fresh Windows checkout needs.
const String nativeSttLogFileName = '.stt-prepare.log';

/// The acquisition tool the launcher runs; it owns download, build, and verify.
const String nativeSttToolPath = 'tool/ensure_native_stt.dart';

/// How the detached shell names FVM.
///
/// The resolved directory is prepended to the child's `PATH` instead of being
/// interpolated here, so this stays a single token the shell cannot misparse.
const String nativeSttFvmCommand = 'fvm';

/// Log path relative to the agent folder, for the detached shell redirect.
///
/// A relative path keeps the generated command free of quoting, which is the one
/// part of a detached shell string that cannot be tested on the other platform.
const String _nativeSttLogRelativePath = 'native/$nativeSttLogFileName';

/// How long a preparing marker is trusted as evidence of a running attempt.
///
/// Mirrors `sttPreparingMarkerMaxAge` in
/// `agent/lib/infrastructure/stt/stt_native_platform.dart`, for the reason
/// [nativeRuntimeTag] mirrors the platform table: the launcher must never
/// import the Agent package, and the value is a published rule rather than an
/// implementation detail. A stale marker (a killed build) expires, and the tool
/// itself refuses a second concurrent attempt with the same window.
const Duration nativeSttAttemptMaxAge = Duration(minutes: 30);

/// Upper bound of the durable preparation log.
///
/// A build streams a megabyte of compiler output; the log keeps the attempt that
/// produced the current state and drops the previous ones instead of growing
/// forever. Mirrors `sttPreparationLogLimitBytes` in the Agent.
const int nativeSttLogLimitBytes = 1024 * 1024;

/// First line of a log that was reset for exceeding [nativeSttLogLimitBytes].
const String nativeSttLogResetHeader =
    '# native dictation preparation log reset: the previous attempt exceeded ';

/// How long a launcher watches a detached attempt before handing it over.
/// Environment variable a wrapper sets to the FVM it already resolved.
///
/// The launcher spawns the acquisition tool through a shell so the attempt can
/// own its log; a shim-started terminal may not expose `fvm` on `PATH` the way
/// the wrapper did, so the resolved path travels with the environment.
const String nativeSttFvmEnvironmentVariable = 'SANAD_DEV_FVM_BIN';

/// Lines of that tail echoed to the terminal when an attempt fails.
const int _nativeSttReportedLines = 3;

/// What one preparation attempt needs in order to run.
class NativeSttPreparationRequest {
  const NativeSttPreparationRequest({
    required this.agentDirectory,
    required this.logPath,
    required this.tag,
    this.fvmExecutable = 'fvm',
  });

  /// Directory the acquisition tool runs in (`agent/`).
  final String agentDirectory;

  /// Durable log the attempt appends to.
  final String logPath;

  /// `<os>-<cpu>` slice being prepared.
  final String tag;

  /// FVM entry point, resolved so a shim-started shell can still find it.
  final String fvmExecutable;
}

/// What one finished attempt produced.
///
/// [tail] is bounded output, parsed for the three keys the tool always prints:
/// `native_stt_stage`, `native_stt_result`, and `native_stt_failure`.
class NativeSttPreparationRun {
  const NativeSttPreparationRun({
    required this.exitCode,
    this.tail = const [],
    this.running = false,
  });

  final int exitCode;
  final List<String> tail;

  /// True when the attempt was started detached and still owns its own result.
  ///
  /// The launcher cannot know how a detached attempt ends without holding this
  /// process open, so it reports the start and the log instead of a verdict.
  /// `sanad-dev setup` awaits the same tool and does report the verdict.
  final bool running;

  String? get stage => _lastKeyedValue(tail, 'native_stt_stage');

  String? get result => _lastKeyedValue(tail, 'native_stt_result');

  String? get failure => _lastKeyedValue(tail, 'native_stt_failure');

  /// True when another attempt already held the preparing marker.
  bool get busy => result == 'busy';

  /// True only when the runtime was acquired and verified.
  bool get ready =>
      !busy && !running && (result == 'ready' || (result == null && exitCode == 0));

  /// The diagnostic lines worth showing: the tool's own last words.
  List<String> get diagnostic => [
    for (final line in tail.reversed)
      if (!line.contains('native_stt_') && line.isNotEmpty) line,
  ].take(_nativeSttReportedLines).toList().reversed.toList();
}

/// Runs one attempt and reports what it produced.
typedef NativeSttPreparationRunner =
    Future<NativeSttPreparationRun> Function(NativeSttPreparationRequest request);

/// Why a launcher did or did not prepare dictation.
enum NativeSttPreparationState {
  /// An architecture-matching shim is already installed.
  ready,

  /// An attempt was started; [NativeSttPreparation.completion] settles it.
  started,

  /// Another attempt holds the preparing marker, so none was started.
  inProgress,

  /// This host has no native dictation target at all.
  unsupported,
}

/// The launcher-visible answer of one preparation request.
class NativeSttPreparation {
  const NativeSttPreparation({
    required this.state,
    required this.logPath,
    this.tag,
    this.completion,
  });

  final NativeSttPreparationState state;

  /// Absolute path of the durable log (empty when the host has no target).
  final String logPath;

  final String? tag;

  /// Settles when a started attempt finishes, or null when none started.
  ///
  /// `run` deliberately does not await it: the daemon and the Client must start
  /// immediately and dictation becomes available when it lands. Tests await it
  /// to observe the terminal report deterministically.
  final Future<void>? completion;
}

/// Prepares the native dictation runtime for the running host.
///
/// `agent/native/<platform>-<architecture>/` is not tracked: the whisper shim and
/// its ggml libraries are per-platform build products. A fresh clone therefore
/// has none, and [nativeSttToolPath] verifies, downloads, or builds them. This
/// starts that tool once per checkout; a failure only leaves dictation
/// unavailable (the daemon reports `native_runtime_missing`), and `run` is never
/// blocked or delayed.
///
/// Four rules make the background path trustworthy:
///
///  * **Detached and unwatched.** The attempt runs in its own process with the
///    shell owning the log, so it outlives this launcher. Nothing here waits for
///    it: a child pipe or a poll timer would hold `sanad-dev run` open for the
///    length of a build. The launcher therefore reports the start and the log,
///    and `sanad-dev setup` is the entry point that reports the verdict.
///  * **One attempt.** A fresh preparing claim whose owner is still running
///    means an attempt is in progress — from this launcher, from
///    `sanad-dev setup`, or from the daemon's Client-triggered retry — so
///    nothing new starts. The tool takes the same decision atomically, and a
///    claim whose owner is gone is cleared instead of waited out.
///  * **Durable diagnostics.** Every attempt appends to
///    `agent/native/.stt-prepare.log`, bounded to [nativeSttLogLimitBytes] per
///    attempt, with the failed stage, the typed cause, and the managed retry
///    command. Nothing is discarded to the null device.
///  * **Dictation only.** Nothing here throws, returns a non-zero status, or
///    delays the daemon.
Future<NativeSttPreparation> prepareNativeDictation(
  String agentDirectory, {
  NativeSttPreparationRunner? runner,
  DateTime? now,
  String? fvmExecutable,
}) async {
  final tag = nativeRuntimeTag();
  final logPath = nativeSttLogPath(agentDirectory);
  if (tag == null) {
    return NativeSttPreparation(
      state: NativeSttPreparationState.unsupported,
      logPath: logPath,
    );
  }
  if (nativeRuntimeShimPath(agentDirectory, tag) != null) {
    return NativeSttPreparation(
      state: NativeSttPreparationState.ready,
      logPath: logPath,
      tag: tag,
    );
  }
  if (nativeSttAttemptInFlight(agentDirectory, now: now)) {
    stdout.writeln(
      'Native dictation preparation is already running; it reports to '
      '${nativeSttLogDisplayPath()} when it finishes.',
    );
    return NativeSttPreparation(
      state: NativeSttPreparationState.inProgress,
      logPath: logPath,
      tag: tag,
    );
  }
  // A marker whose owner is gone (a killed attempt) is not an attempt. It is
  // cleared here rather than waited out, because the tool takes the same
  // decision and a dead claim must never block a retry for the whole window.
  await nativeSttClearAbandonedAttempt(agentDirectory, now: now);

  await _resetBoundedLog(File(logPath));
  stdout.writeln(
    'Preparing the native dictation runtime in the background '
    '(dictation works as soon as it finishes; log: '
    '${nativeSttLogDisplayPath()}; `sanad-dev setup` waits for the result).',
  );
  final request = NativeSttPreparationRequest(
    agentDirectory: agentDirectory,
    logPath: logPath,
    tag: tag,
    fvmExecutable: nativeSttFvmExecutable(override: fvmExecutable),
  );
  final attempt = (runner ?? _startPreparationTool)(request);
  final completion = attempt
      .then<void>((outcome) => _reportPreparationOutcome(outcome, request))
      .catchError((Object error) {
        // A launcher must never fail because of this: the attempt is optional
        // and the run it belongs to is already starting components.
        stderr.writeln(
          'Native dictation preparation could not run '
          '(${error.runtimeType}).',
        );
      });
  return NativeSttPreparation(
    state: NativeSttPreparationState.started,
    logPath: logPath,
    tag: tag,
    completion: completion,
  );
}

/// True when a fresh preparing marker says an attempt is still running.
///
/// Mirrors `sttPreparationInFlight` in the Agent: fresh by age, and only when
/// the process it names is not provably gone. A marker without a readable pid
/// counts as running, because a claim nobody can disprove is never replaced.
bool nativeSttAttemptInFlight(String agentDirectory, {DateTime? now}) {
  final marker = File(
    '$agentDirectory/native/$nativeSttPreparingMarkerName',
  );
  if (!marker.existsSync()) return false;
  try {
    final age = (now ?? DateTime.now()).difference(marker.lastModifiedSync());
    if (age >= nativeSttAttemptMaxAge) return false;
    final owner = _nativeSttMarkerOwner(marker);
    if (owner != null && !_processAlive(owner)) return false;
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Removes a preparing marker whose attempt is expired or whose owner is gone.
///
/// The tool takes the same decision when it claims the marker, so this only
/// keeps the launcher's own message honest: a killed attempt must never be
/// reported as "already running" for the full window.
Future<void> nativeSttClearAbandonedAttempt(
  String agentDirectory, {
  DateTime? now,
}) async {
  final marker = File(
    '$agentDirectory/native/$nativeSttPreparingMarkerName',
  );
  if (!marker.existsSync()) return;
  if (nativeSttAttemptInFlight(agentDirectory, now: now)) return;
  try {
    await marker.delete();
  } on FileSystemException {
    // Leftover markers expire by age, so this stays best-effort.
  }
}

/// Process id recorded in [marker], or null when it names no process.
int? _nativeSttMarkerOwner(File marker) {
  try {
    final first = marker.readAsStringSync().trim().split(RegExp(r'\s+')).first;
    return int.tryParse(first);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// True when [pid] is still running; unknown answers count as alive.
bool _processAlive(int pid) {
  if (pid <= 0) return false;
  try {
    if (Platform.isWindows) {
      final result = Process.runSync(
        'tasklist',
        ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
        runInShell: true,
      );
      return '${result.stdout}'.contains('"$pid"');
    }
    final result = Process.runSync('/bin/sh', ['-c', 'kill -0 $pid']);
    return result.exitCode == 0;
  } on Object {
    return true;
  }
}

/// The FVM entry point to spawn.
///
/// An explicit argument wins, then the path a wrapper already resolved, then
/// the `fvm` on `PATH`. The detached attempt runs through a shell, which does
/// not inherit the wrapper's idea of where FVM lives, so the resolved path is
/// carried in [nativeSttFvmEnvironmentVariable] instead of being guessed.
String nativeSttFvmExecutable({String? override}) {
  final explicit = override?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final inherited =
      Platform.environment[nativeSttFvmEnvironmentVariable]?.trim();
  if (inherited != null && inherited.isNotEmpty) return inherited;
  return 'fvm';
}

/// Absolute path of the durable preparation log inside [agentDirectory].
String nativeSttLogPath(String agentDirectory) =>
    '$agentDirectory/native/$nativeSttLogFileName';

/// Workspace-relative spelling of [nativeSttLogPath], for human-facing output.
///
/// Launcher output never prints absolute local paths.
String nativeSttLogDisplayPath() => 'agent/native/$nativeSttLogFileName';

/// The installed shim for [tag] in [agentDirectory], or null when absent.
///
/// The Apple Silicon unqualified directory stays a bounded legacy alias for the
/// reason the loader keeps it: it was only ever populated by arm64 builds.
String? nativeRuntimeShimPath(String agentDirectory, String tag) {
  final name = _nativeShimFileName(tag);
  for (final directory in <String>[tag, if (tag == 'macos-arm64') 'macos']) {
    final path = '$agentDirectory/native/$directory/$name';
    if (File(path).existsSync()) return path;
  }
  return null;
}

String _nativeShimFileName(String tag) {
  if (tag.startsWith('macos')) return 'libsanad_whisper.dylib';
  if (tag.startsWith('windows')) return 'sanad_whisper.dll';
  return 'libsanad_whisper.so';
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

/// Runs the acquisition tool, keeping its output in the durable log.
///
/// Deliberately detached, and deliberately unwatched. `sanad-dev run` exits as
/// soon as the daemon is published, so an attached child (a pipe, or a poll
/// timer that holds the event loop) would either kill the build mid-flight or
/// hold the terminal behind it. The shell owns the log file instead, which is
/// what keeps the attempt alive and its output durable after this process is
/// gone. Reading the result back is the job of the process a developer asks
/// explicitly: `sanad-dev setup` awaits the same tool.
///
/// The command carries no quoting: `cmd /c` parses a quoted program path
/// inconsistently, and a resolved FVM path may contain spaces. The resolved
/// directory is prepended to `PATH` instead, so a bare `fvm` in the shell is the
/// one the caller already verified.
Future<NativeSttPreparationRun> _startPreparationTool(
  NativeSttPreparationRequest request,
) async {
  final log = File(request.logPath);
  await log.parent.create(recursive: true);
  await _resetBoundedLog(log);
  await _appendLog(log, '== ${_timestamp()} preparing ${request.tag}\n');
  final command =
      '$nativeSttFvmCommand dart run $nativeSttToolPath '
      '>> $_nativeSttLogRelativePath 2>&1';
  await Process.start(
    Platform.isWindows ? 'cmd' : '/bin/sh',
    Platform.isWindows ? ['/c', command] : ['-c', command],
    workingDirectory: request.agentDirectory,
    environment: _shellEnvironment(request.fvmExecutable),
    includeParentEnvironment: true,
    mode: ProcessStartMode.detached,
  );
  return const NativeSttPreparationRun(exitCode: 0, running: true);
}

/// Environment that makes a bare `fvm` resolve to [fvmExecutable].
///
/// A detached shell does not inherit the wrapper's idea of where FVM lives, so
/// the resolved directory goes first on `PATH` and the command stays quote-free.
Map<String, String> _shellEnvironment(String fvmExecutable) {
  final separator = Platform.pathSeparator;
  if (!fvmExecutable.contains(separator) &&
      !fvmExecutable.contains('/')) {
    return const {};
  }
  final directory = File(fvmExecutable).parent.path;
  final inherited =
      Platform.environment[Platform.isWindows ? 'Path' : 'PATH'] ?? '';
  final delimiter = Platform.isWindows ? ';' : ':';
  return <String, String>{
    Platform.isWindows ? 'Path' : 'PATH':
        inherited.isEmpty ? directory : '$directory$delimiter$inherited',
  };
}

/// Prints and records the terminal state of one attempt.
Future<void> _reportPreparationOutcome(
  NativeSttPreparationRun outcome,
  NativeSttPreparationRequest request,
) async {
  final stage = outcome.stage ?? 'inspect';
  final failure = outcome.failure;
  final String summary;
  if (outcome.running) {
    // Nothing to verdict: the attempt owns its own log now, and printing
    // "ready" here would be a lie the launcher cannot verify. The start message
    // already named the log and the awaited entry point.
    summary =
        'attempt started detached for ${request.tag}; '
        'result in ${nativeSttLogDisplayPath()}';
  } else if (outcome.busy) {
    summary =
        'another attempt was already running; '
        'log: ${nativeSttLogDisplayPath()}';
    stdout.writeln(
      'Native dictation preparation is already running elsewhere; it reports to '
      '${nativeSttLogDisplayPath()} when it finishes.',
    );
  } else if (outcome.ready) {
    summary = 'native dictation runtime is ready (${request.tag})';
    stdout.writeln('✓ Native dictation runtime is ready.');
  } else {
    final cause = failure == null ? '' : ' ($failure)';
    summary =
        'native dictation preparation failed at $stage$cause; '
        'exit ${outcome.exitCode}; retry: sanad-dev setup';
    stderr.writeln('Native dictation preparation failed at $stage$cause.');
    for (final line in outcome.diagnostic) {
      stderr.writeln('  $line');
    }
    stderr.writeln('  log:   ${nativeSttLogDisplayPath()}');
    // The managed retry, not a raw Dart command: `setup` awaits the same tool
    // with the same log, so a user never has to reconstruct its arguments.
    stderr.writeln('  retry: sanad-dev setup');
  }
  await _appendLog(
    File(request.logPath),
    '== ${_timestamp()} sanad-dev: $summary\n',
  );
}

Future<void> _appendLog(File log, String line) async {
  try {
    await log.writeAsString(line, mode: FileMode.append, flush: true);
  } on FileSystemException {
    // Diagnostic only.
  }
}

/// Keeps the durable log bounded across attempts.
Future<void> _resetBoundedLog(File log) async {
  try {
    await log.parent.create(recursive: true);
    if (await log.exists() && await log.length() > nativeSttLogLimitBytes) {
      await log.writeAsString(
        '$nativeSttLogResetHeader$nativeSttLogLimitBytes bytes\n',
        flush: true,
      );
    }
  } on FileSystemException {
    // A log that cannot be bounded must not stop the attempt.
  }
}

String _timestamp() => DateTime.now().toUtc().toIso8601String();

/// Last `key=value` line for [key] in [lines].
String? _lastKeyedValue(List<String> lines, String key) {
  for (var index = lines.length - 1; index >= 0; index--) {
    final line = lines[index].trim();
    if (!line.startsWith('$key=')) continue;
    final value = line.substring(key.length + 1).trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}
