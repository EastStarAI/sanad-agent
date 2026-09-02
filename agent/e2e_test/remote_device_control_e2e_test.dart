@Tags(<String>['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

const _canary = 'g6-canary-bearer-9f3a7c2e1b88';

void main() {
  test(
    'device.runtime.restart reconnects and keeps workspace plus MCP mutations',
    () async {
      final tempHome = await Directory.systemTemp.createTemp(
        'sanad-g6-remote-control-e2e-',
      );
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final sanadHomePath = '${tempHome.path}${Platform.pathSeparator}home';
      final sanadStateHomePath =
          '${tempHome.path}${Platform.pathSeparator}state';
      final logs = <String>[];
      Process? supervisor;
      var stopped = false;
      try {
        supervisor = await Process.start(
          Platform.resolvedExecutable,
          const ['run', 'bin/sanad_agent.dart', 'daemon'],
          workingDirectory: Directory.current.path,
          environment: {
            ...Platform.environment,
            'SANAD_HOME': sanadHomePath,
            'SANAD_STATE_HOME': sanadStateHomePath,
            'ENABLE_LOCAL_GATEWAY': 'true',
            'LOCAL_GATEWAY_HOST': '127.0.0.1',
            'LOCAL_GATEWAY_PORT': '$port',
            'ENABLE_GATEWAY': 'false',
            'LOG_LEVEL': 'FINE',
            'SANAD_DEV_LAUNCHER_ID': 'g6-e2e',
            'SANAD_SERVICE_INSTANCE': 'g6-e2e',
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
        final deviceId = await _readHardwareId(sanadHomePath);

        var socket = await connectAuthenticatedLocalGateway(
          port: port,
          sanadHomePath: sanadHomePath,
        );
        var frames = StreamIterator(socket);
        await _waitForType(frames, 'register_success');

        await _sendCommand(
          socket,
          deviceId: deviceId,
          command: 'create_workspace',
          requestId: 'g6-create-ws',
          payload: {'name': 'g6-notes', 'managed_remote': true},
        );
        final created = await _waitForEvent(frames, 'workspace_created');
        final workspace = Map<String, dynamic>.from(
          created['payload']['workspace'] as Map,
        );
        expect(workspace['name'], 'g6-notes');
        expect(
          workspace['path'].toString(),
          contains(
            '${Platform.pathSeparator}workspaces${Platform.pathSeparator}',
          ),
        );

        await _sendCommand(
          socket,
          deviceId: deviceId,
          command: 'save_mcp_server',
          requestId: 'g6-save-mcp',
          payload: {
            'scope': 'global',
            'config': {'name': 'g6-docs', 'url': 'https://example.test/mcp'},
            'secrets': {'bearer_token': _canary},
          },
        );
        final saved = await _waitForEvent(frames, 'mcp_server_saved');
        expect(saved.toString(), isNot(contains(_canary)));

        await _sendCommand(
          socket,
          deviceId: deviceId,
          command: 'device.runtime.restart',
          requestId: 'g6-restart',
        );
        final accepted = await _waitForEvent(
          frames,
          'device.runtime.restart.accepted',
        );
        expect(accepted['payload']['status'], 'accepted');
        await socket.close();
        await frames.cancel();

        await _waitForHealth(port, sanadHomePath, logs: logs);

        socket = await connectAuthenticatedLocalGateway(
          port: port,
          sanadHomePath: sanadHomePath,
        );
        frames = StreamIterator(socket);
        await _waitForType(frames, 'register_success');

        await _sendCommand(
          socket,
          deviceId: deviceId,
          command: 'list_workspaces',
          requestId: 'g6-list-ws',
        );
        final listed = await _waitForEvent(frames, 'workspaces_list');
        final workspaces = (listed['payload']['workspaces'] as List)
            .cast<Map<dynamic, dynamic>>();
        expect(workspaces.any((entry) => entry['name'] == 'g6-notes'), isTrue);

        await _sendCommand(
          socket,
          deviceId: deviceId,
          command: 'list_mcp_servers',
          requestId: 'g6-list-mcp',
        );
        final mcp = await _waitForEvent(frames, 'mcp_servers_list');
        expect(mcp.toString(), isNot(contains(_canary)));
        final servers = ((mcp['payload']['global'] as Map)['servers'] as List)
            .cast<Map<dynamic, dynamic>>();
        expect(servers.any((entry) => entry['name'] == 'g6-docs'), isTrue);

        await socket.close();
        await frames.cancel();
        expect(logs.join('\n'), isNot(contains(_canary)));

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
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _sendCommand(
  WebSocket socket, {
  required String deviceId,
  required String command,
  required String requestId,
  Map<String, dynamic> payload = const {},
}) async {
  socket.add(
    jsonEncode({
      'type': 'execute_command',
      'device_id': deviceId,
      'hardware_id': deviceId,
      'command': command,
      'payload': {'request_id': requestId, 'device_id': deviceId, ...payload},
    }),
  );
}

Future<String> _readHardwareId(String sanadHomePath) async {
  final authFile = File('$sanadHomePath${Platform.pathSeparator}auth.json');
  final auth = jsonDecode(await authFile.readAsString());
  final hardwareId = (auth as Map<String, dynamic>)['hardware_id'] as String?;
  if (hardwareId == null || hardwareId.trim().isEmpty) {
    throw StateError('Test daemon did not persist a hardware identity.');
  }
  return hardwareId;
}

Future<Map<String, dynamic>> _waitForType(
  StreamIterator<dynamic> frames,
  String type,
) async {
  while (await frames.moveNext().timeout(const Duration(seconds: 20))) {
    final decoded = jsonDecode(frames.current as String);
    if (decoded is Map && decoded['type'] == type) {
      return Map<String, dynamic>.from(decoded);
    }
  }
  fail('Did not receive websocket type $type');
}

Future<Map<String, dynamic>> _waitForEvent(
  StreamIterator<dynamic> frames,
  String event,
) async {
  while (await frames.moveNext().timeout(const Duration(seconds: 20))) {
    final decoded = jsonDecode(frames.current as String);
    if (decoded is Map && decoded['event'] == event) {
      return Map<String, dynamic>.from(decoded);
    }
    if (decoded is Map && decoded['event'] == 'error') {
      fail('Received error while waiting for $event: $decoded');
    }
  }
  fail('Did not receive device event $event');
}

Future<void> _waitForHealth(
  int port,
  String sanadHomePath, {
  required List<String> logs,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
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
      await Future<void>.delayed(const Duration(milliseconds: 150));
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
