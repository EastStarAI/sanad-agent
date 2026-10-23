import 'dart:convert';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/startup_probe.dart';

void main() {
  test('Agent startup allows a bounded cold-start window', () {
    expect(sanadDevAgentStartupTimeout, const Duration(minutes: 3));
    expect(
      sanadDevComponentControlTimeout,
      greaterThan(sanadDevAgentStartupTimeout),
    );
  });

  test('Client startup allows a five-minute cold-build window', () {
    expect(sanadDevClientStartupTimeout, const Duration(minutes: 5));
    expect(
      sanadDevClientStartupTimeout,
      greaterThan(const Duration(seconds: 90)),
    );
    expect(
      sanadDevComponentControlTimeout,
      greaterThan(sanadDevClientStartupTimeout),
    );
  });

  test(
    'Agent health matches the inherited launcher lease across Git roots',
    () {
      expect(
        matchesSanadDevAgentHealth(
          const {
            'status': 'ok',
            'workspace_hash': 'public-submodule-hash',
            'dev_launcher_id': 'launcher-1',
            'dev_runtime_nonce': 'nonce-1',
          },
          launcherId: 'launcher-1',
          runtimeNonce: 'nonce-1',
        ),
        isTrue,
      );
    },
  );

  test('Agent health rejects a stale or incomplete launcher lease', () {
    const health = {
      'status': 'ok',
      'dev_launcher_id': 'launcher-1',
      'dev_runtime_nonce': 'nonce-1',
    };

    expect(
      matchesSanadDevAgentHealth(
        health,
        launcherId: 'launcher-stale',
        runtimeNonce: 'nonce-1',
      ),
      isFalse,
    );
    expect(
      matchesSanadDevAgentHealth(
        health,
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-stale',
      ),
      isFalse,
    );
    expect(
      matchesSanadDevAgentHealth(
        const {'status': 'ok'},
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
      ),
      isFalse,
    );
  });

  test('startup timeout follows elapsed time instead of probe speed', () async {
    var now = DateTime.utc(2026);
    var attempts = 0;

    final ready = await waitForSanadDevStartupProbe(
      probe: () async {
        attempts++;
        return false;
      },
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 250),
      clock: () => now,
      delay: (duration) async => now = now.add(duration),
    );

    expect(ready, isFalse);
    expect(attempts, 5);
  });

  test('startup polling returns as soon as the probe is ready', () async {
    var attempts = 0;

    final ready = await waitForSanadDevStartupProbe(
      probe: () async => ++attempts == 3,
      pollInterval: Duration.zero,
    );

    expect(ready, isTrue);
    expect(attempts, 3);
  });

  group('Agent crash loop', () {
    const restartLine =
        '=== ⚠️ Child process exited with code 255. Supervisor auto-restarting... ===';

    test('a corrupt Home ends the readiness wait in seconds', () async {
      // The live-acceptance deviation: `state.db` was not a database, so the
      // supervised child died on every start. The readiness wait must stop as
      // soon as the supervisor reports the loop, not after three minutes.
      var now = DateTime.utc(2026);
      final started = now;
      final detector = SanadDevAgentCrashLoopDetector();
      detector.recordOutputBytes(
        utf8.encode(
          '=== 🚀 Sanad Agent Hot Restart Manager Active ===\n'
          '=== ⚙️ Spawning Process ===\n'
          'Unhandled exception:\n'
          'SqliteException(26): opening the database failed; file is not a '
          'database\n'
          '#0      Database.open (package:sqlite3/src/implementation.dart:1:1)\n',
        ),
      );
      var restarts = 0;

      final ready = await waitForSanadDevStartupProbe(
        probe: () async {
          // The supervisor restarts the dying child every five seconds.
          final due = now.difference(started).inMilliseconds ~/ 5000;
          while (restarts < due) {
            restarts++;
            detector.recordOutputBytes(
              utf8.encode('$restartLine\n$restartLine\n'),
            );
          }
          return false;
        },
        clock: () => now,
        delay: (duration) async => now = now.add(duration),
        shouldAbort: () => detector.isFatal,
      );

      expect(ready, isFalse);
      expect(
        now.difference(started),
        lessThan(const Duration(seconds: 20)),
        reason: 'the wait must not run out the three-minute startup window',
      );
      expect(detector.failureReason, contains('exited with code 255'));
      expect(detector.failureReason, contains('2 times'));
      expect(
        detector.errorLine,
        startsWith('SqliteException(26)'),
        reason:
            'the reported line is the exception identity, not a stack frame',
      );
      expect(detector.failureReason, contains('SqliteException(26)'));
    });

    test('one supervisor restart is not a crash loop', () {
      final detector = SanadDevAgentCrashLoopDetector();

      detector.recordOutputLine(restartLine);

      expect(detector.isFatal, isFalse);
      expect(detector.failureReason, isNull);
    });

    test('the spawned Agent process exit is terminal', () {
      final detector = SanadDevAgentCrashLoopDetector();

      detector.recordAgentExit(0);
      expect(detector.isFatal, isFalse);

      detector.recordAgentExit(1);

      expect(detector.isFatal, isTrue);
      expect(detector.failureReason, contains('exited with code 1'));
    });

    test('the reported line skips supervisor chatter and stack frames', () {
      final detector = SanadDevAgentCrashLoopDetector()
        ..recordOutputBytes(
          utf8.encode(
            'Manual triggers only. File watching is disabled.\n'
            'Type "r" and press enter to trigger a manual Hot Restart.\n'
            'Bad state: the Home is not writable\n'
            '#0      main (file:///agent/bin/sanad_agent.dart:1:1)\n'
            'package:sanad/daemon.dart 12:3\n',
          ),
        );

      expect(detector.errorLine, 'Bad state: the Home is not writable');
    });

    test('a split write never becomes the reported line', () {
      final detector = SanadDevAgentCrashLoopDetector();

      detector.recordOutputBytes(utf8.encode('SqliteException(26): file is '));
      detector.recordOutputBytes(utf8.encode('not a database\n#0 x\n'));
      detector.recordOutputLine(restartLine);
      detector.recordOutputLine(restartLine);

      expect(detector.errorLine, 'SqliteException(26): file is not a database');
    });

    test('the reported line is bounded and redacted', () {
      final detector = SanadDevAgentCrashLoopDetector()
        ..recordOutputLine(
          'Provider rejected the request (api_key=sk-live-1). ${'x' * 400}',
        );

      expect(detector.errorLine, isNot(contains('sk-live-1')));
      expect(
        detector.errorLine!.length,
        lessThanOrEqualTo(sanadDevAgentErrorLineMaxLength),
      );
      expect(detector.errorLine, endsWith('...'));
    });

    test('the reported line redacts a gateway token header by name', () {
      // This is the real header the Agent sends. It matched none of the four
      // fixed names the redactor knew, so the token reached the readiness
      // message and the persisted startup record verbatim.
      final detector = SanadDevAgentCrashLoopDetector()
        ..recordOutputLine(
          'local gateway rejected: {x-sanad-gateway-token: 9f3c2f1a77b0, '
          'x-session-id: 12}',
        );

      expect(detector.errorLine, isNot(contains('9f3c2f1a77b0')));
      expect(detector.errorLine, contains('x-sanad-gateway-token: [REDACTED]'));
      expect(
        detector.errorLine,
        isNot(contains('[REDACTED]12')),
        reason: 'a non-secret header keeps its value',
      );
    });

    test('the gateway token is redacted in name=value form too', () {
      final detector = SanadDevAgentCrashLoopDetector()
        ..recordOutputLine('gateway rejected x-session-token=abc123def');

      expect(detector.errorLine, isNot(contains('abc123def')));
      expect(detector.errorLine, contains('x-session-token=[REDACTED]'));
    });

    test('a bearer credential keeps its existing redaction', () {
      final detector = SanadDevAgentCrashLoopDetector()
        ..recordOutputLine('local gateway rejected: Authorization: Bearer abc.def');

      expect(detector.errorLine, isNot(contains('abc.def')));
      expect(detector.errorLine, contains('Bearer [REDACTED]'));
    });

    test('the exception line wins over a Causing statement line', () {
      // Live report: the coordinator saw `last error: Causing statement: PRAGMA
      // journal_mode = WAL`, which hides the exception that names the cause.
      final detector = SanadDevAgentCrashLoopDetector()
        ..recordOutputBytes(
          utf8.encode(
            'SqliteException(26): unable to open database file, file is not a '
            'database\n'
            '  Causing statement: PRAGMA journal_mode = WAL\n',
          ),
        );

      expect(
        detector.errorLine,
        startsWith('SqliteException(26)'),
        reason: 'the exception line explains the failure; the statement does not',
      );
      expect(detector.errorLine, isNot(contains('Causing statement')));
    });
  });
}
