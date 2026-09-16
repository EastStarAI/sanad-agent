import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();
  test(
    'standalone entry point executes the deterministic engine and releases Home ownership',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sanad-standalone-process-',
      );
      final home = Directory('${root.path}/home');
      final stateHome = Directory('${root.path}/state');
      final environment = <String, String>{
        ...Platform.environment,
        'SANAD_HOME': home.path,
        'SANAD_STATE_HOME': stateHome.path,
        'SANAD_E2E_TEST_MODE': 'true',
      };

      Future<ProcessResult> runStandalone(String outputFlag) {
        return Process.run(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/sanad_agent.dart',
            'run',
            '--standalone',
            '--home',
            home.path,
            outputFlag,
            'standalone process smoke',
          ],
          workingDirectory: Directory.current.path,
          environment: environment,
        ).timeout(const Duration(seconds: 30));
      }

      try {
        final first = await runStandalone('--json');
        expect(first.exitCode, 0, reason: first.stderr.toString());
        final jsonResult = jsonDecode(first.stdout.toString());
        expect(jsonResult['text'], 'e2e-success');
        expect(jsonResult['exit_code'], 0);

        final second = await runStandalone('--quiet');
        expect(second.exitCode, 0, reason: second.stderr.toString());
        expect(second.stdout.toString().trim(), 'e2e-success');
      } finally {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'standalone entry point surfaces runtime recovery notices as terminal JSON errors',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sanad-standalone-runtime-failure-',
      );
      final home = Directory('${root.path}/home');
      final stateHome = Directory('${root.path}/state');
      try {
        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/sanad_agent.dart',
            'run',
            '--standalone',
            '--home',
            home.path,
            '--json',
            '--timeout',
            '20',
            '__SANAD_E2E_RUNTIME_FAILURE__',
          ],
          workingDirectory: Directory.current.path,
          environment: {
            ...Platform.environment,
            'SANAD_HOME': home.path,
            'SANAD_STATE_HOME': stateHome.path,
            'SANAD_E2E_TEST_MODE': 'true',
          },
        ).timeout(const Duration(seconds: 15));

        expect(result.exitCode, 1, reason: result.stderr.toString());
        final outputLines = const LineSplitter()
            .convert(result.stdout.toString())
            .where((line) => line.trim().isNotEmpty)
            .toList();
        expect(outputLines, hasLength(1));
        final jsonResult = jsonDecode(outputLines.single);
        expect(jsonResult['exit_code'], 1);
        expect(
          jsonResult['error'],
          contains('deterministic E2E provider failure'),
        );
      } finally {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'standalone entry point maps timeout and signals to stable exit codes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sanad-standalone-cancellation-',
      );
      final home = Directory('${root.path}/home');
      final stateHome = Directory('${root.path}/state');
      final readyFile = File('${root.path}/tool-ready');
      final environment = <String, String>{
        ...Platform.environment,
        'SANAD_HOME': home.path,
        'SANAD_STATE_HOME': stateHome.path,
        'SANAD_E2E_TEST_MODE': 'true',
      };
      final prompt = '__SANAD_E2E_DELAY__${readyFile.path}';
      final baseArguments = <String>[
        'run',
        'bin/sanad_agent.dart',
        'run',
        '--standalone',
        '--home',
        home.path,
        '--quiet',
      ];

      try {
        final timeoutResult = await Process.run(
          Platform.resolvedExecutable,
          [...baseArguments, '--timeout', '1', prompt],
          workingDirectory: Directory.current.path,
          environment: environment,
        ).timeout(const Duration(seconds: 30));
        expect(
          timeoutResult.exitCode,
          124,
          reason: timeoutResult.stderr.toString(),
        );

        for (final signalCase in <(ProcessSignal, int, String)>[
          (ProcessSignal.sigint, 130, 'sigint-ready'),
          (ProcessSignal.sigterm, 143, 'sigterm-ready'),
        ]) {
          final signalReadyFile = File('${root.path}/${signalCase.$3}');
          final signalPrompt = '__SANAD_E2E_DELAY__${signalReadyFile.path}';
          final interrupted = await Process.start(
            Platform.resolvedExecutable,
            [...baseArguments, signalPrompt],
            workingDirectory: Directory.current.path,
            environment: environment,
          );
          try {
            final deadline = DateTime.now().add(const Duration(seconds: 20));
            while (!signalReadyFile.existsSync() &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(signalReadyFile.existsSync(), isTrue);
            expect(interrupted.kill(signalCase.$1), isTrue);
            expect(
              await interrupted.exitCode.timeout(const Duration(seconds: 10)),
              signalCase.$2,
            );
          } finally {
            interrupted.kill(ProcessSignal.sigkill);
          }
        }
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
