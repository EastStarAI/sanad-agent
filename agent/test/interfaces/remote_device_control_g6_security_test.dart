import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_gateway_behavior.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

const _canary = 'g6-canary-bearer-9f3a7c2e1b88';
const _keyCanary = 'sk-g6canary82abcdefghijklmnop';

void main() {
  final getIt = GetIt.instance;

  late Directory tempDir;
  late DeviceCommandAdmission admission;
  late LocalWorkspaceRuntimeService runtime;
  late WorkspaceCommandHandler handler;
  late StreamSubscription<LogRecord> logSub;
  late List<String> logLines;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sanad-g6-security-test');
    await SanadHomeBootstrap.atRoot(
      tempDir.path,
      scope: SanadHomeScope.identity,
    ).prepare();
    getIt.registerSingleton<AuthManager>(_HardwareAuthManager());
    admission = DeviceCommandAdmission(registeredDeviceId: () => 'device-a');
    runtime = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
    );
    handler = WorkspaceCommandHandler(
      runtimeService: runtime,
      bridge: SanadProtocolBridge(),
      admission: admission,
    );
    logLines = <String>[];
    Logger.root.level = Level.ALL;
    logSub = Logger.root.onRecord.listen((record) {
      logLines.add('${record.message} ${record.error ?? ''}');
    });
  });

  tearDown(() async {
    await logSub.cancel();
    Logger.root.level = Level.INFO;
    await getIt.reset();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  CanonicalEvent cloudMcp(String type, Map<String, dynamic> payload) {
    return CanonicalEvent(
      type: type,
      payload: {'device_id': 'device-a', 'cloud_admitted': true, ...payload},
    );
  }

  void expectNoCanary(Object? value) {
    final text = value.toString();
    expect(text, isNot(contains(_canary)));
    expect(text, isNot(contains(_keyCanary)));
  }

  test(
    'secret canaries never appear in preview, snapshot, export, or logs',
    () async {
      final probe = _LogProbe();
      probe.logFinePayload('command', {
        'command': CanonicalEventTypes.saveMcpServer,
        'payload': {
          'secrets': {'bearer_token': _canary},
          'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
          'note': _keyCanary,
        },
      });

      final preview = await handler.buildSaveMcpServerEnvelope(
        cloudMcp(CanonicalEventTypes.saveMcpServer, {
          'request_id': 'req-g6-preview',
          'scope': 'global',
          'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
          'secrets': {'bearer_token': _canary},
        }),
      );
      expect(preview['event'], CanonicalEventTypes.mcpServerSavePreview);
      final previewPayload = Map<String, dynamic>.from(
        preview['payload'] as Map,
      );
      expectNoCanary(preview);

      final saved = await handler.buildSaveMcpServerEnvelope(
        cloudMcp(CanonicalEventTypes.saveMcpServer, {
          'request_id': 'req-g6-save',
          'scope': 'global',
          'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
          'secrets': {'bearer_token': _canary},
          'confirmation_token': previewPayload['confirmation_token'],
          'confirmation_fingerprint':
              previewPayload['confirmation_fingerprint'],
        }),
      );
      expect(saved['event'], CanonicalEventTypes.mcpServerSaved);
      expectNoCanary(saved);

      final listed = await handler.buildMcpServersEnvelope(
        cloudMcp(CanonicalEventTypes.listMcpServers, {
          'request_id': 'req-g6-list',
        }),
      );
      expectNoCanary(listed);

      final exported = await handler.buildExportMcpServersEnvelope(
        cloudMcp(CanonicalEventTypes.exportMcpServers, {
          'request_id': 'req-g6-export',
          'scope': 'global',
          'server_names': ['docs'],
        }),
      );
      expectNoCanary(exported);
      expect((exported['payload'] as Map)['credentials_excluded'], isTrue);

      expectNoCanary(logLines.join('\n'));
      expect(
        const SecretsRedactor().redactForLog({
          'secrets': {'bearer_token': _canary},
        }),
        isNot(contains(_canary)),
      );
    },
  );

  test(
    'fail-injection on invalid MCP save keeps canaries out of errors',
    () async {
      final preview = await handler.buildSaveMcpServerEnvelope(
        cloudMcp(CanonicalEventTypes.saveMcpServer, {
          'request_id': 'req-g6-fail-preview',
          'scope': 'global',
          'config': {'name': '', 'url': 'https://example.test/mcp'},
          'secrets': {'bearer_token': _canary},
        }),
      );
      final previewPayload = Map<String, dynamic>.from(
        preview['payload'] as Map,
      );

      final failed = await handler.buildSaveMcpServerEnvelope(
        cloudMcp(CanonicalEventTypes.saveMcpServer, {
          'request_id': 'req-g6-fail-save',
          'scope': 'global',
          'config': {'name': '', 'url': 'https://example.test/mcp'},
          'secrets': {'bearer_token': _canary},
          'confirmation_token': previewPayload['confirmation_token'],
          'confirmation_fingerprint':
              previewPayload['confirmation_fingerprint'],
        }),
      );
      expect(failed['event'], 'error');
      expectNoCanary(failed);
      final snapshot = await runtime.readMcpSnapshot();
      expectNoCanary(snapshot);
      expect((snapshot['global'] as Map)['servers'], isEmpty);
      expectNoCanary(logLines.join('\n'));
    },
  );
}

class _HardwareAuthManager extends AuthManager {
  _HardwareAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String get hardwareId => 'device-a';
}

class _LogProbe with SanadGatewayBehavior {
  @override
  Logger get logger => Logger('G6CanaryProbe');

  @override
  SanadProtocolBridge get protocolBridge => throw UnimplementedError();

  @override
  String get transportName => 'probe';
}
