// Bounded PR-check monitor for Sanad workflow guards.
//
// Polls `gh pr checks <ref> --json` every [PrChecksOptions.interval] seconds,
// fails fast on the first failed check, and gives up after
// [PrChecksOptions.timeout] with a timeout verdict. Output is bounded (one
// summary line per poll unless quiet) and the process exit status always
// reflects the outcome (see bin/pr_checks_watch.dart).
//
// Windows safety: `gh` is spawned directly (no shell), and a `.cmd`/`.bat`
// override is executed through ComSpec with explicit per-argument quoting —
// never through fragile `for /f` parsing or shell-concatenated one-liners.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Outcome of a bounded CI check watch.
enum PrChecksVerdict { success, failure, timeout, error }

/// A single check-run entry as reported by `gh pr checks --json`.
class PrCheckState {
  PrCheckState({
    required this.name,
    required this.bucket,
    required this.state,
    required this.conclusion,
  });

  factory PrCheckState.fromJson(Map<String, dynamic> json) {
    return PrCheckState(
      name:
          json['name']?.toString() ??
          json['workflowName']?.toString() ??
          '<unnamed>',
      bucket: json['bucket']?.toString(),
      state: json['state']?.toString(),
      conclusion: json['conclusion']?.toString(),
    );
  }

  final String name;
  final String? bucket;
  final String? state;
  final String? conclusion;

  static const _failedValues = {
    'FAILURE',
    'ERROR',
    'CANCELLED',
    'STARTUP_FAILURE',
    'TIMED_OUT',
    'ACTION_REQUIRED',
  };
  static const _pendingValues = {
    'PENDING',
    'IN_PROGRESS',
    'QUEUED',
    'REQUESTED',
    'WAITING',
  };
  static const _skippedValues = {'SKIPPED', 'NEUTRAL', 'EXPECTED'};

  /// gh's `--json` bucket classifies state into pass/fail/pending/skipping/cancel.
  bool get isFailed =>
      bucket == 'fail' ||
      bucket == 'cancel' ||
      _failedValues.contains(state) ||
      (conclusion != null && _failedValues.contains(conclusion));

  bool get isSkipped =>
      bucket == 'skipping' ||
      _skippedValues.contains(state) ||
      (conclusion != null && _skippedValues.contains(conclusion));

  bool get isPending =>
      !isFailed &&
      !isSkipped &&
      (bucket == 'pending' ||
          _pendingValues.contains(state) ||
          (state == null && bucket != 'pass'));
}

/// Parses `gh pr checks <ref> --json` output into check states.
///
/// Throws [FormatException] when the output is not the expected JSON array.
List<PrCheckState> parseCheckRuns(String jsonOutput) {
  final decoded = jsonDecode(jsonOutput);
  if (decoded is! List) {
    throw FormatException('expected a JSON array of check runs');
  }
  return decoded
      .whereType<Map<dynamic, dynamic>>()
      .map(
        (entry) => PrCheckState.fromJson(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .toList();
}

/// Failure verdict on the first failed/cancelled check; otherwise success.
/// Pending is decided separately via [hasPendingChecks] so the caller can keep
/// polling without conflating "no checks yet" with success.
PrChecksVerdict classifyChecks(List<PrCheckState> checks) {
  for (final check in checks) {
    if (check.isFailed) return PrChecksVerdict.failure;
  }
  return PrChecksVerdict.success;
}

/// True when at least one check is still pending and therefore the watch loop
/// must keep polling.
bool hasPendingChecks(List<PrCheckState> checks) =>
    checks.any((check) => check.isPending);

/// Options for [watchPrChecks].
class PrChecksOptions {
  const PrChecksOptions({
    this.interval = const Duration(seconds: 5),
    this.timeout = const Duration(minutes: 7),
    this.ghCommand = 'gh',
    this.quiet = false,
  });

  /// Poll interval (default 5 seconds).
  final Duration interval;

  /// Maximum watch duration (default 7 minutes).
  final Duration timeout;

  /// Executable used to query checks (defaults to `gh` on PATH).
  final String ghCommand;

  /// Suppress per-poll summary lines; only the final verdict is printed.
  final bool quiet;
}

/// Result of a bounded watch.
class PrChecksResult {
  PrChecksResult({
    required this.verdict,
    required this.pollCount,
    required this.lastChecks,
    this.error,
  });

  final PrChecksVerdict verdict;
  final int pollCount;
  final List<PrCheckState> lastChecks;
  final String? error;

  /// Stable machine-readable exit code for the verdict
  /// (0 success, 1 first failure, 124 timeout, 2 tool error).
  int get exitCode => switch (verdict) {
    PrChecksVerdict.success => 0,
    PrChecksVerdict.failure => 1,
    PrChecksVerdict.timeout => 124,
    PrChecksVerdict.error => 2,
  };
}

/// The outcome of a single `gh` invocation.
class _GhRun {
  _GhRun({required this.exitCode, required this.stdout, required this.stderr});

  final int exitCode;
  final String stdout;
  final String stderr;
}

final _shellMeta = RegExp(r'[|;&<>$`^%!]');

/// Quotes one argument for a `cmd.exe` command line (doubling embedded quotes).
String windowsBatchQuote(String value) => '"${value.replaceAll('"', '""')}"';

/// Spawns [executable] with [args] without a shell, except that a Windows
/// `.cmd`/`.bat` override is routed through the shell with every argument
/// pre-validated against command metacharacters (fail closed, never executed
/// unvalidated).
Future<_GhRun> _runProcess(String executable, List<String> args) async {
  if (executable.isEmpty || _shellMeta.hasMatch(executable)) {
    throw FormatException(
      'refusing to execute $executable (empty or shell metacharacters)',
    );
  }
  final lower = executable.toLowerCase();
  final isCmdWrapper =
      Platform.isWindows && (lower.endsWith('.cmd') || lower.endsWith('.bat'));
  Process process;
  if (isCmdWrapper) {
    for (final arg in args) {
      if (_shellMeta.hasMatch(arg) || arg.contains('"')) {
        throw FormatException(
          'refusing shell-executed argument "$arg" (metacharacters or quotes)',
        );
      }
    }
    process = await Process.start(executable, args, runInShell: true);
  } else {
    process = await Process.start(executable, args);
  }
  // Await stream completion too: the process can exit before the piped stdout
  // has been delivered to the listeners, so waiting on exitCode alone races.
  final stdoutAll = process.stdout.transform(utf8.decoder).join();
  final stderrAll = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;
  return _GhRun(
    exitCode: exitCode,
    stdout: await stdoutAll,
    stderr: await stderrAll,
  );
}

/// Polls CI checks with a fixed interval, fail-fast on first failure, and a
/// maximum [PrChecksOptions.timeout]. Time is injected ([now], [sleeper]) so
/// tests stay deterministic without real sleeping.
Future<PrChecksResult> watchPrChecks(
  String ref, {
  PrChecksOptions options = const PrChecksOptions(),
  DateTime Function()? now,
  Future<void> Function(Duration delay)? sleeper,
}) async {
  final clock = now ?? DateTime.now;
  final sleep = sleeper ?? Future.delayed;
  final deadline = clock().add(options.timeout);
  var pollCount = 0;
  List<PrCheckState> lastChecks = const [];

  while (true) {
    _GhRun run;
    try {
      run = await _runProcess(options.ghCommand, [
        'pr',
        'checks',
        ref,
        '--json',
        'name,bucket,state,workflow',
      ]);
    } on ProcessException catch (error) {
      return PrChecksResult(
        verdict: PrChecksVerdict.error,
        pollCount: pollCount,
        lastChecks: lastChecks,
        error:
            'gh could not be started (${error.message}); install GitHub CLI or pass --gh',
      );
    } on FormatException catch (error) {
      return PrChecksResult(
        verdict: PrChecksVerdict.error,
        pollCount: pollCount,
        lastChecks: lastChecks,
        error: error.message,
      );
    }
    pollCount += 1;

    // gh reports "checks pending" as exit code 8. With `--json` it normally
    // still emits the array; when it exits 8 with no output, treat that as
    // pending and keep polling instead of misreading it as success/error.
    final pendingOnly = run.exitCode == 8 && run.stdout.trim().isEmpty;

    List<PrCheckState> checks;
    try {
      checks = parseCheckRuns(run.stdout);
    } on FormatException {
      if (pendingOnly) {
        checks = const [];
      } else {
        return PrChecksResult(
          verdict: PrChecksVerdict.error,
          pollCount: pollCount,
          lastChecks: lastChecks,
          error:
              'unparseable gh output (exit ${run.exitCode}); expected a JSON array',
        );
      }
    }
    lastChecks = checks;

    if (!pendingOnly) {
      // Fail-fast: any failed/cancelled check stops the watch even when other
      // checks are still pending. Empty output never proves required checks
      // passed, and unexplained gh failures remain tool errors.
      final verdict = classifyChecks(checks);
      if (verdict == PrChecksVerdict.failure) {
        return PrChecksResult(
          verdict: PrChecksVerdict.failure,
          pollCount: pollCount,
          lastChecks: checks,
        );
      }
      if (checks.isEmpty) {
        return PrChecksResult(
          verdict: PrChecksVerdict.error,
          pollCount: pollCount,
          lastChecks: checks,
          error: 'gh reported no checks; required checks cannot be proven',
        );
      }
      if (run.exitCode != 0 && run.exitCode != 8) {
        return PrChecksResult(
          verdict: PrChecksVerdict.error,
          pollCount: pollCount,
          lastChecks: checks,
          error:
              'gh pr checks failed with exit ${run.exitCode}: ${run.stderr.trim()}',
        );
      }
      if (verdict == PrChecksVerdict.success && !hasPendingChecks(checks)) {
        return PrChecksResult(
          verdict: PrChecksVerdict.success,
          pollCount: pollCount,
          lastChecks: checks,
        );
      }
    }
    if (!options.quiet) {
      _printPollSummary(checks);
    }
    if (!clock().isBefore(deadline)) {
      return PrChecksResult(
        verdict: PrChecksVerdict.timeout,
        pollCount: pollCount,
        lastChecks: checks,
        error: 'checks still pending after ${options.timeout.inSeconds}s',
      );
    }
    await sleep(options.interval);
  }
}

void _printPollSummary(List<PrCheckState> checks) {
  final passed = checks.where((c) => !c.isFailed && !c.isPending).length;
  final failed = checks.where((c) => c.isFailed).length;
  final pending = checks.where((c) => c.isPending).length;
  stdout.writeln(
    '[${DateTime.now().toIso8601String()}] checks: $passed passed, $pending pending, $failed failed',
  );
}
