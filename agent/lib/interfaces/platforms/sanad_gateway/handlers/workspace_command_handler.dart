import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/infrastructure/platform/automation_service_factory.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import '../sanad_protocol_bridge.dart';

/// Handles workspace browsing, creation, MCP server management, slash-command
/// discovery, computer-use toggles, and workspace policy queries/mutations.
class WorkspaceCommandHandler {
  final LocalWorkspaceRuntimeService _runtimeService;
  final EnvFileService? _envFileService;
  final WorkspacePolicyStore? _policyStore;
  final SanadProtocolBridge _bridge;

  WorkspaceCommandHandler({
    required LocalWorkspaceRuntimeService runtimeService,
    EnvFileService? envFileService,
    WorkspacePolicyStore? policyStore,
    required SanadProtocolBridge bridge,
  }) : _runtimeService = runtimeService,
       _envFileService = envFileService,
       _policyStore = policyStore,
       _bridge = bridge;

  Future<Map<String, dynamic>> buildWorkspacesEnvelope(
    CanonicalEvent event,
  ) async {
    final workspaces = await _runtimeService.listWorkspaces();
    final requestId = event.payload['request_id'] as String?;

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.workspacesList,
        payload: {'request_id': requestId, 'workspaces': workspaces},
      ),
    );
  }

  Future<Map<String, dynamic>> buildCreateWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final name = event.payload['name'] as String? ?? '';
    final path = event.payload['path'] as String?;

    final workspace = await _runtimeService.createWorkspace(
      name: name,
      path: path,
    );
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.workspaceCreated,
        sessionId: event.sessionId,
        payload: {'request_id': requestId, 'workspace': workspace},
      ),
    );
  }

  Future<Map<String, dynamic>> buildRenameWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    try {
      final workspace = await _runtimeService.renameWorkspace(
        workspaceId: _requiredString(event, 'workspace_id'),
        displayName: _requiredString(event, 'display_name'),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRenamed,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'rename workspace',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildRelocateWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    try {
      final workspace = await _runtimeService.relocateWorkspace(
        workspaceId: _requiredString(event, 'workspace_id'),
        newPath: _requiredString(event, 'new_path'),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRelocated,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'change workspace path',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildWorkspaceTreeEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final path = event.payload['path'] as String?;

    final tree = await _runtimeService.browseWorkspaceTree(
      workspaceId: workspaceId,
      path: path,
    );
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.workspaceTree,
        payload: {'request_id': requestId, ...tree},
      ),
    );
  }

  Future<Map<String, dynamic>> buildCreateFolderEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    try {
      final path = await _runtimeService.createFolder(
        parentPath: _requiredString(event, 'parent_path'),
        name: _requiredString(event, 'name'),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderCreated,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'create folder',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildRenameFolderEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    try {
      final path = await _runtimeService.renameFolder(
        path: _requiredString(event, 'path'),
        newName: _requiredString(event, 'new_name'),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderRenamed,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'rename folder',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildDeleteFolderEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    try {
      final path = await _runtimeService.deleteFolder(
        _requiredString(event, 'path'),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderDeleted,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'delete folder',
        error: error,
      );
    }
  }

  String _requiredString(CanonicalEvent event, String key) {
    final value = event.payload[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  Map<String, dynamic> _mutationError({
    required String? requestId,
    required String action,
    required Object error,
  }) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: 'error',
        payload: {
          'request_id': requestId,
          'message': 'Failed to $action: ${_errorMessage(error)}',
        },
      ),
    );
  }

  String _errorMessage(Object error) {
    return switch (error) {
      StateError() => error.message,
      FormatException() => error.message,
      FileSystemException() => error.message,
      _ => error.toString(),
    };
  }

  Map<String, dynamic> _folderMutationSuccess({
    required String type,
    required String? requestId,
    required String path,
  }) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: type,
        payload: {'request_id': requestId, 'path': path},
      ),
    );
  }

  Future<Map<String, dynamic>> buildMcpServersEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final snapshot = await _runtimeService.readMcpSnapshot(
      workspaceId: workspaceId,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServersList,
        payload: {
          'request_id': requestId,
          'workspace_id': workspaceId,
          ...snapshot,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildSaveMcpServerEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'global';
    final config = Map<String, dynamic>.from(
      event.payload['config'] as Map? ?? const {},
    );
    final snapshot = await _runtimeService.saveMcpServer(
      scope: scope,
      workspaceId: workspaceId,
      config: config,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServerSaved,
        payload: {'request_id': requestId, ...snapshot},
      ),
    );
  }

  Future<Map<String, dynamic>> buildDeleteMcpServerEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'global';
    final serverName = event.payload['server_name'] as String? ?? '';
    final snapshot = await _runtimeService.deleteMcpServer(
      scope: scope,
      workspaceId: workspaceId,
      serverName: serverName,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServerDeleted,
        payload: {'request_id': requestId, ...snapshot},
      ),
    );
  }

  Future<Map<String, dynamic>> buildReplaceMcpConfigEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'global';
    final document = Map<String, dynamic>.from(
      event.payload['document'] as Map? ?? const {},
    );
    final snapshot = await _runtimeService.replaceMcpConfig(
      scope: scope,
      workspaceId: workspaceId,
      document: document,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpConfigReplaced,
        payload: {'request_id': requestId, ...snapshot},
      ),
    );
  }

  Future<Map<String, dynamic>> buildInspectMcpServerEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'effective';
    final serverName = event.payload['server_name'] as String? ?? '';
    final inspection = await _runtimeService.inspectMcpServer(
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServerInspected,
        payload: {'request_id': requestId, ...inspection},
      ),
    );
  }

  Future<Map<String, dynamic>> buildSlashCommandsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final query = event.payload['query'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final commands = await _runtimeService.searchSlashCommands(
      query: query,
      workspaceId: workspaceId,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.slashCommandsList,
        payload: {
          'request_id': requestId,
          'query': query,
          'workspace_id': workspaceId,
          'commands': commands,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildSkillsEnvelope(CanonicalEvent event) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final includeShadowed =
        event.payload['include_shadowed'] as bool? ?? workspaceId != null;
    final inventory = await _runtimeService.listSkills(
      workspaceId: workspaceId,
      includeShadowed: includeShadowed,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.skillsList,
        payload: {
          'request_id': requestId,
          'workspace_id': workspaceId,
          ...inventory,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildCheckComputerUsePermissionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final service = AutomationServiceFactory.instance;
    final granted = await service.checkPermissions();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemCheckComputerUsePermissionsResult,
        payload: {'request_id': requestId, 'granted': granted},
      ),
    );
  }

  Future<Map<String, dynamic>> buildRequestComputerUsePermissionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final service = AutomationServiceFactory.instance;
    final granted = await service.requestPermissions();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemRequestComputerUsePermissionsResult,
        payload: {'request_id': requestId, 'granted': granted},
      ),
    );
  }

  Future<Map<String, dynamic>> buildToggleComputerUseEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final value = event.payload['enabled'] as bool? ?? false;

    await _envFileService?.upsert({'COMPUTER_USE': value.toString()});

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemToggleComputerUseResult,
        payload: {'request_id': requestId, 'enabled': value, 'saved': true},
      ),
    );
  }

  Future<Map<String, dynamic>> buildWorkspaceGetPolicyEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspacePath = event.payload['workspace_path'] as String?;

    if (workspacePath == null || workspacePath.isEmpty) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'workspace_path is required',
          },
        ),
      );
    }

    try {
      final policy = await _policyStore!.readPolicy(workspacePath);
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceGetPolicy,
          payload: {'request_id': requestId, ...policy.toJson()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'Failed to read workspace policy: $e',
          },
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildWorkspaceSetPermissionModeEnvelope(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final permissionModeString = event.payload['permission_mode'] as String?;

    if (workspaceId == null ||
        workspaceId.isEmpty ||
        permissionModeString == null) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'workspace_id and permission_mode are required',
          },
        ),
      );
    }

    final mode = WorkspacePermissionMode.fromValue(permissionModeString);
    try {
      final workspace = await _runtimeService.describeWorkspaceById(
        workspaceId,
      );
      if (workspace == null) {
        throw StateError('Workspace not found.');
      }
      if (workspace['is_missing'] == true) {
        throw StateError('Workspace folder is unavailable.');
      }
      final workspacePath = workspace['path'] as String;
      final current = await _policyStore!.readPolicy(workspacePath);
      final updated = current.copyWith(permissionMode: mode);
      await _policyStore.savePolicy(workspacePath, updated);

      final broadcastEvent = CanonicalEvent(
        type: CanonicalEventTypes.workspacePolicyChanged,
        payload: {'workspace_id': workspaceId, 'policy': updated.toJson()},
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      );
      await emitEnvelope(_bridge.buildAgentEventEnvelope(broadcastEvent));

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceSetPermissionMode,
          payload: {'request_id': requestId, ...updated.toJson()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'Failed to update workspace policy: $e',
          },
        ),
      );
    }
  }
}
