import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

import '../../../../support/memory_agent_secret_store.dart';

void main() {
  final getIt = GetIt.instance;

  late Directory tempDir;
  late DeviceCommandAdmission admission;
  late LocalWorkspaceRuntimeService runtime;
  late WorkspaceCommandHandler handler;
  late String workspacePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-workspace-handler-test',
    );
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
    final created = await runtime.createWorkspace(
      name: 'notes',
      managedRemote: true,
    );
    workspacePath = created['path'] as String;
  });

  tearDown(() async {
    await getIt.reset();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  CanonicalEvent managedEvent(String type, Map<String, dynamic> payload) {
    return CanonicalEvent(
      type: type,
      payload: {'device_id': 'device-a', 'managed_remote': true, ...payload},
    );
  }

  test('delete without a token returns a one-time preview', () async {
    final folder = await runtime.createFolder(
      parentPath: workspacePath,
      name: 'drafts',
      managedRemote: true,
    );

    final envelope = await handler.buildDeleteFolderEnvelope(
      managedEvent(CanonicalEventTypes.deleteFolder, {
        'request_id': 'req-preview',
        'path': folder,
      }),
    );

    expect(envelope['event'], CanonicalEventTypes.deleteFolderPreview);
    final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
    expect(payload['confirmation_token'], isNotEmpty);
    expect(payload['confirmation_fingerprint'], isNotEmpty);
    expect(Directory(folder).existsSync(), isTrue);
  });

  test('delete with the preview token removes the folder once', () async {
    final folder = await runtime.createFolder(
      parentPath: workspacePath,
      name: 'drafts',
      managedRemote: true,
    );
    final preview = await handler.buildDeleteFolderEnvelope(
      managedEvent(CanonicalEventTypes.deleteFolder, {
        'request_id': 'req-preview',
        'path': folder,
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    final deleted = await handler.buildDeleteFolderEnvelope(
      managedEvent(CanonicalEventTypes.deleteFolder, {
        'request_id': 'req-confirm',
        'path': folder,
        'confirmation_token': previewPayload['confirmation_token'],
        'confirmation_fingerprint': previewPayload['confirmation_fingerprint'],
      }),
    );

    expect(deleted['event'], CanonicalEventTypes.folderDeleted);
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('stale delete tokens fail without mutation', () async {
    final folder = await runtime.createFolder(
      parentPath: workspacePath,
      name: 'drafts',
      managedRemote: true,
    );
    final preview = await handler.buildDeleteFolderEnvelope(
      managedEvent(CanonicalEventTypes.deleteFolder, {
        'request_id': 'req-preview',
        'path': folder,
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    await handler.buildDeleteFolderEnvelope(
      managedEvent(CanonicalEventTypes.deleteFolder, {
        'request_id': 'req-confirm',
        'path': folder,
        'confirmation_token': previewPayload['confirmation_token'],
        'confirmation_fingerprint': previewPayload['confirmation_fingerprint'],
      }),
    );

    final replay = await handler.buildDeleteFolderEnvelope(
      managedEvent(CanonicalEventTypes.deleteFolder, {
        'request_id': 'req-replay',
        'path': folder,
        'confirmation_token': previewPayload['confirmation_token'],
        'confirmation_fingerprint': previewPayload['confirmation_fingerprint'],
      }),
    );

    expect(replay['event'], 'error');
    final error = Map<String, dynamic>.from(replay['payload'] as Map);
    expect(error['code'], DeviceControlErrorCodes.staleConfirmation);
  });

  test('managed create rejects a host path', () async {
    final envelope = await handler.buildCreateWorkspaceEnvelope(
      managedEvent(CanonicalEventTypes.createWorkspace, {
        'request_id': 'req-path',
        'name': 'escaped',
        'path': '/tmp/escaped',
      }),
    );

    expect(envelope['event'], 'error');
    final error = Map<String, dynamic>.from(envelope['payload'] as Map);
    expect(error['code'], WorkspaceCommandErrorCodes.invalidRequest);
  });

  CanonicalEvent cloudMcpEvent(String type, Map<String, dynamic> payload) {
    return CanonicalEvent(
      type: type,
      payload: {'device_id': 'device-a', 'cloud_admitted': true, ...payload},
    );
  }

  test('cloud MCP save without a token returns a redacted preview', () async {
    final envelope = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-mcp-preview',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
        'secrets': {'bearer_token': 'super-secret-value'},
      }),
    );

    expect(envelope['event'], CanonicalEventTypes.mcpServerSavePreview);
    final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
    expect(payload['confirmation_token'], isNotEmpty);
    expect(payload['confirmation_fingerprint'], isNotEmpty);
    expect(payload.toString(), isNot(contains('super-secret-value')));
  });

  test('cloud MCP confirmation is bound to secret mutations', () async {
    final preview = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-secret-preview',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
        'secrets': {'bearer_token': 'reviewed-secret'},
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    final envelope = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-secret-confirm',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
        'secrets': {'bearer_token': 'changed-secret'},
        'confirmation_token': previewPayload['confirmation_token'],
        'confirmation_fingerprint': previewPayload['confirmation_fingerprint'],
      }),
    );

    expect(envelope['event'], 'error');
    expect(
      (envelope['payload'] as Map)['code'],
      DeviceControlErrorCodes.staleConfirmation,
    );
    final snapshot = await runtime.readMcpSnapshot();
    expect((snapshot['global'] as Map)['servers'], isEmpty);
  });

  test('cloud MCP save confirmation persists the server', () async {
    final preview = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-mcp-preview-2',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    final envelope = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-mcp-confirm',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
        'confirmation_token': previewPayload['confirmation_token'],
        'confirmation_fingerprint': previewPayload['confirmation_fingerprint'],
      }),
    );

    expect(envelope['event'], CanonicalEventTypes.mcpServerSaved);
    final snapshot = await runtime.readMcpSnapshot();
    final servers = (snapshot['global'] as Map)['servers'] as List;
    expect(servers, isNotEmpty);
    expect((servers.first as Map)['name'], 'docs');
  });

  test('cloud MCP save rejects a stale confirmation after mutation', () async {
    final preview = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-mcp-stale-preview',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    await runtime.saveMcpServer(
      scope: 'global',
      config: {'name': 'other', 'url': 'https://other.example/mcp'},
    );

    final envelope = await handler.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-mcp-stale',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
        'confirmation_token': previewPayload['confirmation_token'],
        'confirmation_fingerprint': previewPayload['confirmation_fingerprint'],
      }),
    );

    expect(envelope['event'], 'error');
    final error = Map<String, dynamic>.from(envelope['payload'] as Map);
    expect(error['code'], DeviceControlErrorCodes.staleConfirmation);
    final snapshot = await runtime.readMcpSnapshot();
    final servers = (snapshot['global'] as Map)['servers'] as List;
    expect(servers, hasLength(1));
    expect((servers.first as Map)['name'], 'other');
  });
}

class _HardwareAuthManager extends AuthManager {
  _HardwareAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String get hardwareId => 'device-a';
}
