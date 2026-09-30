// Bounded verification runner for Sanad workflow guards.
//
// Runs one command, measures elapsed wall time, captures the complete stdout
// and stderr into a unique temporary log (never tracked), preserves the exact
// child exit code, and returns only a bounded tail for the console. This is
// the tested contract behind "every test execution" in the Sanad workflows:
// fully observable results on disk, minimal context pollution, no regressions
// hidden by truncated successful logs.
//
// Windows safety: a `.cmd`/`.bat` target is routed through the shell only after
// every argument passes a command-metacharacter check; plain executables are
// spawned directly, and batch names are resolved through PATH + PATHEXT so
// commands like `fvm` keep working.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Outcome of one bounded run.
class VerifyResult {
  VerifyResult({
    required this.exitCode,
    required this.elapsedMs,
    required this.logPath,
    required this.stdoutTail,
    required this.stderrTail,
    this.error,
  });

  /// Exact child exit code (or tool error code when [error] is set).
  final int exitCode;

  /// Elapsed wall time of the child process in milliseconds.
  final int elapsedMs;

  /// Absolute path of the complete, untracked log.
  final String logPath;

  /// Last [VerifyOptions.tail] lines of child stdout.
  final List<String> stdoutTail;

  /// Last [VerifyOptions.tail] lines of child stderr.
  final List<String> stderrTail;

  /// Tool-level failure (spawn refusal, usage); child output is unaffected.
  final String? error;
}

/// Options for [runBounded].
class VerifyOptions {
  const VerifyOptions({
    this.tail = 5,
    this.logDir,
    this.tempRoot,
  });

  /// Console-visible tail length; the full output always goes to the log.
  final int tail;

  /// Directory for the unique log. Defaults to the system temporary
  /// directory, keeping logs untracked by construction.
  final String? logDir;

  /// Test-only override for the temporary root used when [logDir] is null.
  final String? tempRoot;
}

/// Runs [command] with [args], preserving exit code and bounding console
/// output. Time is measured by the caller-provided [swatch] (defaults to a
/// real [Stopwatch]) so tests stay deterministic on wall-time assertions.
Future<VerifyResult> runBounded(
  String command,
  List<String> args, {
  VerifyOptions options = const VerifyOptions(),
  Stopwatch? swatch,
}) async {
  final stopwatch = swatch ?? Stopwatch()..start();

  _GhLikeRun? run;
  try {
    final resolved = _resolveExecutable(command, options.tempRoot);
    run = await _spawnChild(resolved.resolved, args, resolved.usesShell);
  } on FormatException catch (error) {
    return VerifyResult(
      exitCode: 2,
      elapsedMs: stopwatch.elapsedMilliseconds,
      logPath: '',
      stdoutTail: const [],
      stderrTail: const [],
      error: error.message,
    );
  } on ProcessException catch (error) {
    return VerifyResult(
      exitCode: 2,
      elapsedMs: stopwatch.elapsedMilliseconds,
      logPath: '',
      stdoutTail: const [],
      stderrTail: const [],
      error: 'command could not be started (${error.message})',
    );
  }

  stopwatch.stop();
  final elapsedMs = stopwatch.elapsedMilliseconds;
  final logDir = options.logDir ?? options.tempRoot ?? Directory.systemTemp.path;
  final logPath = _writeLog(logDir, command, args, run);

  return VerifyResult(
    exitCode: run.exitCode,
    elapsedMs: elapsedMs,
    logPath: logPath,
    stdoutTail: _tail(run.stdoutLines, options.tail),
    stderrTail: _tail(run.stderrLines, options.tail),
  );
}

class _ResolvedExecutable {
  _ResolvedExecutable(this.resolved, this.usesShell);

  final String resolved;
  final bool usesShell;
}

final _shellMeta = RegExp(r'[|;&<>$`^%!]');

/// Resolves [command] and decides whether the shell is required.
///
/// Windows: batch names (`.cmd`/`.bat`) and PATH-resolved batch wrappers
/// (e.g. `fvm` -> `fvm.bat`) need the shell; everything else spawns directly.
/// POSIX: commands resolve through PATH by the platform itself, no shell.
_ResolvedExecutable _resolveExecutable(String command, String? tempRoot) {
  if (command.isEmpty || _shellMeta.hasMatch(command)) {
    throw FormatException('refusing to execute "$command" (empty or shell metacharacters)');
  }
  if (!Platform.isWindows) {
    return _ResolvedExecutable(command, false);
  }
  final hasSeparator = command.contains(RegExp(r'[/\\]'));
  String resolved = command;
  if (!hasSeparator) {
    final found = _findOnPath(command, tempRoot);
    if (found != null) resolved = found;
  }
  final lower = resolved.toLowerCase();
  final usesShell = lower.endsWith('.cmd') || lower.endsWith('.bat');
  return _ResolvedExecutable(resolved, usesShell);
}

/// Windows-only PATH + PATHEXT lookup (mirrors the supervisor bootstrap seam).
String? _findOnPath(String command, String? tempRoot) {
  final pathEnv = tempRoot != null
      ? tempRoot
      : (Platform.environment['PATH'] ?? '');
  final pathEntries = pathEnv.split(';').where((entry) => entry.isNotEmpty);
  final pathext = (Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
      .split(';')
      .where((ext) => ext.isNotEmpty);
  for (final dir in pathEntries) {
    final direct = '$dir\\$command';
    if (File(direct).existsSync()) return direct;
    for (final ext in pathext) {
      final candidate = '$dir\\$command$ext';
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

class _GhLikeRun {
  _GhLikeRun({required this.exitCode, required this.stdoutLines, required this.stderrLines});

  final int exitCode;
  final List<String> stdoutLines;
  final List<String> stderrLines;
}

Future<_GhLikeRun> _spawnChild(String executable, List<String> args, bool usesShell) async {
  if (usesShell) {
    for (final arg in args) {
      if (_shellMeta.hasMatch(arg) || arg.contains('"')) {
        throw FormatException(
          'refusing shell-executed argument "$arg" (metacharacters or quotes)',
        );
      }
    }
  }
  final process = usesShell
      ? await Process.start(executable, args, runInShell: true)
      : await Process.start(executable, args);
  // Await stream completion: a process can exit before piped output has been
  // delivered, so waiting on exitCode alone races.
  final stdoutFuture = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .toList();
  final stderrFuture = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .toList();
  final results = await Future.wait([
    process.exitCode,
    stdoutFuture,
    stderrFuture,
  ]);
  return _GhLikeRun(
    exitCode: results[0] as int,
    stdoutLines: results[1] as List<String>,
    stderrLines: results[2] as List<String>,
  );
}

String _writeLog(String logDir, String command, List<String> args, _GhLikeRun run) {
  Directory(logDir).createSync(recursive: true);
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .split('.')
      .first;
  final unique = 'verify-$stamp-${pid}-${Random().nextInt(0xFFFFFF).toRadixString(16)}.log';
  final file = File('$logDir${Platform.pathSeparator}$unique');
  final buffer = StringBuffer()
    ..writeln('# command: $command ${args.join(' ')}')
    ..writeln('# exit: ${run.exitCode}')
    ..writeln('# stdout (${run.stdoutLines.length} lines):')
    ..writeln(run.stdoutLines.join('\n'))
    ..writeln('# stderr (${run.stderrLines.length} lines):')
    ..writeln(run.stderrLines.join('\n'));
  file.writeAsStringSync(buffer.toString());
  return file.absolute.path;
}

List<String> _tail(List<String> lines, int tail) {
  if (lines.length <= tail) return lines;
  return lines.sublist(lines.length - tail);
}