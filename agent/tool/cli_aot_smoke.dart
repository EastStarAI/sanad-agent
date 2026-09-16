import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _cleanupAttempts = 20;
const _cleanupRetryDelay = Duration(milliseconds: 250);
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

    final jsonRun = await Process.run(executable.path, [
      'run',
      '--standalone',
      '--home',
      home.path,
      '--json',
      'AOT JSON smoke',
    ], environment: environment).timeout(const Duration(seconds: 30));
    _requireSuccess('AOT JSON run', jsonRun);
    final result = jsonDecode(jsonRun.stdout.toString());
    if (result is! Map ||
        result['exit_code'] != 0 ||
        result['text'] != 'e2e-success') {
      throw StateError('Unexpected JSON result: ${jsonRun.stdout}');
    }

    final pipeRun = await Process.start(executable.path, [
      'run',
      '--standalone',
      '--home',
      home.path,
      '--quiet',
    ], environment: environment);
    pipeRun.stdin.write('AOT pipe smoke');
    await pipeRun.stdin.close();
    final pipeStdout = await pipeRun.stdout.transform(utf8.decoder).join();
    final pipeStderr = await pipeRun.stderr.transform(utf8.decoder).join();
    final pipeExit = await pipeRun.exitCode.timeout(
      const Duration(seconds: 30),
    );
    if (pipeExit != 0 || pipeStdout.trim() != 'e2e-success') {
      throw StateError(
        'AOT pipe run failed ($pipeExit): stdout=$pipeStdout stderr=$pipeStderr',
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

void _requireSuccess(String operation, ProcessResult result) {
  if (result.exitCode == 0) return;
  throw StateError(
    '$operation failed (${result.exitCode}): '
    'stdout=${result.stdout} stderr=${result.stderr}',
  );
}
