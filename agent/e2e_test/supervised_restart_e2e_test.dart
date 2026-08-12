import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'source daemon supervisor relaunches the child after POST /restart',
    () {
      return _verifySupervisedRestart(
        executable: Platform.resolvedExecutable,
        arguments: const ['run', 'bin/sanad_agent.dart', 'daemon'],
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  final compiledExecutable = Platform.environment['SANAD_COMPILED_AGENT_EXE'];
  test(
    'compiled daemon supervisor relaunches the child after POST /restart',
    () {
      return _verifySupervisedRestart(
        executable: compiledExecutable!,
        arguments: const ['daemon'],
      );
    },
    skip: compiledExecutable == null
        ? 'Set SANAD_COMPILED_AGENT_EXE to verify a compiled binary.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _verifySupervisedRestart({
  required String executable,
  required List<String> arguments,
}) async {
  final tempHome = await Directory.systemTemp.createTemp(
    'sanad-supervised-restart-e2e-',
  );
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();

  final sanadHomePath = '${tempHome.path}${Platform.pathSeparator}home';
  final sanadStateHomePath = '${tempHome.path}${Platform.pathSeparator}state';
  final logs = <String>[];
  Process? supervisor;
  var stopped = false;
  try {
    supervisor = await Process.start(
      executable,
      arguments,
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'SANAD_HOME': sanadHomePath,
        'SANAD_STATE_HOME': sanadStateHomePath,
        'ENABLE_LOCAL_GATEWAY': 'true',
        'LOCAL_GATEWAY_HOST': '127.0.0.1',
        'LOCAL_GATEWAY_PORT': '$port',
        'ENABLE_GATEWAY': 'false',
        'LOG_LEVEL': 'INFO',
      },
    );
    unawaited(
      supervisor.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(logs.add)
          .asFuture<void>(),
    );
    unawaited(
      supervisor.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => logs.add('STDERR: $line'))
          .asFuture<void>(),
    );

    await _waitForHealth(port, sanadHomePath, logs: logs);
    final invalidTimeout = await _post(
      port,
      sanadHomePath,
      '/restart?timeout_seconds=0',
      expectedStatus: HttpStatus.badRequest,
    );
    expect(invalidTimeout['outcome'], 'invalid_timeout');
    await _waitForHealth(port, sanadHomePath, logs: logs);

    final restart = await _post(port, sanadHomePath, '/restart');
    expect(restart['outcome'], 'safe');

    final supervisorExited = await Future.any<bool>([
      supervisor.exitCode.then((_) => true),
      Future<bool>.delayed(const Duration(seconds: 3), () => false),
    ]);
    expect(
      supervisorExited,
      isFalse,
      reason:
          'The supervisor exited instead of replacing its daemon child.\n${logs.join('\n')}',
    );
    await _waitForHealth(port, sanadHomePath, logs: logs);

    await _post(port, sanadHomePath, '/stop');
    final exitCode = await supervisor.exitCode.timeout(
      const Duration(seconds: 10),
    );
    stopped = true;
    expect(exitCode, 0, reason: logs.join('\n'));
  } finally {
    if (!stopped) {
      try {
        await _post(port, sanadHomePath, '/stop');
      } catch (_) {}
      supervisor?.kill(ProcessSignal.sigterm);
    }
    try {
      await tempHome.delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> _waitForHealth(
  int port,
  String sanadHomePath, {
  required List<String> logs,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(milliseconds: 500));
      authorizeLocalGatewayTestRequest(request, sanadHomePath);
      final response = await request.close().timeout(
        const Duration(milliseconds: 500),
      );
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } finally {
      client.close(force: true);
    }
  }
  fail('Daemon did not become healthy on port $port.\n${logs.join('\n')}');
}

Future<Map<String, dynamic>> _post(
  int port,
  String sanadHomePath,
  String path, {
  int expectedStatus = HttpStatus.ok,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    authorizeLocalGatewayTestRequest(request, sanadHomePath);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, expectedStatus);
    return body.isEmpty
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(body) as Map);
  } finally {
    client.close(force: true);
  }
}
