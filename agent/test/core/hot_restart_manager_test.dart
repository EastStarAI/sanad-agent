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
