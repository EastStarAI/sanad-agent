import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/oneshot/oneshot_runner.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:test/test.dart';

import '../../tool/fake_local_gateway.dart';

/// Deadline for one compiled-CLI gateway command. The defect this guards is a
/// process that produced no output and never exited; a bounded budget turns a
/// repeat into a failed expectation instead of a hung suite.
const Duration _aotCommandTimeout = Duration(seconds: 90);
const String _aotBinaryVariable = 'SANAD_AOT_CLI_BINARY';

/// Every `secret_vault*` artifact in [home].
///
/// The vault writes its lock, generation and event files the first time a
/// process opens it, so their absence is positive proof that no process opened
/// it for this Home.
List<String> _vaultArtifacts(Directory home) => home
    .listSync()
    .map((entry) => entry.path.split(Platform.pathSeparator).last)
    .where((name) => name.startsWith('secret_vault'))
    .toList();

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
      expect(
        SanadCommandRunner.requiresSecretVault(const ['--version']),
        isFalse,
      );
      expect(
        SanadCommandRunner.requiresSecretVault(const ['version']),
        isFalse,
      );
      expect(SanadCommandRunner.requiresSecretVault(const ['--help']), isFalse);
      expect(
        SanadCommandRunner.requiresSecretVault(const ['session', '--help']),
        isFalse,
      );
    });

    test('a secret-bearing subcommand keeps the vault in its own family', () {
      for (final arguments in <List<String>>[
        // `schedule` only exempts `list`; a bare family command and every other
        // subcommand open the vault.
        ['schedule'],
        ['schedule', 'add', '0 9 * * *', 'ping'],
        ['skills'],
        ['skills', 'add', '/tmp/skill'],
        ['skills', 'update'],
        ['skills', 'remove', 'skill-1'],
      ]) {
        expect(
          SanadCommandRunner.requiresSecretVault(arguments),
          isTrue,
          reason: '${arguments.join(' ')} is not a secret-free subcommand',
        );
      }
    });

    test('a run command defers the vault to the runtime it selects', () {
      // `run` picks its runtime first: a gateway run reads no Agent secret, and
      // the in-process runtime opens the vault itself. Opening it here would
      // make every gateway run read owner indexes it discards, and wait on an
      // OS authorization dialog whenever its caller happens to hold a terminal.
      for (final arguments in <List<String>>[
        ['run', 'hello'],
        ['run', '--standalone', 'hello'],
        ['run', '--prompt', 'hello'],
        ['run', '--json', '--execution-root', '/tmp/root', 'hello'],
        ['run', '--events', 'hello'],
      ]) {
        expect(
          SanadCommandRunner.requiresSecretVault(arguments),
          isFalse,
          reason: '${arguments.join(' ')} selects its own runtime',
        );
      }
    });

    test('the explicit grant opens the vault itself', () {
      // `sanad vault authorize` is the only command that may start an OS
      // authorization dialog, so it owns the open: asking for its help, or
      // running it where it cannot prompt, must not query the vault first.
      for (final arguments in <List<String>>[
        ['vault'],
        ['vault', 'authorize'],
        ['vault', 'authorize', '--home', '/tmp/sanad-home'],
      ]) {
        expect(
          SanadCommandRunner.requiresSecretVault(arguments),
          isFalse,
          reason: '${arguments.join(' ')} opens the vault itself',
        );
        expect(
          SanadCommandRunner.entryOpensSecretVault(arguments),
          isFalse,
          reason: arguments.join(' '),
        );
      }
    });

    test('a daemon dispatch never opens the vault at the entry point', () {
      for (final arguments in <List<String>>[
        ['daemon'],
        ['start'],
        ['daemon', '--child-process'],
        ['--child-process', 'daemon'],
      ]) {
        expect(
          SanadCommandRunner.entryOpensSecretVault(arguments),
          isFalse,
          reason:
              '${arguments.join(' ')} hands the Home to the daemon, which opens '
              'its own vault without waiting and without prompting',
        );
      }
      // Every other secret-bearing command still opens it before dispatch.
      for (final arguments in <List<String>>[
        ['providers'],
        ['models', 'list'],
        ['setup'],
        ['doctor'],
      ]) {
        expect(
          SanadCommandRunner.entryOpensSecretVault(arguments),
          isTrue,
          reason: arguments.join(' '),
        );
      }
    });

    test('a daemon dispatch is never classified from the daemon stdio', () {
      for (final arguments in <List<String>>[
        ['daemon'],
        ['start'],
        ['daemon', '--child-process'],
        // A supervisor that puts the private marker first must still be
        // recognized before the vault opens.
        ['--child-process', 'daemon'],
        ['--home', '/tmp/sanad-home', 'daemon', '--child-process'],
      ]) {
        expect(
          SanadCommandRunner.dispatchesToDaemon(arguments),
          isTrue,
          reason: arguments.join(' '),
        );
      }
      for (final arguments in <List<String>>[
        ['session', 'list'],
        ['models', 'list'],
        const <String>[],
      ]) {
        expect(
          SanadCommandRunner.dispatchesToDaemon(arguments),
          isFalse,
          reason: arguments.join(' '),
        );
      }
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

  group('Explicit grant', () {
    late Directory root;
    late Directory home;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sanad-vault-authorize-');
      home = Directory('${root.path}/home')..createSync(recursive: true);
      selectSanadHome(home.path);
      setSanadStateHomeOverride(home.path);
      await SanadHomeBootstrap.identity().prepare();
    });

    tearDown(() async {
      await SecretVaults.closeAll();
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      SecretVaultPolicy.reset();
      SecretVaultNotice.reset();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<({int exitCode, String out, String err})> authorize() async {
      final out = StringBuffer();
      final err = StringBuffer();
      final exitCode = await SanadCommandRunner(
        stdoutSink: out,
        stderrSink: err,
      ).run(const ['vault', 'authorize']);
      return (exitCode: exitCode, out: out.toString(), err: err.toString());
    }

    test('a process that may not prompt refuses before opening anything', () async {
      // The daemon's own policy: a daemon must never ask, so the one command
      // that can ask refuses instead of querying the store without a dialog.
      SecretVaultPolicy.apply(
        SecretVaultPolicy.daemonEntryDecision,
        vaultSkipped: true,
      );

      final result = await authorize();

      expect(result.exitCode, 1);
      expect(result.err, contains('needs a terminal'));
      expect(result.err, contains('daemon_background'));
      expect(result.out, isEmpty, reason: 'nothing was opened or announced');
      expect(
        _vaultArtifacts(home),
        isEmpty,
        reason: 'a refused grant must not touch the vault at all',
      );
    });

    test('an interactive grant opens the vault and prints no value', () async {
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.allowed,
          SecretVaultInteractionEvidence.interactiveTerminal,
        ),
        vaultSkipped: true,
      );

      final result = await authorize();

      expect(result.exitCode, 0, reason: 'stderr=${result.err}');
      expect(result.out, contains('Agent vault is available'));
      expect(
        _vaultArtifacts(home),
        isNotEmpty,
        reason: 'the command opened the vault it was asked to open',
      );
      expect(
        '${result.out}${result.err}',
        isNot(contains('sk-')),
        reason: 'the grant never prints a value',
      );
    });

    test('a refused grant keeps the vault closed and says why', () async {
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.allowed,
          SecretVaultInteractionEvidence.interactiveTerminal,
        ),
        vaultSkipped: true,
      );
      // The store refuses exactly as macOS answers an item whose access control
      // does not accept this binary.
      final vaults = SecretVaults.beginOpen(store: _RefusingStore());
      await vaults.ready;

      final result = await authorize();

      expect(result.exitCode, 1);
      expect(
        result.err,
        contains(AgentSecretStoreUnavailableReason.interactionForbidden),
      );
      expect(result.err, contains('sanad vault authorize'));
      expect(vaults.available, isFalse, reason: 'failure keeps it closed');
    });
  });

  group('Gateway run', () {
    late Directory root;
    late Directory home;
    late Directory stateHome;
    late FakeLocalGateway gateway;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sanad-gateway-run-');
      home = Directory('${root.path}/home')..createSync(recursive: true);
      stateHome = Directory('${root.path}/state')..createSync(recursive: true);
      selectSanadHome(home.path);
      setSanadStateHomeOverride(stateHome.path);
      // The CLI refuses a token any other user can read.
      final tokenFile = File('${home.path}/.local_token');
      await tokenFile.writeAsString('gateway-run-token', flush: true);
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['600', tokenFile.path]);
        expect(chmod.exitCode, 0, reason: 'chmod 600 ${tokenFile.path}');
      }
      gateway = await FakeLocalGateway.start(
        homeId: sanadHomeIdentity(home.path),
      );
    });

    tearDown(() async {
      await gateway.close();
      await SecretVaults.closeAll();
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      SecretVaultPolicy.reset();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'a run that attaches to the daemon completes without opening the vault',
      () async {
        final out = StringBuffer();
        final err = StringBuffer();
        final runner = OneshotRunner(
          // The in-process runtime is the only path that opens the vault. A
          // gateway run must never reach it.
          standaloneClientFactory: ({String? sanadHomeOverride}) async => fail(
            'a gateway run must not start the in-process runtime.',
          ),
        );

        final exitCode = await runner.run(
          prompt: 'gateway run regression guard',
          executionRoot: root.path,
          sanadHome: home.path,
          gatewayUrl: gateway.gatewayUrl.toString(),
          json: true,
          timeout: const Duration(seconds: 30),
          stdoutSink: out,
          stderrSink: err,
          signalStream: const Stream<ProcessSignal>.empty(),
          readStdin: false,
        );

        expect(exitCode, 0, reason: 'stdout=$out stderr=$err');
        expect(gateway.commands, contains('think'));
        final result = jsonDecode(out.toString().trim());
        expect(result, isA<Map<String, dynamic>>());
        expect((result as Map<String, dynamic>)['exit_code'], 0);
        expect(
          _vaultArtifacts(home),
          isEmpty,
          reason:
              'a gateway run read the Agent vault; it reads no secret at all, '
              'so it must never expose its caller to an OS credential prompt.',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('Compiled CLI gateway commands', () {
    final binaryPath = Platform.environment[_aotBinaryVariable];
    final hasBinary = binaryPath != null && binaryPath.trim().isNotEmpty;

    test(
      'session list reaches a fake gateway without opening the Agent vault',
      () async {
        final home = await Directory.systemTemp.createTemp('sanad-aot-home-');
        final stateHome = await Directory.systemTemp.createTemp(
          'sanad-aot-state-',
        );
        final gateway = await FakeLocalGateway.start(
          homeId: sanadHomeIdentity(home.path),
        );
        const token = 'aot-regression-token';
        final tokenFile = File('${home.path}/.local_token');
        await tokenFile.writeAsString(token, flush: true);
        if (!Platform.isWindows) {
          // The CLI refuses a token any other user can read.
          final chmod = await Process.run('chmod', ['600', tokenFile.path]);
          expect(chmod.exitCode, 0, reason: 'chmod 600 ${tokenFile.path}');
        }
        final environment =
            <String, String>{
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
          expect(_vaultArtifacts(home), isEmpty);
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

/// A store that refuses every query the way macOS answers an item whose access
/// control does not accept the running binary, without touching any real
/// operating-system vault.
final class _RefusingStore implements AgentSecretStore {
  static const _error = AgentSecretStoreUnavailable(
    'The Agent vault item demands an interactive authorization and this process '
    'has no human to answer it.',
    reasonCode: AgentSecretStoreUnavailableReason.interactionForbidden,
  );

  @override
  Future<String?> read(String key) async => throw _error;

  @override
  Future<void> write(String key, String value) async => throw _error;

  @override
  Future<void> delete(String key) async => throw _error;
}
