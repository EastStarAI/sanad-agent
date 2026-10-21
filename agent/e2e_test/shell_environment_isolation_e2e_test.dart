@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/engine/adapters/e2e_fixture_adapter.dart';
import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';
import 'support/workspace_policy_seed.dart';
import '../test/support/isolated_sanad_test_home.dart';

/// A real daemon process receives a provider credential in its own
/// environment; a shell command it runs must not see it, while developer
/// variables and `PATH` survive.
void main() {
  // In-process seeding and inspection open the temporary state roots the
  // spawned daemons use; declare that isolation for the G0 test guard.
  useIsolatedSanadStateRoot();
  const sentinel = 'sk-e2e-isolation-sentinel-000000000000';

  test(
    'a daemon shell child never inherits Sanad credentials',
    () async {
      final home = await Directory.systemTemp.createTemp('sanad-env-e2e-home-');
      final state = await Directory.systemTemp.createTemp(
        'sanad-env-e2e-state-',
      );
      addTearDown(() async {
        for (final dir in [home, state]) {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
        }
      });
      final workspace = Directory('${home.path}/workspace')..createSync();
      final output = File('${state.path}/shell-env.txt');
      seedWorkspacePolicy(
        stateHomePath: state.path,
        workspacePath: workspace.path,
        policy: const WorkspacePolicy(
          permissionMode: WorkspacePermissionMode.fullAccess,
        ),
      );

      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final daemon = await Process.start(
        Platform.resolvedExecutable,
        ['bin/daemon.dart'],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'SANAD_STATE_HOME': state.path,
          'SANAD_E2E_TEST_MODE': 'true',
          'ENABLE_GATEWAY': 'false',
          'ENABLE_LOCAL_GATEWAY': 'true',
          'LOCAL_GATEWAY_PORT': '$port',
          'LLM_BASE_URL': 'http://127.0.0.1/e2e',
          'LLM_MODEL': E2eFixtureAdapter.modelId,
          'DUMP_REQUESTS': 'false',
          'OPENAI_API_KEY': sentinel,
          'SERPER_API_KEY': sentinel,
          'SANAD_E2E_PROJECT_MARKER': 'developer-value',
        },
      );
      unawaited(daemon.stdout.drain<void>());
      unawaited(daemon.stderr.drain<void>());
      addTearDown(() => daemon.kill(ProcessSignal.sigkill));

      await _waitForHealth(port, home.path);
      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: home.path,
      );
      addTearDown(socket.close);
      final frames = <Map<String, dynamic>>[];
      socket.listen(
        (raw) => frames.add(jsonDecode(raw as String) as Map<String, dynamic>),
      );

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'device_id': 'env-e2e-device',
          'command': 'think',
          'payload': {
            'request_id': 'req-env-e2e',
            'session_id': 'env-e2e-${DateTime.now().microsecondsSinceEpoch}',
            'workspace_id': workspace.path,
            'provider_instance_id': E2eFixtureAdapter.providerId,
            'model': E2eFixtureAdapter.modelId,
            'message':
                '${E2eFixtureAdapter.shellCrashPromptPrefix}'
                '${jsonEncode('env > "${output.path}"')}',
          },
        }),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!(output.existsSync() && output.lengthSync() > 0)) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'shell child never ran; frames: ${frames.map((f) => f['event'] ?? f['type']).toList()}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final env = output.readAsStringSync();
      expect(env, isNot(contains(sentinel)));
      expect(env, contains('SANAD_E2E_PROJECT_MARKER=developer-value'));
      expect(RegExp(r'^PATH=', multiLine: true).hasMatch(env), isTrue);
      expect(RegExp(r'^HOME=', multiLine: true).hasMatch(env), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: Platform.isWindows ? 'uses the POSIX env command' : false,
  );
}

Future<void> _waitForHealth(int port, String sanadHomePath) async {
  final client = HttpClient();
  Object? lastError;
  try {
    for (var attempt = 0; attempt < 100; attempt++) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/health'),
        );
        authorizeLocalGatewayTestRequest(request, sanadHomePath);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == HttpStatus.ok &&
            (jsonDecode(body) as Map<String, dynamic>)['status'] == 'ok') {
          return;
        }
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  } finally {
    client.close(force: true);
  }
  throw StateError('Daemon health check failed: $lastError');
}
