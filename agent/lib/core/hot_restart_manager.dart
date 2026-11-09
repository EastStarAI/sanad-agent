import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/supervisor_launcher_lease.dart';
import 'package:sanad_agent/core/supervisor_lifecycle_log.dart';
import 'package:sanad_agent/core/termination_cleanup.dart';

const _localGatewayCredentialHeader = 'x-sanad-local-token';

/// The exit status a supervised daemon uses to ask its supervisor for a
/// permanent stop instead of a restart.
const int supervisedPermanentShutdownExitCode = 123;

/// Consecutive child failures that end the supervisor.
///
/// Counting consecutive failures is the point: the previous policy measured
/// failures inside a 15-second window, but a child that dies in ~5.3 s can place
/// at most three failures in any such window, so the breaker could never trip
/// while the supervisor restarted forever. A count cannot be dodged by spacing.
const int supervisorMaxConsecutiveFailures = 5;

/// Delay before a respawn, indexed by the consecutive failure count and capped
/// at the last entry: 0.5 → 1 → 2 → 5 → 10 s.
///
/// The default policy ends the supervisor on the fifth consecutive failure, so it
/// respawns four times; the tenth-second entry is the ceiling for a configured
/// limit above the default.
const List<Duration> supervisorRespawnBackoff = <Duration>[
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
];

/// Child lifetime that proves a run was not a crash loop.
const Duration supervisorLongLivedChildThreshold = Duration(seconds: 60);

/// Whether a closed stdin pipe must end the supervisor.
///
/// A managed launcher hands its supervisor a pipe instead of a terminal, so
/// end-of-file on that pipe is the launcher's death. Without it the supervisor
/// outlives its owner: it keeps respawning children against a Home it cannot
/// own, and wins the Home lock on the next managed restart. An interactive or
/// unmanaged run must never be shut down this way, which is why the launcher
/// identity and the terminal state are both required.
bool endsOnLauncherPipeClose({
  required bool managedLauncher,
  required bool hasTerminal,
}) => managedLauncher && !hasTerminal;

/// What a supervisor does after the supervised daemon exits.
enum SupervisedChildExit {
  /// A shutdown is already in progress: the supervisor is about to end, so it
  /// must neither restart the child nor race its own exit.
  ignore,

  /// The child asked for a permanent stop.
  stop,

  /// Start the child again.
  restart,
}

SupervisedChildExit decideSupervisedChildExit({
  required int exitCode,
  required bool shuttingDown,
}) {
  if (shuttingDown) return SupervisedChildExit.ignore;
  if (exitCode == supervisedPermanentShutdownExitCode) {
    return SupervisedChildExit.stop;
  }
  return SupervisedChildExit.restart;
}

bool shouldUseHotRestartSupervisor({required List<String> arguments}) {
  final command = arguments.isEmpty ? '' : arguments.first.toLowerCase();
  return command == 'daemon' || command == 'start';
}

bool shouldDeferSanadHomeBootstrapToChild({required List<String> arguments}) {
  return !arguments.contains('--child-process') &&
      shouldUseHotRestartSupervisor(arguments: arguments);
}

({String executable, List<String> arguments}) supervisedChildCommand(
  List<String> originalArgs, {
  String? resolvedExecutable,
  String? scriptPath,
}) {
  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final executableName = p.basenameWithoutExtension(executable).toLowerCase();
  if (executableName == 'dart') {
    final sourceScript =
        scriptPath ??
        (Platform.script.isScheme('file')
            ? Platform.script.toFilePath()
            : p.join(Directory.current.path, 'bin', 'sanad_agent.dart'));
    return (
      executable: executable,
      arguments: ['run', sourceScript, ...originalArgs, '--child-process'],
    );
  }
  return (
    executable: executable,
    arguments: [...originalArgs, '--child-process'],
  );
}

Future<bool> requestControlledDaemonRestart({
  required Uri baseUri,
  required String credential,
  Duration timeout = const Duration(seconds: 60),
  bool force = false,
  HttpClient? httpClient,
}) async {
  final ownsClient = httpClient == null;
  final client = httpClient ?? HttpClient();
  try {
    final restartUri = baseUri
        .resolve('/restart')
        .replace(
          queryParameters: {
            'force': force.toString(),
            'timeout_seconds': timeout.inSeconds.toString(),
          },
        );
    final request = await client.postUrl(restartUri).timeout(timeout);
    request.headers.set(_localGatewayCredentialHeader, credential);
    final requesterSessionId =
        Platform.environment['SANAD_REQUESTER_SESSION_ID'];
    final requesterToolCallId =
        Platform.environment['SANAD_REQUESTER_TOOL_CALL_ID'];
    if (requesterSessionId?.isNotEmpty == true) {
      request.headers.set('x-sanad-requester-session-id', requesterSessionId!);
    }
    if (requesterToolCallId?.isNotEmpty == true) {
      request.headers.set(
        'x-sanad-requester-tool-call-id',
        requesterToolCallId!,
      );
    }
    final responseFuture = request.close();
    final response = force
        ? await responseFuture.timeout(timeout + const Duration(seconds: 5))
        : await responseFuture;
    await response.drain<void>().timeout(timeout);
    return response.statusCode >= 200 && response.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    if (ownsClient) client.close(force: true);
  }
}

class RestartFailureWindow {
  RestartFailureWindow({
    this.maxFailures = 5,
    this.window = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxFailures;
  final Duration window;
  final DateTime Function() _now;
  final List<DateTime> _failures = <DateTime>[];

  bool recordFailure() {
    final currentTime = _now();
    _failures.removeWhere(
      (failureTime) => currentTime.difference(failureTime) > window,
    );
    _failures.add(currentTime);
    return _failures.length <= maxFailures;
  }

  int get recentFailures => _failures.length;
}

/// Why a supervised child exit happened, and whether the supervisor continues.
class SupervisorRestartDecision {
  const SupervisorRestartDecision({
    required this.respawn,
    required this.consecutiveFailures,
    required this.delay,
  });

  final bool respawn;
  final int consecutiveFailures;
  final Duration delay;
}

/// Consecutive-failure accounting for the in-process Agent supervisor.
///
/// The breaker has to be reachable for the shape that actually happens: a child
/// that cannot acquire the Home dies in about five seconds, so the supervisor
/// must count the failures rather than measure their spacing. A child that exits
/// cleanly, or that ran long enough to be a real run, clears the count so a
/// healthy runtime never accumulates its way to an exit.
class SupervisorCrashLoopGuard {
  SupervisorCrashLoopGuard({
    this.maxConsecutiveFailures = supervisorMaxConsecutiveFailures,
    List<Duration> backoff = supervisorRespawnBackoff,
    this.longLivedThreshold = supervisorLongLivedChildThreshold,
    Duration flappingWindow = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : backoff = List<Duration>.unmodifiable(
         backoff.isEmpty ? const [Duration(milliseconds: 500)] : backoff,
       ),
       recentFailures = RestartFailureWindow(
         maxFailures: maxConsecutiveFailures,
         window: flappingWindow,
         now: clock,
       );

  final int maxConsecutiveFailures;
  final List<Duration> backoff;
  final Duration longLivedThreshold;

  /// Flapping density, reported beside the consecutive count.
  ///
  /// It stays diagnostic: the exit decision is the consecutive count, because a
  /// wall-clock window is exactly what made the old breaker unreachable.
  final RestartFailureWindow recentFailures;

  int _consecutiveFailures = 0;

  int get consecutiveFailures => _consecutiveFailures;

  /// Delay before the next respawn, capped at the last configured entry.
  Duration get respawnDelay {
    final index = (_consecutiveFailures - 1).clamp(0, backoff.length - 1);
    return backoff[index];
  }

  /// Records one child exit and answers whether the supervisor may respawn.
  SupervisorRestartDecision recordExit({
    required int exitCode,
    required Duration lifetime,
  }) {
    if (exitCode == 0 || lifetime >= longLivedThreshold) {
      // A controlled restart or a long-lived run is not a crash loop.
      _consecutiveFailures = 0;
      if (exitCode == 0) {
        return SupervisorRestartDecision(
          respawn: true,
          consecutiveFailures: 0,
          delay: backoff.first,
        );
      }
    }
    _consecutiveFailures++;
    recentFailures.recordFailure();
    return SupervisorRestartDecision(
      respawn: _consecutiveFailures < maxConsecutiveFailures,
      consecutiveFailures: _consecutiveFailures,
      delay: respawnDelay,
    );
  }
}

/// A built-in, cross-platform self-forking development manager that supervises
/// child process exits and supports manual hot restarts.
class HotRestartManager {
  /// Start the hot restart supervisor wrapping the specified arguments.
  static Future<void> run(List<String> originalArgs) async {
    print('=== 🚀 Sanad Agent Hot Restart Manager Active ===');
    print('Manual triggers only. File watching is disabled.\n');
    print(
      'Type "r" and press enter (or just "r" if terminal permits) to trigger a manual Hot Restart.\n',
    );

    // A managed launcher injects its identity; a deliberate manual
    // `fvm dart run … daemon` does not, and keeps the unmanaged behaviour.
    final managedLauncher =
        (Platform.environment['SANAD_DEV_LAUNCHER_ID']?.trim() ?? '')
            .isNotEmpty;
    final lifecycle = _openLifecycleLog();

    void recordLifecycle(
      SupervisorLifecycleEvent event, {
      int? attempt,
      String detail = '',
    }) {
      lifecycle?.record(event, pid: pid, attempt: attempt, detail: detail);
    }

    Process? childProcess;
    var manualRestartInProgress = false;
    var shuttingDown = false;
    DateTime? childStartedAt;
    var spawnedChildren = 0;
    final guard = SupervisorCrashLoopGuard();

    Future<void> startChild() async {
      if (childProcess != null) {
        final oldProcess = childProcess;
        childProcess =
            null; // Clear to prevent double-triggering in exit code listener
        print('\n=== 🔄 Restart requested! Restarting Process... ===');
        oldProcess!.kill();
        await oldProcess.exitCode;
        // Brief delay to allow sockets and file handles to clear
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        print('=== ⚙️ Spawning Process ===');
      }

      final child = supervisedChildCommand(originalArgs);

      Process spawned;
      try {
        spawned = await Process.start(
          child.executable,
          child.arguments,
          mode: ProcessStartMode.inheritStdio,
        );
      } catch (e) {
        final isSourceRuntime =
            p.basenameWithoutExtension(child.executable).toLowerCase() ==
            'dart';
        if (!isSourceRuntime) rethrow;
        spawned = await Process.start(
          'dart',
          child.arguments,
          mode: ProcessStartMode.inheritStdio,
        );
      }

      childProcess = spawned;
      childStartedAt = DateTime.now();
      spawnedChildren++;
      // `start` is the supervisor taking ownership once. A later spawn is a
      // respawn (logged with its attempt) or a requested restart, and repeating
      // `start` for each of them would invent transitions that never happened.
      if (spawnedChildren == 1) {
        recordLifecycle(
          SupervisorLifecycleEvent.start,
          detail: managedLauncher
              ? 'managed child pid ${spawned.pid}'
              : 'unmanaged',
        );
      }

      // Listen for exit code to restart automatically if the process exits on its own (e.g. /restart POST)
      spawned.exitCode.then((exitCode) async {
        if (childProcess != spawned) return;
        final startedAt = childStartedAt;
        final lifetime = startedAt == null
            ? Duration.zero
            : DateTime.now().difference(startedAt);
        // A shutdown in progress owns the exit: restarting here would orphan a
        // fresh daemon behind a supervisor that is already leaving.
        final decision = decideSupervisedChildExit(
          exitCode: exitCode,
          shuttingDown: shuttingDown,
        );
        if (decision == SupervisedChildExit.ignore) return;
        if (decision == SupervisedChildExit.stop) {
          print(
            '\n[HotRestartManager] Child requested permanent shutdown. Exiting...',
          );
          recordLifecycle(SupervisorLifecycleEvent.childStop);
          exit(0);
        }
        // A supervisor must never spawn a daemon for a launcher that is gone:
        // the leased Home belongs to whoever holds it, and a respawn racing a
        // new launcher is how a foreign supervisor ends up owning the runtime.
        final verdict = await verifySupervisorLauncher();
        if (verdict.isDenied) {
          print(
            '\n=== ⛔ Supervisor stopping instead of respawning: '
            '${verdict.reason} ===',
          );
          recordLifecycle(
            SupervisorLifecycleEvent.leaseMismatchExit,
            detail: verdict.reason,
          );
          exit(1);
        }
        final restart = guard.recordExit(
          exitCode: exitCode,
          lifetime: lifetime,
        );
        if (!restart.respawn) {
          final reason =
              'child exited with code $exitCode and failed '
              '${restart.consecutiveFailures} times in a row.';
          print('\n=== ⛔ $reason Stopping supervisor. ===');
          recordLifecycle(
            SupervisorLifecycleEvent.breakerExit,
            attempt: restart.consecutiveFailures,
            detail: reason,
          );
          exit(exitCode);
        }
        final delay = restart.delay;
        print(
          '\n=== ⚠️ Child process exited with code $exitCode. Supervisor auto-restarting... ===',
        );
        recordLifecycle(
          SupervisorLifecycleEvent.respawn,
          attempt: restart.consecutiveFailures,
          detail:
              'child exit code $exitCode after '
              '${lifetime.inMilliseconds}ms, waiting ${delay.inMilliseconds}ms',
        );
        childProcess = null;
        await Future.delayed(delay);
        await startChild();
      });
    }

    await startChild();

    Future<void> requestManualRestart() async {
      if (manualRestartInProgress || childProcess == null) return;
      manualRestartInProgress = true;
      final processAtRequest = childProcess;
      try {
        final config = Config();
        final configuredUri = Uri.parse(config.localGatewayUrl);
        final restartUri =
            configuredUri.host == '0.0.0.0' || configuredUri.host == '::'
            ? configuredUri.replace(host: '127.0.0.1')
            : configuredUri;
        final accepted = await requestControlledDaemonRestart(
          baseUri: restartUri,
          credential: String.fromCharCodes(
            SanadHomeBootstrap.identity().readSecretBytes('.local_token'),
          ).trim(),
        );
        if (!accepted || processAtRequest == null) {
          print(
            '\n[HotRestartManager] Safe restart was rejected or unavailable. '
            'The child process was left running.',
          );
          return;
        }
        try {
          await processAtRequest.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          print(
            '\n[HotRestartManager] The daemon accepted restart but did not '
            'exit. The child process was left running.',
          );
        }
      } finally {
        manualRestartInProgress = false;
      }
    }

    Future<void> shutdown([ProcessSignal? signal]) async {
      if (shuttingDown) return;
      shuttingDown = true;
      print('\n[HotRestartManager] Shutting down cleanly...');
      recordLifecycle(
        signal == null
            ? SupervisorLifecycleEvent.launcherExit
            : SupervisorLifecycleEvent.shutdown,
        detail: signal == null
            ? 'the launcher stdin pipe closed'
            : 'signal ${signal.toString()}',
      );
      // Restore the terminal before exit: raw mode was enabled for the 'r'
      // key listener, and without this the host terminal stays corrupted
      // (Backspace prints ^H) after Ctrl+C, especially on Windows.
      if (stdin.hasTerminal) {
        try {
          stdin.lineMode = true;
          stdin.echoMode = true;
        } catch (_) {
          // The host terminal may not expose mutable modes.
        }
      }
      // The daemon owns the Home's runtime record, not this supervisor: the
      // child receives this SIGTERM, runs one bounded cleanup, and exits. The
      // supervisor only waits for that to finish.
      final child = childProcess;
      childProcess = null;
      child?.kill();
      if (child != null) {
        await child.exitCode;
      }
      // A supervisor that exits 0 after a signal looks like a requested clean
      // stop: `launchd` keeps `KeepAlive { SuccessfulExit = false }`, so the
      // service would stay down after a stray SIGTERM. Report the signal the
      // way a signal death would (143 for SIGTERM, 130 for SIGINT). A closed
      // launcher pipe is not a signal: nothing supervises that exit status, and
      // the supervisor did exactly what its launcher's death asked.
      exit(signal == null ? 0 : signalExitCode(signal));
    }

    // Read from stdin to trigger restart manually
    final isDaemon =
        originalArgs.contains('daemon') || originalArgs.contains('start');
    if (isDaemon) {
      try {
        if (stdin.hasTerminal) {
          try {
            stdin.lineMode = false;
            stdin.echoMode = false;
          } catch (e) {
            // Keep going even if raw mode couldn't be set (e.g., on Windows Terminal/CMD)
          }
        }
        stdin.listen(
          (List<int> bytes) async {
            for (final byte in bytes) {
              final char = String.fromCharCode(byte).toLowerCase();
              if (char == 'r') {
                await requestManualRestart();
              }
            }
          },
          // A launcher-owned supervisor reads the launcher's pipe. Its end (EOF)
          // is the launcher's death: without this, the supervisor outlives its
          // owner, respawns children against a Home it cannot own, and steals
          // the lock on the next managed restart. Manual and interactive runs
          // have no launcher identity, so their behaviour is unchanged.
          onDone:
              endsOnLauncherPipeClose(
                managedLauncher: managedLauncher,
                hasTerminal: stdin.hasTerminal,
              )
              ? () => unawaited(shutdown())
              : null,
        );
      } catch (e) {
        print(
          '[HotRestartManager] Warning: Stdin listener could not be initialized: $e',
        );
      }
    }

    // Clean shutdown of child on terminal or supervisor termination.
    ProcessSignal.sigint.watch().listen((signal) => shutdown(signal));
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((signal) => shutdown(signal));
    }
  }

  /// Opens the bounded lifecycle log, or null when the Home is unknown.
  static SupervisorLifecycleLog? _openLifecycleLog() {
    try {
      return SupervisorLifecycleLog(home: getSanadHome());
    } on Object {
      // The supervisor must start even when no Home can be resolved.
      return null;
    }
  }
}
