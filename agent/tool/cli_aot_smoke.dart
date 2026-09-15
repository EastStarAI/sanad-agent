import 'dart:convert';
import 'dart:io';

Future<void> main() async {
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

    stdout.writeln('Sanad CLI AOT JSON and pipe smoke passed.');
  } finally {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

void _requireSuccess(String operation, ProcessResult result) {
  if (result.exitCode == 0) return;
  throw StateError(
    '$operation failed (${result.exitCode}): '
    'stdout=${result.stdout} stderr=${result.stderr}',
  );
}
