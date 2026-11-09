import 'dart:io';

import 'package:sanad_agent/core/hot_restart_manager.dart';
import 'package:sanad_agent/core/termination_cleanup.dart';
import 'package:test/test.dart';

void main() {
  group('RestartFailureWindow', () {
    test(
      'allows up to the configured number of failures within the window',
      () {
        final timestamps = <DateTime>[
          DateTime(2026, 1, 1, 0, 0, 0),
          DateTime(2026, 1, 1, 0, 0, 1),
          DateTime(2026, 1, 1, 0, 0, 2),
          DateTime(2026, 1, 1, 0, 0, 3),
          DateTime(2026, 1, 1, 0, 0, 4),
        ];
        var index = 0;
        final window = RestartFailureWindow(
          maxFailures: 5,
          window: const Duration(seconds: 15),
          now: () => timestamps[index++],
        );

        for (var i = 0; i < 5; i++) {
          expect(window.recordFailure(), isTrue);
        }
        expect(window.recentFailures, 5);
      },
    );

    test('stops allowing restarts after exceeding the limit in the window', () {
      final timestamps = <DateTime>[
        DateTime(2026, 1, 1, 0, 0, 0),
        DateTime(2026, 1, 1, 0, 0, 1),
        DateTime(2026, 1, 1, 0, 0, 2),
        DateTime(2026, 1, 1, 0, 0, 3),
        DateTime(2026, 1, 1, 0, 0, 4),
        DateTime(2026, 1, 1, 0, 0, 5),
      ];
      var index = 0;
      final window = RestartFailureWindow(
        maxFailures: 5,
        window: const Duration(seconds: 15),
        now: () => timestamps[index++],
      );

      for (var i = 0; i < 5; i++) {
        expect(window.recordFailure(), isTrue);
      }

      expect(window.recordFailure(), isFalse);
      expect(window.recentFailures, 6);
    });

    test('drops old failures once they move outside the time window', () {
      final timestamps = <DateTime>[
        DateTime(2026, 1, 1, 0, 0, 0),
        DateTime(2026, 1, 1, 0, 0, 16),
      ];
      var index = 0;
      final window = RestartFailureWindow(
        maxFailures: 1,
        window: const Duration(seconds: 15),
        now: () => timestamps[index++],
      );

      expect(window.recordFailure(), isTrue);
      expect(window.recordFailure(), isTrue);
      expect(window.recentFailures, 1);
    });
  });

  group('crash-loop breaker', () {
    test(
      'a child that fails every ~5.3 s trips the breaker at five failures',
      () {
        // The old policy allowed five failures inside a 15-second window. A
        // child that dies in 5.3 s can never place five failures in that
        // window — the incident ran 28 failures in 150 s — so the breaker was
        // unreachable. The count must decide, not the spacing.
        var now = DateTime.utc(2026, 11, 9, 17, 30, 5);
        final guard = SupervisorCrashLoopGuard(clock: () => now);
        final oldPolicy = RestartFailureWindow(
          maxFailures: 5,
          window: const Duration(seconds: 15),
          now: () => now,
        );
        const spacing = Duration(milliseconds: 5300);

        for (var failure = 1; failure <= 4; failure++) {
          now = now.add(spacing);
          final decision = guard.recordExit(exitCode: 1, lifetime: spacing);
          expect(decision.respawn, isTrue, reason: 'failure $failure');
          expect(decision.consecutiveFailures, failure);
          // Proof that the previous policy would have kept restarting forever.
          expect(oldPolicy.recordFailure(), isTrue);
        }

        now = now.add(spacing);
        final tripped = guard.recordExit(exitCode: 1, lifetime: spacing);
        expect(tripped.respawn, isFalse);
        expect(tripped.consecutiveFailures, 5);
        // The flapping density stays below the limit in the same run, which is
        // exactly why the two policies disagree here.
        expect(guard.recentFailures.recentFailures, lessThan(5));
      },
    );

    test('a clean restart or a long-lived child clears the count', () {
      final guard = SupervisorCrashLoopGuard();

      for (var failure = 1; failure <= 4; failure++) {
        expect(
          guard
              .recordExit(exitCode: 1, lifetime: const Duration(seconds: 2))
              .respawn,
          isTrue,
        );
      }
      expect(guard.consecutiveFailures, 4);

      // A `/restart` exits 0 and is not a failure at all.
      final controlled = guard.recordExit(
        exitCode: 0,
        lifetime: const Duration(seconds: 1),
      );
      expect(controlled.respawn, isTrue);
      expect(guard.consecutiveFailures, 0);

      // A child that ran long enough to count as a real run starts over: the
      // crash that ends it is the first failure of a new run, not the fifth.
      for (var failure = 1; failure <= 4; failure++) {
        guard.recordExit(exitCode: 1, lifetime: const Duration(seconds: 2));
      }
      final longLived = guard.recordExit(
        exitCode: 1,
        lifetime: supervisorLongLivedChildThreshold,
      );
      expect(longLived.respawn, isTrue);
      expect(longLived.consecutiveFailures, 1);
    });

    test('the respawn delay grows to a cap and stays there', () {
      final guard = SupervisorCrashLoopGuard();
      final delays = <Duration>[];
      for (var failure = 1; failure <= 6; failure++) {
        final decision = guard.recordExit(
          exitCode: 1,
          lifetime: const Duration(seconds: 1),
        );
        delays.add(decision.delay);
      }
      expect(delays, [
        const Duration(milliseconds: 500),
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 10),
      ]);
    });

    test('four failures are tolerated and the fifth ends the supervisor', () {
      final guard = SupervisorCrashLoopGuard();
      for (
        var failure = 1;
        failure < supervisorMaxConsecutiveFailures;
        failure++
      ) {
        expect(
          guard
              .recordExit(exitCode: 1, lifetime: const Duration(seconds: 1))
              .respawn,
          isTrue,
        );
      }
      expect(
        guard
            .recordExit(exitCode: 1, lifetime: const Duration(seconds: 1))
            .respawn,
        isFalse,
      );
    });
  });

  group('supervised child exit', () {
    test('a signal keeps its signal status instead of a clean exit', () {
      // The supervisor is the process `launchd` and `sanad-dev` watch, so it
      // must not report a stray SIGTERM as a successful exit: the macOS plist
      // keeps KeepAlive{SuccessfulExit=false} and would stop relaunching.
      expect(signalExitCode(ProcessSignal.sigterm), 143);
      expect(signalExitCode(ProcessSignal.sigint), 130);
    });

    test('a shutdown in progress never restarts the child', () {
      // Both sides receive the same Ctrl+C. The child cleans up and exits 143,
      // so the supervisor must not treat that as a crash to respawn while it is
      // already leaving: that would orphan a daemon behind a dead supervisor.
      for (final exitCode in [0, 1, 143, supervisedPermanentShutdownExitCode]) {
        expect(
          decideSupervisedChildExit(exitCode: exitCode, shuttingDown: true),
          SupervisedChildExit.ignore,
        );
      }
    });

    test('a controlled refresh restarts and a permanent stop does not', () {
      // A controlled restart exits 0 and must still be restarted; the daemon's
      // permanent-stop request (123) must end the supervisor.
      expect(
        decideSupervisedChildExit(exitCode: 0, shuttingDown: false),
        SupervisedChildExit.restart,
      );
      expect(
        decideSupervisedChildExit(
          exitCode: supervisedPermanentShutdownExitCode,
          shuttingDown: false,
        ),
        SupervisedChildExit.stop,
      );
      // A crash, or a signal aimed only at the child, keeps the old behaviour:
      // the supervisor brings the daemon back.
      expect(
        decideSupervisedChildExit(exitCode: 143, shuttingDown: false),
        SupervisedChildExit.restart,
      );
      expect(
        decideSupervisedChildExit(exitCode: 1, shuttingDown: false),
        SupervisedChildExit.restart,
      );
    });
  });

  group('launcher-bound supervision', () {
    test('a managed launcher pipe ends the supervisor', () {
      expect(
        endsOnLauncherPipeClose(managedLauncher: true, hasTerminal: false),
        isTrue,
      );
    });

    test('an interactive or unmanaged run is never ended by stdin', () {
      // A human terminal, or a manual `fvm dart run … daemon`, must keep
      // today's behaviour: closing stdin is not an instruction to exit.
      expect(
        endsOnLauncherPipeClose(managedLauncher: true, hasTerminal: true),
        isFalse,
      );
      expect(
        endsOnLauncherPipeClose(managedLauncher: false, hasTerminal: false),
        isFalse,
      );
      expect(
        endsOnLauncherPipeClose(managedLauncher: false, hasTerminal: true),
        isFalse,
      );
    });
  });

  group('restart supervisor selection', () {
    test('supervises daemon commands for source and compiled runtimes', () {
      expect(
        shouldUseHotRestartSupervisor(arguments: const ['daemon']),
        isTrue,
      );
      expect(shouldUseHotRestartSupervisor(arguments: const ['start']), isTrue);
      expect(
        shouldUseHotRestartSupervisor(arguments: const ['setup']),
        isFalse,
      );
    });

    test('supervisor parent defers Home preparation to its child', () {
      expect(
        shouldDeferSanadHomeBootstrapToChild(arguments: const ['daemon']),
        isTrue,
      );
      expect(
        shouldDeferSanadHomeBootstrapToChild(
          arguments: const ['daemon', '--child-process'],
        ),
        isFalse,
      );
      expect(
        shouldDeferSanadHomeBootstrapToChild(arguments: const ['setup']),
        isFalse,
      );
    });

    test('builds source and compiled child commands', () {
      final source = supervisedChildCommand(
        const ['daemon'],
        resolvedExecutable: Platform.isWindows
            ? r'C:\sdk\dart.exe'
            : '/sdk/dart',
        scriptPath: Platform.isWindows
            ? r'C:\repo\bin\sanad_agent.dart'
            : '/repo/bin/sanad_agent.dart',
      );
      expect(source.arguments.first, 'run');
      expect(source.arguments, contains('--child-process'));

      final compiled = supervisedChildCommand(
        const ['daemon'],
        resolvedExecutable: Platform.isWindows
            ? r'C:\bin\sanad.exe'
            : '/bin/sanad',
      );
      expect(compiled.arguments, ['daemon', '--child-process']);
    });
  });

  test(
    'manual restart request uses the daemon controlled restart endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = <HttpRequest>[];
      final handled = server.listen((request) async {
        received.add(request);
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(handled.cancel);

      final accepted = await requestControlledDaemonRestart(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        credential: 'restart-secret',
      );

      expect(accepted, isTrue);
      expect(received, hasLength(1));
      expect(received.single.method, 'POST');
      expect(received.single.uri.path, '/restart');
      expect(received.single.uri.queryParameters['force'], 'false');
      expect(received.single.uri.queryParameters['timeout_seconds'], '60');
      expect(
        received.single.headers.value('x-sanad-local-token'),
        'restart-secret',
      );
    },
  );

  test(
    'ordinary restart request waits beyond one checkpoint timeout window',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final handled = server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(handled.cancel);

      final accepted = await requestControlledDaemonRestart(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        credential: 'restart-secret',
        timeout: const Duration(milliseconds: 20),
      );

      expect(accepted, isTrue);
    },
  );
}
