import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'local daemon exposes workspace-aware slash command results over the real websocket',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory.current;
      final sanadHome = await Directory.systemTemp.createTemp(
        'sanad-agent-e2e-home',
      );
      final sanadStateHome = await Directory.systemTemp.createTemp(
        'sanad-agent-e2e-state',
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
      ).writeAsString('Workspace owned by the local runtime query e2e test.');
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

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'search_slash_commands',
          'payload': {
            'request_id': 'req-slash-e2e',
            'workspace_id': workspaceDir.path,
            'query': 'review',
          },
        }),
      );

      expect(await frames.moveNext(), isTrue);
      final slashCommandsFrame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      expect(slashCommandsFrame['type'], equals('device_event'));
      expect(slashCommandsFrame['event'], equals('slash_commands_list'));
      expect(
        slashCommandsFrame['payload']['workspace_id'],
        equals(workspaceDir.path),
      );

      final commands =
          (slashCommandsFrame['payload']['commands'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final reviewCommand = commands.firstWhere(
        (entry) => entry['command'] == 'review',
      );
      expect(reviewCommand['source'], equals('skill'));
      expect(
        reviewCommand['description'],
        contains('Review the workspace and report findings.'),
      );
      expect(reviewCommand['path'], contains('.sanad/skills/review/SKILL.md'));

      await frames.cancel();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

int _pickPort() {
  const basePort = 58220;
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
    'ENABLE_GATEWAY': 'false',
    'ENABLE_LOCAL_GATEWAY': 'true',
    'LOCAL_GATEWAY_PORT': '$port',
    'LLM_BASE_URL': 'http://127.0.0.1:11434',
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
