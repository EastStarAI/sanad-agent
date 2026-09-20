import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';

class McpRuntimeClient {
  McpRuntimeClient({
    DeviceCommandClient? commandClient,
    DeviceConnectionCoordinator? connectionCoordinator,
    DeviceConfig? Function()? defaultDevice,
  }) : assert(commandClient != null || connectionCoordinator != null),
       _commandClient = commandClient ?? DeviceCommandClient(connectionCoordinator: connectionCoordinator!),
       _defaultDevice = defaultDevice ?? (() => null);

  final DeviceCommandClient _commandClient;
  final DeviceConfig? Function() _defaultDevice;

  Future<McpRuntimeSnapshot> listServers({
    DeviceConfig? device,
    String? workspaceId,
  }) async {
    final payload = await _request(
      device: _resolveDevice(device),
      command: 'list_mcp_servers',
      payload: {
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
      },
      expectedEvent: 'mcp_servers_list',
    );
    return McpRuntimeSnapshot.fromJson(payload);
  }

  Future<McpRuntimeSnapshot> saveServer({
    DeviceConfig? device,
    required McpConfigScope scope,
    required McpServerConfig config,
    String? workspaceId,
    Map<String, dynamic> secrets = const {},
  }) async {
    final payload = await _request(
      device: _resolveDevice(device),
      command: 'save_mcp_server',
      payload: {
        'scope': scope.wireValue,
        'config': {
          'name': config.name,
          ...config.toConfigJson(),
        },
        if (secrets.isNotEmpty) 'secrets': secrets,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
      },
      expectedEvent: 'mcp_server_saved',
    );
    return McpRuntimeSnapshot.fromJson(payload);
  }

  Future<McpRuntimeSnapshot> deleteServer({
    DeviceConfig? device,
    required McpConfigScope scope,
    required String serverName,
    String? workspaceId,
  }) async {
    final payload = await _request(
      device: _resolveDevice(device),
      command: 'delete_mcp_server',
      payload: {
        'scope': scope.wireValue,
        'server_name': serverName,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
      },
      expectedEvent: 'mcp_server_deleted',
    );
    return McpRuntimeSnapshot.fromJson(payload);
  }

  Future<McpServerInspection> inspectServer({
    DeviceConfig? device,
    required String serverName,
    McpConfigScope scope = McpConfigScope.effective,
    String? workspaceId,
    McpServerConfig? draft,
    Map<String, dynamic> secrets = const {},
  }) async {
    final payload = await _request(
      device: _resolveDevice(device),
      command: 'inspect_mcp_server',
      payload: {
        'scope': scope.wireValue,
        'server_name': serverName,
        if (draft != null) 'config': draft.toConfigJson(),
        if (secrets.isNotEmpty) 'secrets': secrets,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
      },
      expectedEvent: 'mcp_server_inspected',
    );
    return McpServerInspection.fromJson(payload);
  }

  Future<McpConfigPreview> previewImport({
    DeviceConfig? device,
    required String input,
  }) async => McpConfigPreview.fromJson(
    await _request(
      device: _resolveDevice(device),
      command: 'preview_mcp_import',
      payload: {'input': input},
      expectedEvent: 'mcp_import_previewed',
    ),
  );

  Future<McpExportDocument> exportServers({
    DeviceConfig? device,
    required List<String> serverNames,
    McpConfigScope scope = McpConfigScope.effective,
    String? workspaceId,
  }) async {
    final result = await _request(
      device: _resolveDevice(device),
      command: 'export_mcp_servers',
      payload: {
        'server_names': serverNames,
        'scope': scope.wireValue,
        if (workspaceId?.trim().isNotEmpty == true) 'workspace_id': workspaceId!.trim(),
      },
      expectedEvent: 'mcp_servers_exported',
    );
    return McpExportDocument.fromJson(result);
  }

  Future<McpAdvancedDocument> readAdvanced({
    DeviceConfig? device,
    required String serverName,
    required McpConfigScope scope,
    String? workspaceId,
  }) async => McpAdvancedDocument.fromJson(
    await _advancedRequest(
      device: device,
      command: 'read_advanced_mcp_server',
      expectedEvent: 'mcp_advanced_read',
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
    ),
  );

  Future<McpConfigPreview> previewAdvanced({
    DeviceConfig? device,
    required String serverName,
    required McpConfigScope scope,
    required String input,
    String? workspaceId,
  }) async => McpConfigPreview.fromJson(
    await _advancedRequest(
      device: device,
      command: 'preview_advanced_mcp_server',
      expectedEvent: 'mcp_advanced_previewed',
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
      extra: {'input': input},
    ),
  );

  Future<McpRuntimeSnapshot> saveAdvanced({
    DeviceConfig? device,
    required String serverName,
    required McpConfigScope scope,
    required String input,
    required String baseRevision,
    required String previewRevision,
    String? workspaceId,
  }) async => McpRuntimeSnapshot.fromJson(
    await _advancedRequest(
      device: device,
      command: 'save_advanced_mcp_server',
      expectedEvent: 'mcp_advanced_saved',
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
      extra: {
        'input': input,
        'base_revision': baseRevision,
        'preview_revision': previewRevision,
      },
    ),
  );

  Future<McpOAuthFlow> startOAuth({
    DeviceConfig? device,
    required McpServerConfig draft,
    Map<String, dynamic> secrets = const {},
  }) async => McpOAuthFlow.fromJson(
    await _request(
      device: _resolveDevice(device),
      command: 'start_mcp_oauth',
      payload: {
        'server_name': draft.name,
        'config': draft.toConfigJson(),
        if (secrets.isNotEmpty) 'secrets': secrets,
      },
      expectedEvent: 'mcp_oauth_started',
      timeout: const Duration(seconds: 30),
    ),
  );

  Future<McpOAuthFlow> oauthStatus({
    DeviceConfig? device,
    required String flowId,
  }) async => McpOAuthFlow.fromJson(
    await _request(
      device: _resolveDevice(device),
      command: 'get_mcp_oauth_status',
      payload: {'flow_id': flowId},
      expectedEvent: 'mcp_oauth_status',
    ),
  );

  Future<McpOAuthFlow> cancelOAuth({
    DeviceConfig? device,
    required String flowId,
  }) async => McpOAuthFlow.fromJson(
    await _request(
      device: _resolveDevice(device),
      command: 'cancel_mcp_oauth',
      payload: {'flow_id': flowId},
      expectedEvent: 'mcp_oauth_cancelled',
    ),
  );

  Future<McpRuntimeSnapshot> completeOAuth({
    DeviceConfig? device,
    required String flowId,
    required McpServerConfig config,
    required McpConfigScope scope,
    String? workspaceId,
  }) async => McpRuntimeSnapshot.fromJson(
    await _request(
      device: _resolveDevice(device),
      command: 'complete_mcp_oauth',
      payload: {
        'flow_id': flowId,
        'config': {'name': config.name, ...config.toConfigJson()},
        'scope': scope.wireValue,
        if (workspaceId?.trim().isNotEmpty == true) 'workspace_id': workspaceId!.trim(),
      },
      expectedEvent: 'mcp_oauth_completed',
    ),
  );

  Future<Map<String, dynamic>> _advancedRequest({
    DeviceConfig? device,
    required String command,
    required String expectedEvent,
    required String serverName,
    required McpConfigScope scope,
    String? workspaceId,
    Map<String, dynamic> extra = const {},
  }) => _request(
    device: _resolveDevice(device),
    command: command,
    payload: {
      'server_name': serverName,
      'scope': scope.wireValue,
      if (workspaceId?.trim().isNotEmpty == true) 'workspace_id': workspaceId!.trim(),
      ...extra,
    },
    expectedEvent: expectedEvent,
  );

  Future<Map<String, dynamic>> _request({
    required DeviceConfig device,
    required String command,
    required Map<String, dynamic> payload,
    required String expectedEvent,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final previewEvent = _previewEventFor(command);
    final result = await _commandClient.request(
      device: device,
      command: command,
      payload: payload,
      expectedEvent: expectedEvent,
      acceptedEvents: previewEvent == null ? null : {previewEvent},
      timeout: timeout,
    );
    final token = result['confirmation_token']?.toString() ?? '';
    final fingerprint = result['confirmation_fingerprint']?.toString() ?? '';
    if (previewEvent == null || token.isEmpty || fingerprint.isEmpty) {
      return result;
    }
    return _commandClient.request(
      device: device,
      command: command,
      payload: {
        ...payload,
        'confirmation_token': token,
        'confirmation_fingerprint': fingerprint,
      },
      expectedEvent: expectedEvent,
      timeout: timeout,
    );
  }

  String? _previewEventFor(String command) {
    return switch (command) {
      'save_mcp_server' || 'save_advanced_mcp_server' => 'mcp.server.save.preview',
      'delete_mcp_server' => 'mcp.server.delete.preview',
      'inspect_mcp_server' => 'mcp.server.inspect.preview',
      'complete_mcp_oauth' => 'mcp.oauth.complete.preview',
      _ => null,
    };
  }

  DeviceConfig _resolveDevice(DeviceConfig? device) {
    final resolved = device ?? _defaultDevice();
    if (resolved == null) {
      throw StateError('Select a device before managing MCP servers.');
    }
    return resolved;
  }
}
