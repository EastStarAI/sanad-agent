import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/mcp_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

import '../../../../support/memory_agent_secret_store.dart';
import '../../../../support/memory_workspace_policy_store.dart';
import '../../../../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadStateRoot();
  final getIt = GetIt.instance;

  late Directory tempDir;
  late DeviceCommandAdmission admission;
  late LocalWorkspaceRuntimeService runtime;
  late WorkspaceCommandHandler handler;
  late McpCommandHandler mcp;
  late String workspacePath;
  late MemoryWorkspacePolicyStore policyStore;

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
      policyStore: policyStore = MemoryWorkspacePolicyStore(
        paths: const {},
      ),
      admission: admission,
    );
    mcp = McpCommandHandler(
      runtimeService: runtime,
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
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
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
    final envelope = await mcp.buildSaveMcpServerEnvelope(
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
    final preview = await mcp.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-secret-preview',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
        'secrets': {'bearer_token': 'reviewed-secret'},
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    final envelope = await mcp.buildSaveMcpServerEnvelope(
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
    final preview = await mcp.buildSaveMcpServerEnvelope(
      cloudMcpEvent(CanonicalEventTypes.saveMcpServer, {
        'request_id': 'req-mcp-preview-2',
        'scope': 'global',
        'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
      }),
    );
    final previewPayload = Map<String, dynamic>.from(preview['payload'] as Map);

    final envelope = await mcp.buildSaveMcpServerEnvelope(
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
    final preview = await mcp.buildSaveMcpServerEnvelope(
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

    final envelope = await mcp.buildSaveMcpServerEnvelope(
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

  Future<Map<String, dynamic>> setPolicy(
    Map<String, dynamic> fields, {
    CommandAuthority? authority = CommandAuthority.owner,
    List<Map<String, dynamic>>? broadcasts,
  }) => handler.buildWorkspaceSetPermissionModeEnvelope(
    CanonicalEvent(
      type: CanonicalEventTypes.workspaceSetPermissionMode,
      payload: {
        'request_id': 'req-policy',
        ...fields,
        if (authority != null) CommandAuthority.payloadKey: authority.value,
      },
    ),
    (envelope) async => broadcasts?.add(envelope),
  );

  Map<String, dynamic> payloadOf(Map<String, dynamic> envelope) =>
      Map<String, dynamic>.from(envelope['payload'] as Map);

  test('rejects set_permission_mode when exec_root path does not exist', () async {
    final envelope = await setPolicy({
      'workspace_id': 'exec_root:/nonexistent/directory/path/here',
      'permission_mode': 'full_access',
    });

    expect(envelope['event'], 'error');
    expect(payloadOf(envelope)['code'], 'workspace_unavailable');
  });

  test('validates and updates policy when exec_root path is a valid directory', () async {
    final validDir = Directory('${tempDir.path}/valid_root')..createSync();
    final envelope = await setPolicy({
      'workspace_id': 'exec_root:${validDir.path}',
      'permission_mode': 'full_access',
    });

    expect(envelope['event'], CanonicalEventTypes.workspaceSetPermissionMode);
    final payload = payloadOf(envelope);
    expect(payload['permissionMode'], 'full_access');
    expect(payload['revision'], 1);
    expect(payload['canWiden'], isTrue);
  });

  group('workspace security policy authority', () {
    late String workspaceId;

    setUp(() async {
      final workspace = await runtime.describeWorkspace(workspacePath);
      workspaceId = workspace!['id'] as String;
      policyStore.bind(workspaceId, workspacePath);
    });

    test('an unstamped or unverified caller cannot widen any axis', () async {
      for (final fields in [
        {'permission_mode': 'full_access'},
        {'execution_mode': 'direct'},
        {'host_discovery_policy': 'owner_only'},
      ]) {
        await policyStore.seed(
          workspaceId,
          const WorkspacePolicy(
            executionMode: ExecutionMode.protected,
            hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
          ),
        );
        for (final authority in [null, CommandAuthority.unverified]) {
          final broadcasts = <Map<String, dynamic>>[];
          final envelope = await setPolicy(
            {'workspace_id': workspaceId, ...fields},
            authority: authority,
            broadcasts: broadcasts,
          );
          expect(payloadOf(envelope)['code'], 'permission_denied');
          expect(broadcasts, isEmpty);
        }
      }
      final stored = await policyStore.readPolicy(workspaceId);
      expect(stored.permissionMode, WorkspacePermissionMode.defaultMode);
      expect(stored.executionMode, ExecutionMode.protected);
      expect(stored.hostDiscoveryPolicy, HostDiscoveryPolicy.disabled);
    });

    test('an unverified caller may narrow and the change is broadcast', () async {
      await policyStore.seed(
        workspaceId,
        const WorkspacePolicy(permissionMode: WorkspacePermissionMode.fullAccess),
      );
      final broadcasts = <Map<String, dynamic>>[];
      final envelope = await setPolicy(
        {
          'workspace_id': workspaceId,
          'permission_mode': 'default',
          'execution_mode': 'protected',
          'host_discovery_policy': 'disabled',
        },
        authority: CommandAuthority.unverified,
        broadcasts: broadcasts,
      );
      final payload = payloadOf(envelope);
      expect(payload['permissionMode'], 'default');
      expect(payload['executionMode'], 'protected');
      expect(payload['hostDiscoveryPolicy'], 'disabled');
      expect(payload['canWiden'], isFalse);
      // The store announces the change; the requester gets only the reply.
      expect(broadcasts, isEmpty);
    });

    test('policy_changed is announced to every client, not sent to the requester', () async {
      final announced = <(String, WorkspacePolicy)>[];
      final announcing = MemoryWorkspacePolicyStore(
        paths: {workspaceId: workspacePath},
        announceChange: (id, policy) => announced.add((id, policy)),
      );
      addTearDown(announcing.dispose);
      final fanOut = WorkspaceCommandHandler(
        runtimeService: runtime,
        policyStore: announcing,
        admission: admission,
      );
      final requesterFrames = <Map<String, dynamic>>[];
      await fanOut.buildWorkspaceSetPermissionModeEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceSetPermissionMode,
          payload: {
            'request_id': 'req-fan-out',
            'workspace_id': workspaceId,
            'execution_mode': 'protected',
            CommandAuthority.payloadKey: CommandAuthority.owner.value,
          },
        ),
        (envelope) async => requesterFrames.add(envelope),
      );
      expect(announced.single.$1, workspaceId);
      expect(announced.single.$2.executionMode, ExecutionMode.protected);
      expect(announced.single.$2.revision, 1);
      expect(requesterFrames, isEmpty);
    });

    test('an owner caller from any authenticated transport can widen', () async {
      final envelope = await setPolicy({
        'workspace_id': workspaceId,
        'permission_mode': 'full_access',
        'execution_mode': 'direct',
        'host_discovery_policy': 'owner_only',
      });
      expect(payloadOf(envelope)['permissionMode'], 'full_access');
      expect(payloadOf(envelope)['canWiden'], isTrue);
    });

    test('rejects unknown values and malformed revisions without writing', () async {
      for (final fields in [
        {'permission_mode': 'root'},
        {'execution_mode': 'host'},
        {'host_discovery_policy': 'everyone'},
        {'permission_mode': 'default', 'expected_revision': 'one'},
        <String, Object>{},
      ]) {
        final envelope = await setPolicy({'workspace_id': workspaceId, ...fields});
        expect(payloadOf(envelope)['code'], 'invalid_request', reason: '$fields');
      }
      expect((await policyStore.readPolicy(workspaceId)).revision, 0);
    });

    test('a stale expected_revision is rejected with the current revision', () async {
      final first = await setPolicy({
        'workspace_id': workspaceId,
        'permission_mode': 'full_access',
        'expected_revision': 0,
      });
      expect(payloadOf(first)['revision'], 1);
      final stale = await setPolicy({
        'workspace_id': workspaceId,
        'permission_mode': 'default',
        'expected_revision': 0,
      });
      expect(payloadOf(stale)['code'], 'stale_revision');
      expect(payloadOf(stale)['current_revision'], 1);
      expect(
        (await policyStore.readPolicy(workspaceId)).permissionMode,
        WorkspacePermissionMode.fullAccess,
      );
    });

    test('an unknown workspace id is rejected', () async {
      final envelope = await setPolicy({
        'workspace_id': 'missing-workspace',
        'permission_mode': 'default',
      });
      expect(payloadOf(envelope)['code'], 'workspace_not_found');
    });

    test(
      'get_policy resolves an execution root without registering a workspace',
      () async {
        final execRoot = Directory('${tempDir.path}/exec-root-only')
          ..createSync();
        final canonicalRoot = execRoot.resolveSymbolicLinksSync();
        final before = (await runtime.listWorkspaces()).map((w) => w['id']);

        final envelope = await handler.buildWorkspaceGetPolicyEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.workspaceGetPolicy,
            payload: {
              'request_id': 'req-get-exec-root',
              'workspace_path': execRoot.path,
              CommandAuthority.payloadKey: CommandAuthority.unverified.value,
            },
          ),
        );

        final payload = payloadOf(envelope);
        expect(payload['workspaceId'], 'exec_root:$canonicalRoot');
        expect(payload['permissionMode'], 'default');
        expect(payload['revision'], 0);
        expect(payload['canWiden'], isFalse);
        // The query is a read: no workspace row is created for the execution
        // root, so the client never shows an empty workspace for the session.
        final after = await runtime.listWorkspaces();
        expect(after.map((w) => w['id']), before);
        expect(after.map((w) => w['path']), isNot(contains(canonicalRoot)));
        expect(
          runtime.stateDatabase.db.select(
            "SELECT source, path FROM workspaces "
            "WHERE source = 'legacy_path_request' OR path = ?",
            [canonicalRoot],
          ),
          isEmpty,
        );
      },
    );

    test('get_policy ignores a forged workspace settings file', () async {
      final settings = File('$workspacePath/.sanad/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"permissionMode":"full_access","executionMode":"direct",'
          '"permissions":{"allow":["shell_execute::rm -rf /"]}}',
        );
      final envelope = await handler.buildWorkspaceGetPolicyEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceGetPolicy,
          payload: {
            'request_id': 'req-get',
            'workspace_path': workspacePath,
            CommandAuthority.payloadKey: CommandAuthority.unverified.value,
          },
        ),
      );
      final payload = payloadOf(envelope);
      expect(payload['workspaceId'], workspaceId);
      expect(payload['permissionMode'], 'default');
      expect(payload['revision'], 0);
      expect(payload, isNot(contains('permissions')));
      expect(payload['canWiden'], isFalse);
      expect(settings.readAsStringSync(), contains('full_access'));
    });
  });

  group('Task 123 managed confinement replies', () {
    var sequence = 0;
    String nextId() => 'req-123-${sequence++}';

    Map<String, dynamic> errorPayload(Map<String, dynamic> envelope) {
      expect(envelope['event'], 'error');
      return Map<String, dynamic>.from(envelope['payload'] as Map);
    }

    String managedRoot() => Directory(
      '${tempDir.path}/${SanadHomeBootstrap.managedWorkspacesDirectoryName}',
    ).resolveSymbolicLinksSync();

    Future<Map<String, dynamic>> browse(String path) =>
        handler.buildWorkspaceTreeEnvelope(
          managedEvent(CanonicalEventTypes.browseWorkspaceTree, {
            'request_id': nextId(),
            'path': path,
          }),
        );

    Future<Map<String, dynamic>> createFolder(String parent) =>
        handler.buildCreateFolderEnvelope(
          managedEvent(CanonicalEventTypes.createFolder, {
            'request_id': nextId(),
            'parent_path': parent,
            'name': 'child',
          }),
        );

    Future<Map<String, dynamic>> pick(String path) =>
        handler.buildCreateWorkspaceEnvelope(
          managedEvent(CanonicalEventTypes.createWorkspace, {
            'request_id': nextId(),
            'path': path,
          }),
        );

    test('S1 a NUL path replies path_not_allowed', () async {
      final path = '${managedRoot()}/a\u0000b';
      for (final reply in [
        await browse(path),
        await createFolder(path),
        await pick(path),
      ]) {
        expect(
          errorPayload(reply)['code'],
          WorkspaceCommandErrorCodes.pathNotAllowed,
        );
      }
    });

    test('S2 a raw .. segment replies path_not_allowed', () async {
      final path = '$workspacePath/../notes';
      for (final reply in [
        await browse(path),
        await createFolder(path),
        await pick(path),
      ]) {
        expect(
          errorPayload(reply)['code'],
          WorkspaceCommandErrorCodes.pathNotAllowed,
        );
      }
      expect(Directory('$workspacePath/child').existsSync(), isFalse);
    });

    test('S4 an outside absolute path replies path_not_allowed', () async {
      final outside = Directory('${tempDir.path}-outside')..createSync();
      addTearDown(() => outside.delete(recursive: true));
      for (final reply in [
        await browse(outside.path),
        await createFolder(outside.path),
        await pick(outside.path),
      ]) {
        expect(
          errorPayload(reply)['code'],
          WorkspaceCommandErrorCodes.pathNotAllowed,
        );
      }
      expect(Directory('${outside.path}/child').existsSync(), isFalse);
    });

    test(
      'S6 an outside registered workspace replies path_not_allowed',
      () async {
        final outside = Directory('${tempDir.path}-host')..createSync();
        addTearDown(() => outside.delete(recursive: true));
        final local = await runtime.createWorkspace(path: outside.path);
        final byId = await handler.buildWorkspaceTreeEnvelope(
          managedEvent(CanonicalEventTypes.browseWorkspaceTree, {
            'request_id': nextId(),
            'workspace_id': local['id'],
          }),
        );
        expect(
          errorPayload(byId)['code'],
          WorkspaceCommandErrorCodes.pathNotAllowed,
        );
        expect(
          errorPayload(await browse(outside.path))['code'],
          WorkspaceCommandErrorCodes.pathNotAllowed,
        );
      },
    );

    test('S12 picking the managed root replies path_not_allowed', () async {
      expect(
        errorPayload(await pick(managedRoot()))['code'],
        WorkspaceCommandErrorCodes.pathNotAllowed,
      );
    });

    test(
      'S14 workspace_in_use reaches the rename and delete replies',
      () async {
        final rename = await handler.buildRenameFolderEnvelope(
          managedEvent(CanonicalEventTypes.renameFolder, {
            'request_id': nextId(),
            'path': workspacePath,
            'new_name': 'moved',
          }),
        );
        expect(
          errorPayload(rename)['code'],
          WorkspaceCommandErrorCodes.workspaceInUse,
        );
        final delete = await handler.buildDeleteFolderEnvelope(
          managedEvent(CanonicalEventTypes.deleteFolder, {
            'request_id': nextId(),
            'path': workspacePath,
          }),
        );
        expect(
          errorPayload(delete)['code'],
          WorkspaceCommandErrorCodes.workspaceInUse,
        );
        expect(Directory(workspacePath).existsSync(), isTrue);
      },
    );

    test('S16 create_workspace path and name are exclusive', () async {
      final both = await handler.buildCreateWorkspaceEnvelope(
        managedEvent(CanonicalEventTypes.createWorkspace, {
          'request_id': nextId(),
          'name': 'x',
          'path': workspacePath,
        }),
      );
      expect(
        errorPayload(both)['code'],
        WorkspaceCommandErrorCodes.invalidRequest,
      );
      final neither = await handler.buildCreateWorkspaceEnvelope(
        managedEvent(CanonicalEventTypes.createWorkspace, {
          'request_id': nextId(),
        }),
      );
      expect(
        errorPayload(neither)['code'],
        WorkspaceCommandErrorCodes.invalidRequest,
      );
    });

    test('a nested pick replies workspace_created with the folder', () async {
      final nested = await runtime.createFolder(
        parentPath: workspacePath,
        name: 'nested',
        managedRemote: true,
      );
      final reply = await pick(nested);
      expect(reply['event'], CanonicalEventTypes.workspaceCreated);
      final workspace = Map<String, dynamic>.from(
        (reply['payload'] as Map)['workspace'] as Map,
      );
      expect(workspace['path'], nested);
      expect(workspace['name'], 'nested');
    });
  });
}

class _HardwareAuthManager extends AuthManager {
  _HardwareAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String get hardwareId => 'device-a';
}
