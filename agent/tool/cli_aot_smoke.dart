import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/auth/secret_vault_policy.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';

import 'fake_local_gateway.dart';

const _cleanupAttempts = 20;
const _cleanupRetryDelay = Duration(milliseconds: 250);
const _aotExecutionTimeout = Duration(seconds: 60);
const _processTerminationTimeout = Duration(seconds: 5);
const cliAotSuccessFileEnvironment = 'SANAD_CLI_AOT_SUCCESS_FILE';

Future<void> main() async {
  final successFilePath = Platform.environment[cliAotSuccessFileEnvironment];
  final successFile = successFilePath == null || successFilePath.trim().isEmpty
      ? null
      : File(successFilePath);
  if (successFile != null && await successFile.exists()) {
    await successFile.delete();
  }

  final root = await Directory.systemTemp.createTemp('sanad-cli-aot-smoke-');
  final executable = File(
    '${root.path}/sanad${Platform.isWindows ? '.exe' : ''}',
  );
  final home = Directory('${root.path}/home');
  final stateHome = Directory('${root.path}/state');
  final environment = <String, String>{
    ...Platform.environment,
    'SANAD_HOME': home.path,
    'SANAD_STATE_HOME': stateHome.path,
    'SANAD_E2E_TEST_MODE': 'true',
  };

  try {
    final compilation = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/sanad_agent.dart',
      '-o',
      executable.path,
    ]).timeout(const Duration(minutes: 3));
    _requireSuccess('AOT compilation', compilation);

    final jsonRun = await _runAotProcess(
      executable.path,
      [
        'run',
        '--standalone',
        '--home',
        home.path,
        '--execution-root',
        root.path,
        '--json',
        'AOT JSON smoke',
      ],
      environment: environment,
      operation: 'AOT JSON run',
    );
    _requireAotSuccess('AOT JSON run', jsonRun);
    final result = jsonDecode(jsonRun.stdout);
    if (result is! Map ||
        result['exit_code'] != 0 ||
        result['text'] != 'e2e-success') {
      throw StateError('Unexpected JSON result: ${jsonRun.stdout}');
    }

    final pipeRun = await _runAotProcess(
      executable.path,
      [
        'run',
        '--standalone',
        '--home',
        home.path,
        '--execution-root',
        root.path,
        '--quiet',
      ],
      environment: environment,
      operation: 'AOT pipe run',
      stdinInput: 'AOT pipe smoke',
    );
    if (pipeRun.exitCode != 0 || pipeRun.stdout.trim() != 'e2e-success') {
      throw StateError(
        'AOT pipe run failed (${pipeRun.exitCode}): '
        'stdout=${pipeRun.stdout} stderr=${pipeRun.stderr}',
      );
    }

    await _verifyGatewayCommands(executable: executable.path, root: root);
  } finally {
    await deleteDirectoryWithRetry(root);
  }

  if (successFile != null) {
    await successFile.parent.create(recursive: true);
    await successFile.writeAsString('passed\n', flush: true);
  }
  stdout.writeln('Sanad CLI AOT JSON and pipe smoke passed.');
}

/// Runs the gateway-dependent commands of a compiled CLI against a fake
/// gateway and a throwaway Home.
///
/// This is the regression guard for the released AOT binary: a gateway command
/// must reach the gateway without opening the Agent vault. The vault is the OS
/// credential vault, and an item that belongs to another code identity makes
/// macOS raise an authorization prompt that a CLI can never answer, so opening
/// it for a command with no secrets hangs the process before the first socket
/// with no output at all. Every step below is bounded by
/// [_aotExecutionTimeout], and the fake gateway keeps the run off the default
/// port, the real Home, and the developer's daemon.
Future<void> _verifyGatewayCommands({
  required String executable,
  required Directory root,
}) async {
  final home = Directory('${root.path}/gateway-home');
  final stateHome = Directory('${root.path}/gateway-state');
  await home.create(recursive: true);
  await stateHome.create(recursive: true);
  // A throwaway token, never the developer's or a client's credential. The CLI
  // requires the token file to be owner-only, exactly as the desktop Client and
  // sanad-dev do.
  const token = 'fake-gateway-token';
  final tokenFile = File('${home.path}/.local_token');
  await tokenFile.writeAsString(token, flush: true);
  await _restrictToOwnerOnly(tokenFile);

  final baseEnvironment =
      <String, String>{
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'SANAD_STATE_HOME': stateHome.path,
        }
        ..remove('SANAD_E2E_TEST_MODE')
        ..remove('SANAD_GATEWAY_URL')
        ..remove('LOCAL_GATEWAY_URL')
        ..remove('LOCAL_GATEWAY_PORT');

  final gateway = await FakeLocalGateway.start(
    homeId: sanadHomeIdentity(home.path),
  );
  try {
    final common = <String>[
      '--home',
      home.path,
      '--gateway-url',
      gateway.gatewayUrl.toString(),
      '--json',
    ];

    final listRun = await _runAotProcess(
      executable,
      ['session', 'list', ...common],
      environment: baseEnvironment,
      operation: 'AOT session list against a fake gateway',
    );
    _requireAotSuccess('AOT session list against a fake gateway', listRun);
    final listed = jsonDecode(listRun.stdout.trim());
    if (listed is! List ||
        !listed.any(
          (entry) => entry is Map && entry['session_id'] == fakeSessionId,
        )) {
      throw StateError(
        'AOT session list did not report the fake gateway session: '
        '${listRun.stdout}',
      );
    }
    if (!gateway.commands.contains('get_sessions')) {
      throw StateError(
        'AOT session list never reached the gateway: '
        'commands=${gateway.commands}',
      );
    }
    if (!gateway.healthTokens.contains(token)) {
      throw StateError(
        'AOT session list did not authenticate with the throwaway Home token.',
      );
    }

    for (final command in const [
      ['session', 'show', fakeSessionId],
      ['session', 'stop', fakeSessionId],
    ]) {
      final result = await _runAotProcess(
        executable,
        [...command, ...common],
        environment: baseEnvironment,
        operation: 'AOT ${command.join(' ')} against a fake gateway',
      );
      _requireAotSuccess(
        'AOT ${command.join(' ')} against a fake gateway',
        result,
      );
    }

    // A gateway command must never open the Agent vault, so the throwaway Home
    // must hold no vault artifact: the vault writes its lock and generation
    // markers the first time any process opens it.
    final vaultArtifacts = home
        .listSync()
        .map((entry) => entry.path.split(Platform.pathSeparator).last)
        .where((name) => name.startsWith('secret_vault'))
        .toList();
    if (vaultArtifacts.isNotEmpty) {
      throw StateError(
        'A gateway command opened the Agent vault ($vaultArtifacts); the CLI '
        'must never make a gateway command wait on an OS credential prompt.',
      );
    }

    // `models list` is a local query that does open the vault for provider
    // credentials, and this process has no terminal. The vault must therefore
    // open and its read must finish without starting an OS authorization
    // dialog: the run may report a closed vault, but it must never wait for a
    // prompt nobody can answer, and it must never print the waiting notice that
    // belongs to an interactive run.
    final modelsRun = await _runAotProcess(
      executable,
      ['models', 'list', '--home', home.path],
      environment: baseEnvironment,
      operation: 'AOT models list',
    );
    if (modelsRun.exitCode != 0) {
      throw StateError(
        'AOT models list failed (${modelsRun.exitCode}): '
        'stdout=${modelsRun.stdout} stderr=${modelsRun.stderr}',
      );
    }
    if (modelsRun.stderr.contains(keychainApprovalWaitNotice())) {
      throw StateError(
        'AOT models list announced a Keychain approval for a process with no '
        'terminal: stderr=${modelsRun.stderr}',
      );
    }
    final vaultOpened = home
        .listSync()
        .map((entry) => entry.path.split(Platform.pathSeparator).last)
        .any((name) => name.startsWith('secret_vault'));
    if (!vaultOpened) {
      throw StateError(
        'AOT models list never opened the Agent vault, so a command that reads '
        'provider credentials was classified as secret-free.',
      );
    }
  } finally {
    await gateway.close();
  }
  stdout.writeln(
    'Sanad CLI AOT gateway commands passed against a fake gateway.',
  );
}

typedef _AotProcessResult = ({int exitCode, String stdout, String stderr});

Future<_AotProcessResult> _runAotProcess(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required String operation,
  String? stdinInput,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  if (stdinInput != null) process.stdin.write(stdinInput);
  await process.stdin.close();

  late final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(_aotExecutionTimeout);
  } on TimeoutException {
    process.kill();
    try {
      await process.exitCode.timeout(_processTerminationTimeout);
    } on TimeoutException {
      // The timeout below remains authoritative even if Windows delays reaping.
    }
    final stdout = await stdoutFuture.timeout(
      _processTerminationTimeout,
      onTimeout: () => '<stdout unavailable after termination>',
    );
    final stderr = await stderrFuture.timeout(
      _processTerminationTimeout,
      onTimeout: () => '<stderr unavailable after termination>',
    );
    throw TimeoutException(
      '$operation exceeded $_aotExecutionTimeout: '
      'stdout=$stdout stderr=$stderr',
      _aotExecutionTimeout,
    );
  }

  return (
    exitCode: exitCode,
    stdout: await stdoutFuture,
    stderr: await stderrFuture,
  );
}

/// Restricts a throwaway credential file to its owner, or fails.
///
/// The CLI refuses a `.local_token` that any other user can read, so the guard
/// must present the same shape a real Home's daemon would.
Future<void> _restrictToOwnerOnly(File file) async {
  if (Platform.isWindows) return;
  final chmod = await Process.run('chmod', ['600', file.path]);
  if (chmod.exitCode != 0) {
    throw StateError(
      'Could not restrict the throwaway token at ${file.path} to its owner: '
      '${chmod.stderr}',
    );
  }
}

Future<void> deleteDirectoryWithRetry(
  Directory directory, {
  int maxAttempts = _cleanupAttempts,
  Duration retryDelay = _cleanupRetryDelay,
  FutureOr<void> Function()? delete,
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  if (maxAttempts < 1) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
  }
  if (!await directory.exists()) return;

  final deleteOperation = delete ?? () => directory.delete(recursive: true);
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await deleteOperation();
      return;
    } on FileSystemException {
      if (attempt == maxAttempts) rethrow;
      await wait(retryDelay);
    }
  }
}

void _requireAotSuccess(String operation, _AotProcessResult result) {
  if (result.exitCode == 0) return;
  throw StateError(
    '$operation failed (${result.exitCode}): '
    'stdout=${result.stdout} stderr=${result.stderr}',
  );
}

void _requireSuccess(String operation, ProcessResult result) {
  if (result.exitCode == 0) return;
  throw StateError(
    '$operation failed (${result.exitCode}): '
    'stdout=${result.stdout} stderr=${result.stderr}',
  );
}
