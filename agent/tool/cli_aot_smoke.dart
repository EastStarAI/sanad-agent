import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  } finally {
    await deleteDirectoryWithRetry(root);
  }

  if (successFile != null) {
    await successFile.parent.create(recursive: true);
    await successFile.writeAsString('passed\n', flush: true);
  }
  stdout.writeln('Sanad CLI AOT JSON and pipe smoke passed.');
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
