import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'local daemon persists memory tool writes across restart through the real think path',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory.current;
      final sanadHome = await Directory.systemTemp.createTemp(
        'sanad-agent-memory-e2e-home',
      );
      final sanadStateHome = await Directory.systemTemp.createTemp(
        'sanad-agent-memory-e2e-state',
      );
      final workspaceDir = Directory('${sanadHome.path}/workspace')
        ..createSync(recursive: true);

      addTearDown(() async {
        if (sanadHome.existsSync()) {
          await sanadHome.delete(recursive: true);
        }
        if (sanadStateHome.existsSync()) {
          await sanadStateHome.delete(recursive: true);
        }
      });

      await File(
        '${workspaceDir.path}/AGENTS.md',
      ).writeAsString('Workspace owned by the memory tool e2e test.');

      final firstDaemon = await _startDaemon(
        sanadagentLocalDir: sanadagentLocalDir,
        sanadHome: sanadHome,
        sanadStateHome: sanadStateHome,
        port: port,
      );
      await _runAddMemoryScenario(
        daemon: firstDaemon,
        port: port,
        sanadHomePath: sanadHome.path,
        workspacePath: workspaceDir.path,
      );

      final userMemoryFile = File('${sanadStateHome.path}/memories/USER.md');
      expect(userMemoryFile.existsSync(), isTrue);
      final persistedMemory = await userMemoryFile.readAsString();
      expect(persistedMemory, contains('User name is Ahmed Memory E2E'));

      final secondDaemon = await _startDaemon(
        sanadagentLocalDir: sanadagentLocalDir,
        sanadHome: sanadHome,
        sanadStateHome: sanadStateHome,
        port: port,
      );
      await _runReadMemoryScenario(
        daemon: secondDaemon,
        port: port,
        sanadHomePath: sanadHome.path,
        workspacePath: workspaceDir.path,
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _runAddMemoryScenario({
  required Process daemon,
  required int port,
  required String sanadHomePath,
  required String workspacePath,
}) async {
  final teardown = _daemonTearDown(daemon);
  try {
    await _waitForHealth(port, sanadHomePath);

    final socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: sanadHomePath,
    );
    final frames = StreamIterator(socket);
    expect(await frames.moveNext(), isTrue);
    final registerSuccess =
        jsonDecode(frames.current as String) as Map<String, dynamic>;
    expect(registerSuccess['type'], equals('register_success'));

    final sessionId = 'memory-add-e2e-${DateTime.now().millisecondsSinceEpoch}';
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'command': 'think',
        'payload': {
          'request_id':
              'req-memory-add-${DateTime.now().millisecondsSinceEpoch}',
          'session_id': sessionId,
          'workspace_id': workspacePath,
          'provider_instance_id': 'e2e-provider',
          'model': 'e2e-model',
          'message': '__SANAD_E2E_MEMORY_ADD__',
        },
      }),
    );

    final toolUseFrame = await _awaitEvent(
      frames: frames,
      sessionId: sessionId,
      eventType: 'tool_use',
      timeout: const Duration(seconds: 90),
    );
    expect(toolUseFrame['payload']['tool'], equals('memory'));
    final toolInput = toolUseFrame['payload']['input']?.toString() ?? '';
    expect(toolInput, contains('"action":"add"'));
    expect(toolInput, contains('"target":"user"'));
    expect(toolInput, contains('Ahmed Memory E2E'));

    final toolResultFrame = await _awaitEvent(
      frames: frames,
      sessionId: sessionId,
      eventType: 'tool_result',
      timeout: const Duration(seconds: 90),
    );
    expect(toolResultFrame['payload']['tool'], equals('memory'));
    final toolOutput = toolResultFrame['payload']['output']?.toString() ?? '';
    expect(toolOutput, contains('"success":true'));
    expect(toolOutput, contains('"done":true'));
    expect(toolOutput, contains('"target":"user"'));
    expect(toolOutput, isNot(contains('"entries"')));
    expect(toolOutput, isNot(contains('"path"')));

    final finalAnswerFrame = await _awaitEvent(
      frames: frames,
      sessionId: sessionId,
      eventType: 'final_answer',
      timeout: const Duration(seconds: 90),
    );
    expect(
      finalAnswerFrame['payload']['content']?.toString(),
      contains('MEMORY_STORED'),
    );

    await frames.cancel();
    await socket.close();
  } finally {
    await teardown();
  }
}

Future<void> _runReadMemoryScenario({
  required Process daemon,
  required int port,
  required String sanadHomePath,
  required String workspacePath,
}) async {
  final teardown = _daemonTearDown(daemon);
  try {
    await _waitForHealth(port, sanadHomePath);

    final socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: sanadHomePath,
    );
    final frames = StreamIterator(socket);
    expect(await frames.moveNext(), isTrue);
    final registerSuccess =
        jsonDecode(frames.current as String) as Map<String, dynamic>;
    expect(registerSuccess['type'], equals('register_success'));

    final sessionId =
        'memory-read-e2e-${DateTime.now().millisecondsSinceEpoch}';
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'command': 'think',
        'payload': {
          'request_id':
              'req-memory-read-${DateTime.now().millisecondsSinceEpoch}',
          'session_id': sessionId,
          'workspace_id': workspacePath,
          'provider_instance_id': 'e2e-provider',
          'model': 'e2e-model',
          'message': '__SANAD_E2E_MEMORY_READ__',
        },
      }),
    );

    final toolUseFrame = await _awaitEvent(
      frames: frames,
      sessionId: sessionId,
      eventType: 'tool_use',
      timeout: const Duration(seconds: 90),
    );
    expect(toolUseFrame['payload']['tool'], equals('memory'));
    final toolInput = toolUseFrame['payload']['input']?.toString() ?? '';
    expect(toolInput, contains('"action":"read"'));
    expect(toolInput, contains('"target":"user"'));

    final toolResultFrame = await _awaitEvent(
      frames: frames,
      sessionId: sessionId,
      eventType: 'tool_result',
      timeout: const Duration(seconds: 90),
    );
    expect(toolResultFrame['payload']['tool'], equals('memory'));
    final toolOutput = toolResultFrame['payload']['output']?.toString() ?? '';
    expect(toolOutput, contains('"success":true'));
    expect(toolOutput, contains('User name is Ahmed Memory E2E'));

    final finalAnswerFrame = await _awaitEvent(
      frames: frames,
      sessionId: sessionId,
      eventType: 'final_answer',
      timeout: const Duration(seconds: 90),
    );
    expect(
      finalAnswerFrame['payload']['content']?.toString(),
      contains('MEMORY_READ'),
    );

    await frames.cancel();
    await socket.close();
  } finally {
    await teardown();
  }
}

Future<void> Function() _daemonTearDown(Process daemon) {
  return () async {
    daemon.kill(ProcessSignal.sigterm);
    await daemon.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        daemon.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  };
}

Future<Map<String, dynamic>> _awaitEvent({
  required StreamIterator<dynamic> frames,
  required String sessionId,
  required String eventType,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await frames.moveNext()) {
      break;
    }

    final frame = jsonDecode(frames.current as String) as Map<String, dynamic>;
    if (frame['type'] != 'device_event') {
      continue;
    }

    final payload = frame['payload'] is Map
        ? Map<String, dynamic>.from(frame['payload'] as Map)
        : <String, dynamic>{};
    final eventSessionId =
        frame['session_id'] as String? ?? payload['session_id'] as String?;
    if (eventSessionId != sessionId) {
      continue;
    }

    if (frame['event'] == eventType) {
      return frame;
    }
  }

  throw StateError(
    'Timed out waiting for event $eventType on session $sessionId',
  );
}

int _pickPort() {
  const basePort = 59120;
  return basePort + (DateTime.now().millisecondsSinceEpoch % 200);
}

Future<Process> _startDaemon({
  required Directory sanadagentLocalDir,
  required Directory sanadHome,
  required Directory sanadStateHome,
  required int port,
}) async {
  final environment = <String, String>{
    ...Platform.environment,
    'SANAD_HOME': sanadHome.path,
    'SANAD_STATE_HOME': sanadStateHome.path,
    'SANAD_E2E_TEST_MODE': 'true',
    'ENABLE_GATEWAY': 'false',
    'ENABLE_LOCAL_GATEWAY': 'true',
    'LOCAL_GATEWAY_PORT': '$port',
    'LLM_BASE_URL': 'http://127.0.0.1/e2e',
    'LLM_MODEL': 'e2e-model',
  };

  final process = await Process.start(
    Platform.resolvedExecutable,
    ['bin/daemon.dart'],
    workingDirectory: sanadagentLocalDir.path,
    environment: environment,
  );

  unawaited(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stdout.writeln('[daemon] $line'))
        .asFuture<void>(),
  );
  unawaited(
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[daemon] $line'))
        .asFuture<void>(),
  );

  return process;
}

Future<void> _waitForHealth(int port, String sanadHomePath) async {
  final client = HttpClient();
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  Object? lastError;

  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/health'),
        );
        authorizeLocalGatewayTestRequest(request, sanadHomePath);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          if (decoded['status'] == 'ok') {
            return;
          }
        }
        lastError = StateError('Unexpected health response: $body');
      } catch (error) {
        lastError = error;
      }

      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    client.close(force: true);
  }

  throw StateError(
    'Local daemon health endpoint did not become ready: $lastError',
  );
}
