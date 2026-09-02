import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/engine/adapters/e2e_fixture_adapter.dart';
import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'local daemon requests permission before executing a sensitive platform tool',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory.current;

      final sanadHome = await Directory.systemTemp.createTemp(
        'sanad-agent-permission-e2e-home',
      );
      final sanadStateHome = await Directory.systemTemp.createTemp(
        'sanad-agent-permission-e2e-state',
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
      ).writeAsString('Workspace owned by the tool permission e2e test.');

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
      final deviceId =
          registerSuccess['device_id']?.toString() ?? 'local-agent';

      final sessionId =
          'tool-permission-e2e-${DateTime.now().millisecondsSinceEpoch}';
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'think',
          'payload': {
            'request_id':
                'req-tool-permission-${DateTime.now().millisecondsSinceEpoch}',
            'session_id': sessionId,
            'workspace_id': workspaceDir.path,
            'model': 'e2e-model',
            'message':
                'You must call the tool named system_screenshot exactly once as your first action with monitor_number=1. '
                'Do not skip the tool call. After the tool returns, answer with exactly SCREEN_OK.',
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
      expect(
        permissionRequest['payload']['tool_name'],
        equals('system_screenshot'),
      );

      final requestId = permissionRequest['payload']['request_id'] as String;
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'device_id': deviceId,
          'command': 'tool_permission_response',
          'payload': {
            'session_id': sessionId,
            'request_id': requestId,
            'allowed': true,
            'scope': 'session',
            'decision': 'allow',
          },
        }),
      );

      final platformToolCall = await _awaitEvent(
        frames: frames,
        sessionId: sessionId,
        eventType: 'platform_tool_call',
        timeout: const Duration(seconds: 45),
      );
      expect(
        platformToolCall['payload']['tool_name'],
        equals('system_screenshot'),
      );
      expect(
        (platformToolCall['payload']['tool_input'] as Map)['monitor_number'],
        equals(1),
      );

      final toolRequestId = platformToolCall['payload']['request_id'] as String;
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'device_id': deviceId,
          'command': 'platform_tool_result',
          'payload': {
            'session_id': sessionId,
            'request_id': toolRequestId,
            'output': jsonEncode({'captured': true}),
            'is_error': false,
          },
        }),
      );

      final finalAnswer = await _awaitEvent(
        frames: frames,
        sessionId: sessionId,
        eventType: 'final_answer',
        timeout: const Duration(seconds: 45),
      );
      expect(finalAnswer['payload']['content'], equals('SCREEN_OK'));

      await frames.cancel();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'parallel external file reads present permission requests one at a time',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory.current;
      final sanadHome = await Directory.systemTemp.createTemp(
        'sanad-agent-parallel-permission-e2e-home',
      );
      final sanadStateHome = await Directory.systemTemp.createTemp(
        'sanad-agent-parallel-permission-e2e-state',
      );
      final workspaceDir = Directory('${sanadHome.path}/workspace')
        ..createSync(recursive: true);
      final externalDir = Directory('${sanadHome.path}/external')
        ..createSync(recursive: true);
      final externalPaths = <String>[];
      for (var index = 0; index < 3; index++) {
        final file = File('${externalDir.path}/external-$index.txt');
        await file.writeAsString('external-content-$index');
        externalPaths.add(file.path);
      }

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
      ).writeAsString('Workspace owned by the parallel permission e2e test.');

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
      final probe = _FrameProbe(socket);
      addTearDown(probe.close);
      addTearDown(socket.close);

      final registerSuccess = await probe.waitForFrameType(
        'register_success',
        timeout: const Duration(seconds: 10),
      );
      final deviceId =
          registerSuccess['device_id']?.toString() ?? 'local-agent';
      final sessionId =
          'parallel-permission-e2e-${DateTime.now().millisecondsSinceEpoch}';
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'think',
          'payload': {
            'request_id':
                'req-parallel-permission-${DateTime.now().millisecondsSinceEpoch}',
            'session_id': sessionId,
            'workspace_id': workspaceDir.path,
            'model': 'e2e-model',
            'message':
                '${E2eFixtureAdapter.parallelExternalReadPromptPrefix}${jsonEncode(externalPaths)}',
          },
        }),
      );

      final seenPaths = <String>{};
      for (var index = 0; index < externalPaths.length; index++) {
        final permissionRequest = await probe.waitForDeviceEvent(
          sessionId: sessionId,
          eventType: 'tool_permission_request',
          occurrence: index + 1,
          timeout: const Duration(seconds: 45),
        );
        expect(permissionRequest['payload']['tool_name'], equals('file_read'));
        final toolInput = Map<String, dynamic>.from(
          permissionRequest['payload']['tool_input'] as Map,
        );
        seenPaths.add(toolInput['path'].toString());

        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          probe.deviceEventCount(sessionId, 'tool_permission_request'),
          index + 1,
          reason: 'The next permission must wait for the current response.',
        );

        socket.add(
          jsonEncode({
            'type': 'execute_command',
            'device_id': deviceId,
            'command': 'tool_permission_response',
            'payload': {
              'session_id': sessionId,
              'request_id': permissionRequest['payload']['request_id'],
              'allowed': true,
              'scope': 'once',
              'decision': 'allow',
            },
          }),
        );
      }

      final finalAnswer = await probe.waitForDeviceEvent(
        sessionId: sessionId,
        eventType: 'final_answer',
        occurrence: 1,
        timeout: const Duration(seconds: 45),
      );
      expect(
        finalAnswer['payload']['content'],
        E2eFixtureAdapter.parallelExternalReadResponseText,
      );
      final canonicalExternalPaths = externalPaths
          .map((path) => File(path).resolveSymbolicLinksSync())
          .toList(growable: false);
      expect(seenPaths, unorderedEquals(canonicalExternalPaths));
      expect(
        probe.deviceEventCount(sessionId, 'tool_permission_request'),
        externalPaths.length,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _FrameProbe {
  _FrameProbe(WebSocket socket) {
    _subscription = socket.listen((rawFrame) {
      final frame = jsonDecode(rawFrame as String) as Map<String, dynamic>;
      _frames.add(frame);
      _changes.add(null);
    });
  }

  final List<Map<String, dynamic>> _frames = [];
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );
  late final StreamSubscription<dynamic> _subscription;

  int deviceEventCount(String sessionId, String eventType) => _frames
      .where(
        (frame) =>
            frame['type'] == 'device_event' &&
            _sessionId(frame) == sessionId &&
            frame['event'] == eventType,
      )
      .length;

  Future<Map<String, dynamic>> waitForFrameType(
    String type, {
    required Duration timeout,
  }) => _waitFor(
    (frame) => frame['type'] == type,
    description: 'frame type $type',
    timeout: timeout,
  );

  Future<Map<String, dynamic>> waitForDeviceEvent({
    required String sessionId,
    required String eventType,
    required int occurrence,
    required Duration timeout,
  }) => _waitFor(
    (frame) {
      if (frame['type'] != 'device_event' ||
          _sessionId(frame) != sessionId ||
          frame['event'] != eventType) {
        return false;
      }
      final matches = _frames
          .takeWhile((candidate) => !identical(candidate, frame))
          .where(
            (candidate) =>
                candidate['type'] == 'device_event' &&
                _sessionId(candidate) == sessionId &&
                candidate['event'] == eventType,
          )
          .length;
      return matches + 1 == occurrence;
    },
    description: '$eventType occurrence $occurrence on $sessionId',
    timeout: timeout,
  );

  Future<Map<String, dynamic>> _waitFor(
    bool Function(Map<String, dynamic> frame) predicate, {
    required String description,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final frame in _frames) {
        if (predicate(frame)) return frame;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw StateError('Timed out waiting for $description');
      }
      try {
        await _changes.stream.first.timeout(remaining);
      } on TimeoutException {
        throw StateError('Timed out waiting for $description');
      }
    }
  }

  String? _sessionId(Map<String, dynamic> frame) {
    final payload = frame['payload'] is Map
        ? Map<String, dynamic>.from(frame['payload'] as Map)
        : const <String, dynamic>{};
    return frame['session_id']?.toString() ?? payload['session_id']?.toString();
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _changes.close();
  }
}

Future<Map<String, dynamic>> _awaitEvent({
  required StreamIterator<dynamic> frames,
  required String sessionId,
  required String eventType,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    late final bool hasFrame;
    try {
      hasFrame = await frames.moveNext().timeout(remaining);
    } on TimeoutException {
      break;
    }
    if (!hasFrame) {
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
  const basePort = 58820;
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
    'DUMP_REQUESTS': 'false',
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
