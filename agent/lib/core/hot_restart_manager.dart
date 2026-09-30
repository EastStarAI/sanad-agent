import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

const _localGatewayCredentialHeader = 'x-sanad-local-token';

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

/// A built-in, cross-platform self-forking development manager that supervises
/// child process exits and supports manual hot restarts.
class HotRestartManager {
  static const int _maxFailuresPerWindow = 5;
  static const Duration _failureWindow = Duration(seconds: 15);

  /// Start the hot restart supervisor wrapping the specified arguments.
  static Future<void> run(List<String> originalArgs) async {
    print('=== 🚀 Sanad Agent Hot Restart Manager Active ===');
    print('Manual triggers only. File watching is disabled.\n');
    print(
      'Type "r" and press enter (or just "r" if terminal permits) to trigger a manual Hot Restart.\n',
    );

    Process? childProcess;
    var manualRestartInProgress = false;
    final failureWindow = RestartFailureWindow(
      maxFailures: _maxFailuresPerWindow,
      window: _failureWindow,
    );

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

      // Listen for exit code to restart automatically if the process exits on its own (e.g. /restart POST)
      spawned.exitCode.then((exitCode) async {
        if (childProcess == spawned) {
          if (exitCode == 123) {
            print(
              '\n[HotRestartManager] Child requested permanent shutdown. Exiting...',
            );
            exit(0);
          }
          if (exitCode != 0) {
            final shouldRestart = failureWindow.recordFailure();
            if (!shouldRestart) {
              print(
                '\n=== ⛔ Child process failed more than $_maxFailuresPerWindow times within ${_failureWindow.inSeconds} seconds. Stopping supervisor. ===',
              );
              exit(exitCode);
            }
          }
          print(
            '\n=== ⚠️ Child process exited with code $exitCode. Supervisor auto-restarting... ===',
          );
          childProcess = null;
          await Future.delayed(const Duration(milliseconds: 500));
          await startChild();
        }
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
        stdin.listen((List<int> bytes) async {
          for (final byte in bytes) {
            final char = String.fromCharCode(byte).toLowerCase();
            if (char == 'r') {
              await requestManualRestart();
            }
          }
        });
      } catch (e) {
        print(
          '[HotRestartManager] Warning: Stdin listener could not be initialized: $e',
        );
      }
    }

    Future<void> shutdown() async {
      print('\n[HotRestartManager] Shutting down cleanly...');
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
      childProcess?.kill();
      if (childProcess != null) {
        await childProcess!.exitCode;
      }
      exit(0);
    }

    // Clean shutdown of child on terminal or supervisor termination.
    ProcessSignal.sigint.watch().listen((_) => shutdown());
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) => shutdown());
    }
  }
}
