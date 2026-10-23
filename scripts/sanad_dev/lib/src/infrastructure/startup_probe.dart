import 'dart:async';
import 'dart:convert';

import 'component_journal.dart';

const sanadDevAgentStartupTimeout = Duration(minutes: 3);
const sanadDevClientStartupTimeout = Duration(minutes: 5);
const sanadDevComponentControlTimeout = Duration(minutes: 6);
const sanadDevStartupPollInterval = Duration(milliseconds: 250);

bool matchesSanadDevAgentHealth(
  Object? decoded, {
  required String launcherId,
  required String runtimeNonce,
}) {
  return decoded is Map &&
      decoded['status'] == 'ok' &&
      decoded['dev_launcher_id'] == launcherId &&
      decoded['dev_runtime_nonce'] == runtimeNonce;
}

Future<bool> waitForSanadDevStartupProbe({
  required Future<bool> Function() probe,
  Duration timeout = sanadDevAgentStartupTimeout,
  Duration pollInterval = sanadDevStartupPollInterval,
  DateTime Function()? clock,
  Future<void> Function(Duration)? delay,
  bool Function()? shouldAbort,
}) async {
  final now = clock ?? DateTime.now;
  final pause = delay ?? Future<void>.delayed;
  final deadline = now().add(timeout);

  while (true) {
    if (await probe()) return true;
    // A component that has already failed terminally can never satisfy the
    // probe, so waiting out the full timeout only delays the diagnosis.
    if (shouldAbort?.call() ?? false) return false;
    if (!now().isBefore(deadline)) return false;
    await pause(pollInterval);
  }
}

/// Supervisor line printed for every automatic restart of the Agent child.
final _sanadDevSupervisorRestartPattern = RegExp(
  r'Child process exited with code (-?\d+)\.\s*Supervisor auto-restarting',
);

/// Lines that describe the supervisor itself rather than the child's failure.
final _sanadDevSupervisorChatterPattern = RegExp(
  r'Hot Restart Manager|Manual triggers only|Type "r"|Spawning Process|'
  r'Restart requested|Supervisor auto-restarting|Stopping supervisor|'
  r'HotRestartManager',
);

/// Stack frames, which never explain a failure.
final RegExp _sanadDevStackFramePattern = RegExp(
  r'^(#\d+\s|package:|dart:|org\.|at\s)',
);

/// Continuation lines of one exception message.
///
/// Dart prints the useful line first and then indents the detail, so a
/// `SqliteException(26) … file is not a database` is followed by an indented
/// `Causing statement: PRAGMA journal_mode = WAL`. Keeping the last line would
/// report the SQL statement as the cause and hide the actual exception.
final RegExp _sanadDevErrorContinuationPattern = RegExp(
  r'^(causing statement|while executing|sql|parameters|stack trace)\s*:',
  caseSensitive: false,
);

/// Number of supervisor auto-restarts that prove a crash loop.
///
/// One restart is a transient child failure the supervisor can absorb; two in a
/// row mean the child cannot start, so the readiness wait must stop instead of
/// waiting out the three-minute startup window.
const sanadDevAgentCrashLoopRestartThreshold = 2;

/// Longest recorded error line; a longer line is truncated with an ellipsis.
const sanadDevAgentErrorLineMaxLength = 300;

/// Longest buffered partial line; a longer one is truncated rather than grown.
const sanadDevAgentPendingLineMaxLength = 4096;

/// Recognises an Agent that cannot become healthy, so a startup wait fails in
/// seconds instead of the full [sanadDevAgentStartupTimeout].
///
/// Two independent signals are watched, because the Agent runs under the
/// in-process `HotRestartManager` supervisor: the child process keeps exiting
/// with a non-zero code while the supervisor stays alive, or the spawned Agent
/// process itself exits. Either one makes the health probe unsatisfiable, and
/// the detector keeps the last output line that describes the failure so the
/// caller can report it. Dart prints an exception's first line before its stack
/// trace, so that line identifies the cause (for example a corrupt `state.db`)
/// without dumping a full log that can carry conversation or provider traffic.
class SanadDevAgentCrashLoopDetector {
  SanadDevAgentCrashLoopDetector({
    this.restartThreshold = sanadDevAgentCrashLoopRestartThreshold,
  });

  final int restartThreshold;
  int _restarts = 0;
  String _pending = '';
  String? _errorLine;
  String? _failureReason;

  /// True once the Agent can no longer satisfy the health probe.
  bool get isFatal => _failureReason != null;

  /// Bounded, secret-free explanation of the failure.
  String? get failureReason => _failureReason;

  /// The Agent's last output line that explains the failure.
  String? get errorLine => _errorLine;

  /// Records the spawned Agent process exit code.
  void recordAgentExit(int code) {
    if (code == 0) return;
    _fail('the Agent process exited with code $code');
  }

  /// Records a chunk of Agent output, keeping a partial trailing line buffered
  /// until its newline arrives so a split write never becomes the reported line.
  void recordOutputBytes(List<int> bytes) {
    if (isFatal) return;
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final buffered = '$_pending$decoded';
    final lines = buffered.split('\n');
    _pending = buffered.endsWith('\n') ? '' : lines.removeLast();
    if (_pending.length > sanadDevAgentPendingLineMaxLength) {
      _pending = _pending.substring(0, sanadDevAgentPendingLineMaxLength);
    }
    for (final line in lines) {
      recordOutputLine(line);
    }
  }

  /// Records one complete line of Agent output.
  void recordOutputLine(String line) {
    if (isFatal) return;
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final restart = _sanadDevSupervisorRestartPattern.firstMatch(trimmed);
    if (restart != null) {
      _restarts++;
      if (_restarts >= restartThreshold) {
        _fail(
          'the Agent child exited with code ${restart.group(1)} '
          '$_restarts times while the supervisor kept restarting it',
        );
      }
      return;
    }
    if (_sanadDevSupervisorChatterPattern.hasMatch(trimmed)) return;
    if (_sanadDevStackFramePattern.hasMatch(trimmed)) return;
    // The first line of an exception message names the cause; the indented lines
    // that follow describe where it happened. Keeping the last line would report
    // a `Causing statement:` instead of the exception itself.
    final isContinuation =
        (line.isNotEmpty && (line.startsWith(' ') || line.startsWith('\t'))) ||
        _sanadDevErrorContinuationPattern.hasMatch(trimmed);
    if (isContinuation && _errorLine != null) return;
    final redacted = redactComponentOutputText(trimmed);
    _errorLine = redacted.length <= sanadDevAgentErrorLineMaxLength
        ? redacted
        : '${redacted.substring(0, sanadDevAgentErrorLineMaxLength - 3)}...';
  }

  void _fail(String reason) {
    if (_failureReason != null) return;
    final error = _errorLine;
    _failureReason = error == null ? reason : '$reason; last error: $error';
  }
}
