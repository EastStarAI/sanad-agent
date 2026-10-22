import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:test/test.dart';

import '../../tool/fake_local_gateway.dart';

/// Deadline for one compiled-CLI gateway command. The defect this guards is a
/// process that produced no output and never exited; a bounded budget turns a
/// repeat into a failed expectation instead of a hung suite.
const Duration _aotCommandTimeout = Duration(seconds: 90);
const String _aotBinaryVariable = 'SANAD_AOT_CLI_BINARY';

void main() {
  group('Agent vault open policy', () {
    test('gateway-only commands never open the vault', () {
      for (final arguments in <List<String>>[
        ['session', 'list'],
        ['session', 'list', '--json'],
        ['session', 'show', 'session-1'],
        ['session', 'stop', 'session-1'],
        ['workspace', 'list'],
        ['ws', 'list'],
        ['memory', 'list'],
        ['schedule', 'list'],
        ['skills', 'list'],
      ]) {
        expect(
          SanadCommandRunner.requiresSecretVault(arguments),
          isFalse,
          reason: '${arguments.join(' ')} reads no Agent secret',
        );
      }
    });

    test('pure queries never open the vault', () {
      expect(SanadCommandRunner.requiresSecretVault(const ['--version']), isFalse);
      expect(SanadCommandRunner.requiresSecretVault(const ['version']), isFalse);
      expect(SanadCommandRunner.requiresSecretVault(const ['--help']), isFalse);
      expect(
        SanadCommandRunner.requiresSecretVault(const ['session', '--help']),
        isFalse,
      );
    });

    test('secret-bearing and unrecognized commands keep the vault', () {
      for (final arguments in <List<String>>[
        ['models', 'list'],
        ['providers'],
        ['setup'],
        ['login'],
        ['logout'],
        ['mcp', 'list'],
        ['doctor'],
        ['run', '--standalone', 'hello'],
        ['chat'],
        const <String>[],
        // An unparseable command line falls back to opening the vault instead
        // of silently running a secret-bearing command without credentials.
        ['session', 'list', '--not-an-option'],
      ]) {
        expect(
          SanadCommandRunner.requiresSecretVault(arguments),
          isTrue,
          reason: '${arguments.join(' ')} may read or write an Agent secret',
        );
      }
    });
  });

  group('Compiled CLI gateway commands', () {
    final binaryPath = Platform.environment[_aotBinaryVariable];
    final hasBinary = binaryPath != null && binaryPath.trim().isNotEmpty;

    test(
      'session list reaches a fake gateway without opening the Agent vault',
      () async {
        final gateway = await FakeLocalGateway.start();
        final home = await Directory.systemTemp.createTemp('sanad-aot-home-');
        final stateHome = await Directory.systemTemp.createTemp(
          'sanad-aot-state-',
        );
        const token = 'aot-regression-token';
        await File(
          '${home.path}/.local_token',
        ).writeAsString(token, flush: true);
        final environment = <String, String>{
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'SANAD_STATE_HOME': stateHome.path,
        }
          ..remove('SANAD_E2E_TEST_MODE')
          ..remove('SANAD_GATEWAY_URL')
          ..remove('LOCAL_GATEWAY_URL')
          ..remove('LOCAL_GATEWAY_PORT');
        try {
          final result = await _runBounded(binaryPath!, [
            'session',
            'list',
            '--home',
            home.path,
            '--gateway-url',
            gateway.gatewayUrl.toString(),
            '--json',
          ], environment: environment);

          expect(result.exitCode, 0, reason: 'stderr=${result.stderr}');
          final listed = jsonDecode(result.stdout.trim());
          expect(listed, isA<List<dynamic>>());
          expect(
            (listed as List<dynamic>).any(
              (entry) => entry is Map && entry['session_id'] == fakeSessionId,
            ),
            isTrue,
            reason: 'stdout=${result.stdout}',
          );
          expect(gateway.commands, contains('get_sessions'));
          expect(gateway.healthTokens, contains(token));

          // The vault writes its lock and generation markers the first time any
          // process opens it, so their absence proves the gateway command never
          // touched the OS credential vault.
          final vaultArtifacts = home
              .listSync()
              .map((entry) => entry.path.split(Platform.pathSeparator).last)
              .where((name) => name.startsWith('secret_vault'))
              .toList();
          expect(vaultArtifacts, isEmpty);
        } finally {
          await gateway.close();
          await home.delete(recursive: true);
          await stateHome.delete(recursive: true);
        }
      },
      skip: hasBinary
          ? false
          : 'Set $_aotBinaryVariable to a `dart compile exe` build of '
                'bin/sanad_agent.dart to run the compiled-CLI guard.',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

typedef _BoundedResult = ({int exitCode, String stdout, String stderr});

/// Runs one compiled-CLI command with a hard deadline and kills it on expiry.
Future<_BoundedResult> _runBounded(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  await process.stdin.close();
  try {
    final exitCode = await process.exitCode.timeout(_aotCommandTimeout);
    return (
      exitCode: exitCode,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    final stdout = await stdoutFuture.timeout(
      const Duration(seconds: 5),
      onTimeout: () => '',
    );
    final stderr = await stderrFuture.timeout(
      const Duration(seconds: 5),
      onTimeout: () => '',
    );
    fail(
      'Compiled CLI did not finish within $_aotCommandTimeout '
      '(${arguments.join(' ')}): stdout=$stdout stderr=$stderr',
    );
  }
}
