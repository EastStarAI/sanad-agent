import 'dart:async';
import 'dart:io';

/// The exit status that preserves a terminating signal for whoever waits on the
/// process.
///
/// A process that dies *from* a signal is reported by a shell as
/// `128 + <signal number>` (143 for SIGTERM, 130 for SIGINT), and a supervisor
/// classifies the same shape as a signal exit. A process that catches the
/// signal and exits `0` instead looks like a requested clean stop: the macOS
/// service plist keeps `KeepAlive { SuccessfulExit = false }`, so a stray
/// SIGTERM would silently leave the Agent down.
///
/// Every signal-driven exit therefore reports this mapping, which keeps
/// "stopped by a signal" distinguishable from "finished its work" for shells,
/// `launchd`, `sanad-dev`, and any wrapper.
int signalExitCode(ProcessSignal signal) => 128 + signal.signalNumber;

/// Runs one bounded cleanup step and then ends the process when the runtime is
/// asked to terminate.
///
/// The daemon needs this for its Home's local-gateway runtime record: without a
/// termination hook, `sanad-dev stop` (SIGTERM) or Ctrl+C ended the process
/// abruptly, so `.local_gateway_endpoint.json` kept naming a pid that was gone
/// and the next Home-selected call reported a stale record for a Home that had
/// in fact stopped cleanly.
///
/// The contract is deliberately small: the cleanup runs at most once, it
/// finishes before the process exits, a failed cleanup still ends the process
/// instead of leaving a runtime alive with no signal handler, and the exit
/// status keeps the signal semantics of [signalExitCode].
class TerminationCleanup {
  TerminationCleanup({
    required Future<void> Function() cleanup,
    void Function(int exitCode) exitProcess = exit,
  }) : _cleanup = cleanup,
       _exitProcess = exitProcess;

  final Future<void> Function() _cleanup;
  final void Function(int exitCode) _exitProcess;
  final List<StreamSubscription<ProcessSignal>> _watchers = [];
  bool _stopping = false;

  /// Whether a termination signal has already been accepted.
  bool get isStopping => _stopping;

  /// Watches the process's termination signals, or the injected [signals] in
  /// tests.
  ///
  /// Windows has no SIGTERM, so only SIGINT is watched there.
  void install({Stream<ProcessSignal>? signals}) {
    _watchers.add(
      (signals ?? ProcessSignal.sigint.watch()).listen(_handleSignal),
    );
    if (!Platform.isWindows) {
      _watchers.add(
        (signals ?? ProcessSignal.sigterm.watch()).listen(_handleSignal),
      );
    }
  }

  /// Stops watching. An installed hook normally lives for the process lifetime;
  /// tests call this so a signal stream is not held open between cases.
  Future<void> dispose() async {
    for (final watcher in _watchers) {
      await watcher.cancel();
    }
    _watchers.clear();
  }

  Future<void> _handleSignal(ProcessSignal signal) async {
    if (_stopping) return;
    _stopping = true;
    try {
      await _cleanup();
    } catch (_) {
      // The caller's cleanup owns reporting, and the process must still end:
      // staying alive here would leave a runtime that ignores SIGTERM.
    } finally {
      // The first signal owns the exit status; a later one only repeats a stop
      // that is already underway.
      _exitProcess(signalExitCode(signal));
    }
  }
}
