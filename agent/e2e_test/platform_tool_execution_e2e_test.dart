import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'local daemon resumes the turn after a platform tool result is returned',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory.current;
      final sanadHome = await Directory.systemTemp.createTemp(
        'sanad-agent-platform-tool-e2e-home',
      );
      final sanadStateHome = await Directory.systemTemp.createTemp(
        'sanad-agent-platform-tool-e2e-state',
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

      await File('${workspaceDir.path}/AGENTS.md').writeAsString(
        'Workspace owned by the platform tool execution e2e test.',
      );

      final daemon = await _startDaemon(
        sanadagentLocalDir: sanadagentLocalDir,
        sanadHome: sanadHome,
        sanadStateHome: sanadStateHome,
        port: port,
      );
      addTearDown(() async {
        daemon.kill(ProcessSignal.sigterm);
        await daemon.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            daemon.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      });

      await _waitForHealth(port, sanadHome.path);

      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: sanadHome.path,
      );
      addTearDown(() async {
        await socket.close();
      });

      final frames = StreamIterator(socket);
      expect(await frames.moveNext(), isTrue);
      final registerSuccess =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      expect(registerSuccess['type'], equals('register_success'));

      final sessionId =
          'platform-tool-e2e-${DateTime.now().millisecondsSinceEpoch}';
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'think',
          'payload': {
            'request_id':
                'req-platform-tool-${DateTime.now().millisecondsSinceEpoch}',
            'session_id': sessionId,
            'workspace_id': workspaceDir.path,
            'provider_instance_id': 'e2e-provider',
            'model': 'e2e-model',
            'message': '__SANAD_E2E_PLATFORM_TOOL__',
            'platform_tools': [
              {
                'name': 'system_screenshot',
                'display_name': 'Screenshot',
                'description': 'Capture the current screen.',
                'category': 'system',
                'input_schema': {
                  'type': 'object',
                  'properties': {
                    'monitor_number': {'type': 'integer'},
                  },
                  'required': ['monitor_number'],
                  'additionalProperties': false,
                },
                'approval': {
                  'mode': 'default',
                  'sensitive': true,
                  'scope': 'session',
                  'permission_class': 'screen_capture',
                },
                'execution': {'target': 'platform'},
                'availability': {'status': 'available'},
              },
            ],
          },
        }),
      );

      final permissionRequest = await _awaitEvent(
        frames: frames,
        sessionId: sessionId,
        eventType: 'tool_permission_request',
        timeout: const Duration(seconds: 90),
      );
      socket.add(
        jsonEncode({
          'type': 'protocol_event',
          'event': {
            'type': 'tool_permission_response',
            'payload': {
              'request_id': permissionRequest['payload']['request_id'],
              'allowed': true,
              'scope': 'session',
              'decision': 'allow',
            },
            'session_id': sessionId,
          },
        }),
      );

      final toolCall = await _awaitEvent(
        frames: frames,
        sessionId: sessionId,
        eventType: 'platform_tool_call',
        timeout: const Duration(seconds: 45),
      );
      final toolRequestId = toolCall['payload']['request_id'] as String;
      socket.add(
        jsonEncode({
          'type': 'protocol_event',
          'event': {
            'type': 'platform_tool_result',
            'payload': {
              'request_id': toolRequestId,
              'output': jsonEncode({'marker': 'PLATFORM_MARKER_321'}),
              'is_error': false,
            },
            'session_id': sessionId,
          },
        }),
      );

      final finalAnswer = await _awaitEvent(
        frames: frames,
        sessionId: sessionId,
        eventType: 'final_answer',
        timeout: const Duration(seconds: 60),
      );
      expect(
        finalAnswer['payload']['content']?.toString(),
        contains('PLATFORM_MARKER_321'),
      );

      await frames.cancel();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
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
  const basePort = 59020;
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
