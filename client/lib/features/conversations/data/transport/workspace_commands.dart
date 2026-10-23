import 'package:sanad_client/features/conversations/data/transport/command_response_errors.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_request_id.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';

/// Owns the workspace and folder commands that `ConversationCommands`
/// exposes: workspace CRUD, folder CRUD, tree browsing, and slash lookup.
///
/// The gateway stays the only transport dependency, so every request keeps the
/// request identity, payload shape, and rejection mapping the façade used.
class WorkspaceCommands {
  final ConversationCommandGateway _gateway;

  WorkspaceCommands({required ConversationCommandGateway gateway}) : _gateway = gateway;

  Future<List<DeviceWorkspace>> getWorkspaces() async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'list_workspaces',
      payload: {'request_id': requestId},
      requestId: requestId,
    );

    throwIfErrorResponse(result, 'Failed to get workspaces');
    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final workspaces = payload['workspaces'] as List? ?? [];
      return workspaces
          .map(
            (workspace) => DeviceWorkspace.fromJson(
              Map<String, dynamic>.from(workspace as Map),
            ),
          )
          .toList();
    }

    throw StateError('Failed to get workspaces');
  }

  Future<List<SlashCommandEntry>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'search_slash_commands',
      payload: {
        'request_id': requestId,
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
      },
      requestId: requestId,
    );

    throwIfErrorResponse(result, 'Failed to search slash commands');
    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final commands = payload['commands'] as List? ?? [];
      return commands
          .whereType<Map>()
          .map((command) {
            final type = switch (command['type']?.toString()) {
              'runtime_action' => SlashCommandType.runtimeAction,
              'skill' => SlashCommandType.skill,
              _ => null,
            };
            if (type == null) return null;
            return SlashCommandEntry(
              sourceId: command['source']?.toString() ?? 'runtime',
              command: command['command']?.toString() ?? '',
              insertText: command['command']?.toString() ?? '',
              description: command['description']?.toString(),
              type: type,
            );
          })
          .whereType<SlashCommandEntry>()
          .where((entry) => entry.command.trim().isNotEmpty)
          .toList(growable: false);
    }

    throw StateError('Failed to search slash commands');
  }

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({
    String? workspaceId,
    String? path,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'browse_workspace_tree',
      payload: {
        'request_id': requestId,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
        if (path != null && path.trim().isNotEmpty) 'path': path.trim(),
      },
      requestId: requestId,
    );

    throwIfWorkspaceError(result, 'Failed to browse workspace tree');
    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      return WorkspaceTreeSnapshot.fromJson(payload);
    }

    throw StateError('Failed to browse workspace tree');
  }

  Future<DeviceWorkspace> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) async {
    final trimmedPath = path?.trim() ?? '';
    final trimmedName = name?.trim() ?? '';
    final trimmedDescription = description?.trim() ?? '';
    if (trimmedPath.isEmpty && trimmedName.isEmpty) {
      throw StateError('Workspace name or path is required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'create_workspace',
      payload: {
        'request_id': requestId,
        if (trimmedPath.isNotEmpty) 'path': trimmedPath,
        if (trimmedName.isNotEmpty) 'name': trimmedName,
        if (trimmedDescription.isNotEmpty) 'description': trimmedDescription,
      },
      requestId: requestId,
    );

    throwIfWorkspaceError(result, 'Failed to create workspace');
    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final workspace = payload['workspace'];
      if (workspace is Map) {
        return DeviceWorkspace.fromJson(Map<String, dynamic>.from(workspace));
      }
    }

    throw StateError('Failed to create workspace');
  }

  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) {
    return _mutateWorkspace(
      command: 'workspace.rename',
      payload: {
        'workspace_id': workspaceId.trim(),
        'display_name': displayName.trim(),
      },
    );
  }

  Future<void> removeWorkspace({required String workspaceId}) async {
    final normalizedId = workspaceId.trim();
    if (normalizedId.isEmpty) {
      throw StateError('Workspace id is required');
    }
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.remove',
      payload: {'request_id': requestId, 'workspace_id': normalizedId},
      requestId: requestId,
    );
    final payload = result?['payload'] as Map<String, dynamic>? ?? result;
    if (result?['event'] == 'workspace.removed' && payload?['workspace_id']?.toString() == normalizedId) {
      return;
    }
    if (result?['event'] == 'error') {
      throw StateError(
        payload?['message']?.toString() ?? 'Failed to remove workspace',
      );
    }
    throw StateError('Failed to remove workspace');
  }

  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) {
    return _mutateWorkspace(
      command: 'workspace.relocate',
      payload: {'workspace_id': workspaceId.trim(), 'new_path': newPath.trim()},
      previewEvent: 'workspace.relocate.preview',
    );
  }

  Future<DeviceWorkspace> _mutateWorkspace({
    required String command,
    required Map<String, dynamic> payload,
    String? previewEvent,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: command,
      payload: {'request_id': requestId, ...payload},
      requestId: requestId,
    );
    if (previewEvent != null && result?['event'] == previewEvent) {
      final preview = result?['payload'] as Map<String, dynamic>? ?? result;
      final token = preview?['confirmation_token']?.toString() ?? '';
      final fingerprint = preview?['confirmation_fingerprint']?.toString() ?? '';
      if (token.isEmpty || fingerprint.isEmpty) {
        throw StateError('Failed to update workspace');
      }
      return _mutateWorkspace(
        command: command,
        payload: {
          ...payload,
          'confirmation_token': token,
          'confirmation_fingerprint': fingerprint,
        },
      );
    }
    final response = result == null ? null : (result['payload'] as Map<String, dynamic>? ?? result);
    throwIfWorkspaceError(result, 'Failed to update workspace');
    final workspace = response?['workspace'];
    if (workspace is Map) {
      return DeviceWorkspace.fromJson(Map<String, dynamic>.from(workspace));
    }
    throw StateError('Failed to update workspace');
  }

  Future<void> createFolder({
    required String parentPath,
    required String name,
  }) async {
    final trimmedParentPath = parentPath.trim();
    final trimmedName = name.trim();
    if (trimmedParentPath.isEmpty || trimmedName.isEmpty) {
      throw StateError('Parent path and folder name are required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.create_folder',
      payload: {
        'request_id': requestId,
        'parent_path': trimmedParentPath,
        'name': trimmedName,
      },
      requestId: requestId,
    );
    _requireFolderMutationAcknowledgment(
      result,
      expectedEvent: 'workspace.folder_created',
      fallbackMessage: 'Failed to create folder',
    );
  }

  Future<void> renameFolder({
    required String path,
    required String newName,
  }) async {
    final trimmedPath = path.trim();
    final trimmedNewName = newName.trim();
    if (trimmedPath.isEmpty || trimmedNewName.isEmpty) {
      throw StateError('Folder path and new name are required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.rename_folder',
      payload: {
        'request_id': requestId,
        'path': trimmedPath,
        'new_name': trimmedNewName,
      },
      requestId: requestId,
    );
    _requireFolderMutationAcknowledgment(
      result,
      expectedEvent: 'workspace.folder_renamed',
      fallbackMessage: 'Failed to rename folder',
    );
  }

  Future<void> deleteFolder({required String path}) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      throw StateError('Folder path is required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.delete_folder',
      payload: {'request_id': requestId, 'path': trimmedPath},
      requestId: requestId,
    );
    if (result?['event']?.toString() == 'workspace.delete_folder.preview') {
      final payload = result?['payload'] as Map<String, dynamic>? ?? result;
      final token = payload?['confirmation_token']?.toString() ?? '';
      final fingerprint = payload?['confirmation_fingerprint']?.toString() ?? '';
      if (token.isEmpty || fingerprint.isEmpty) {
        throw StateError('Failed to delete folder');
      }
      final confirmId = generateConversationRequestId();
      final confirmed = await _gateway.request(
        command: 'workspace.delete_folder',
        payload: {
          'request_id': confirmId,
          'path': trimmedPath,
          'confirmation_token': token,
          'confirmation_fingerprint': fingerprint,
        },
        requestId: confirmId,
      );
      _requireFolderMutationAcknowledgment(
        confirmed,
        expectedEvent: 'workspace.folder_deleted',
        fallbackMessage: 'Failed to delete folder',
      );
      return;
    }
    _requireFolderMutationAcknowledgment(
      result,
      expectedEvent: 'workspace.folder_deleted',
      fallbackMessage: 'Failed to delete folder',
    );
  }

  void _requireFolderMutationAcknowledgment(
    Map<String, dynamic>? result, {
    required String expectedEvent,
    required String fallbackMessage,
  }) {
    final event = result?['event']?.toString();
    if (event == expectedEvent) {
      return;
    }
    throwIfWorkspaceError(result, fallbackMessage);
    final payload = result?['payload'];
    final message = payload is Map ? payload['message'] : null;
    throw StateError(message?.toString() ?? fallbackMessage);
  }
}
