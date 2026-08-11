import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'local daemon executes skill_load through the real think path',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory.current;
      final sanadHome = await Directory.systemTemp.createTemp(
        'sanad-agent-skill-e2e-home',
      );
      final sanadStateHome = await Directory.systemTemp.createTemp(
        'sanad-agent-skill-e2e-state',
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
      ).writeAsString('Workspace owned by the skill load e2e test.');
      await Directory(
        '${workspaceDir.path}/.sanad/skills/review',
      ).create(recursive: true);
      await File(
        '${workspaceDir.path}/.sanad/skills/review/SKILL.md',
      ).writeAsString('''---
name: review
description: Review the workspace and report findings.
---
Use the review skill for workspace audits.
''');

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
          'skill-load-e2e-${DateTime.now().millisecondsSinceEpoch}';
      final requestId =
          'req-skill-load-${DateTime.now().millisecondsSinceEpoch}';

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'think',
          'payload': {
            'request_id': requestId,
            'session_id': sessionId,
            'workspace_id': workspaceDir.path,
            'provider_instance_id': 'e2e-provider',
            'model': 'e2e-model',
            'message': '__SANAD_E2E_SKILL_LOAD__',
          },
        }),
      );

      Map<String, dynamic>? toolUseFrame;
      Map<String, dynamic>? toolResultFrame;
      Map<String, dynamic>? finalAnswerFrame;
      final deadline = DateTime.now().add(const Duration(seconds: 90));

      while (DateTime.now().isBefore(deadline)) {
        if (!await frames.moveNext()) {
          break;
        }

        final frame =
            jsonDecode(frames.current as String) as Map<String, dynamic>;
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

        final eventType = frame['event'] as String?;
        if (eventType == 'tool_use' && payload['tool'] == 'skill_load') {
          toolUseFrame = frame;
        } else if (eventType == 'tool_result' &&
            payload['tool'] == 'skill_load') {
          toolResultFrame = frame;
        } else if (eventType == 'final_answer') {
          finalAnswerFrame = frame;
          if ((payload['status']?.toString() ?? 'done') == 'done') {
            break;
          }
        }
      }

      expect(
        toolUseFrame,
        isNotNull,
        reason: 'skill_load tool_use was never observed.',
      );
      expect(
        toolResultFrame,
        isNotNull,
        reason: 'skill_load tool_result was never observed.',
      );
      expect(
        finalAnswerFrame,
        isNotNull,
        reason: 'final_answer was never observed.',
      );

      final toolUsePayload = Map<String, dynamic>.from(
        toolUseFrame!['payload'] as Map,
      );
      final toolUseInput = toolUsePayload['input']?.toString() ?? '';
      expect(toolUseInput, contains('"skill":"review"'));

      final toolResultPayload = Map<String, dynamic>.from(
        toolResultFrame!['payload'] as Map,
      );
      final toolOutput = toolResultPayload['output']?.toString() ?? '';
      expect(toolOutput, startsWith('Skill source: '));
      expect(
        toolOutput,
        contains('/workspace/.sanad/skills/review/SKILL.md\n\n'),
      );
      expect(
        toolOutput,
        contains('Use the review skill for workspace audits.'),
      );
      expect(toolResultPayload['isError'], isFalse);

      final finalPayload = Map<String, dynamic>.from(
        finalAnswerFrame!['payload'] as Map,
      );
      expect(finalPayload['content']?.toString().trim(), isNotEmpty);

      await frames.cancel();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

int _pickPort() {
  const basePort = 58420;
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
