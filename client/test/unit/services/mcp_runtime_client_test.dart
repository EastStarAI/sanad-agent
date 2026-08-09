import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeSanadSocketService cloudSocket;
  late DeviceConnectionCoordinator coordinator;
  late McpRuntimeClient client;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    cloudSocket = FakeSanadSocketService();
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: socket,
      currentDeviceId: 'test-device-id',
    );
    client = McpRuntimeClient(
      connectionCoordinator: coordinator,
      defaultDevice: () => DeviceConfig(
        id: 'test-agent',
        name: 'Test agent',
        hardwareId: 'test-device-id',
        isOnline: true,
      ),
    );
  });

  tearDown(() {
    coordinator.dispose();
    cloudSocket.dispose();
    socket.dispose();
  });

  test('listServers requests MCP snapshot from local runtime', () async {
    final future = client.listServers(workspaceId: '/repo');
    await Future<void>.delayed(Duration.zero);

    expect(socket.capturedCommands.single['command'], 'list_mcp_servers');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['workspace_id'], '/repo');

    socket.debugEmitEvent({
      'type': 'device_event',
      'event': 'mcp_servers_list',
      'payload': {
        'request_id': payload['request_id'],
        'workspace_id': '/repo',
        'global': {
          'scope': 'global',
          'document': {
            'mcpServers': {
              'github': {'url': 'https://example.com/mcp'},
            },
          },
          'servers': [
            {
              'name': 'github',
              'source': 'global',
              'config': {'name': 'github', 'url': 'https://example.com/mcp'},
            },
          ],
        },
        'workspace': {
          'scope': 'workspace',
          'document': {'mcpServers': {}},
          'servers': [],
        },
        'effective': {
          'scope': 'effective',
          'document': {
            'mcpServers': {
              'github': {'url': 'https://example.com/mcp'},
            },
          },
          'servers': [
            {
              'name': 'github',
              'source': 'global',
              'config': {'name': 'github', 'url': 'https://example.com/mcp'},
            },
          ],
        },
      },
    });

    final snapshot = await future;
    expect(snapshot.workspaceId, '/repo');
    expect(snapshot.effective.servers.single.name, 'github');
    expect(snapshot.effective.servers.single.config.serverUrl, 'https://example.com/mcp');
  });

  test('saveServer sends runtime mutation command', () async {
    final future = client.saveServer(
      scope: McpConfigScope.workspace,
      workspaceId: '/repo',
      config: McpServerConfig(
        name: 'filesystem',
        authType: McpAuthType.none,
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-filesystem'],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(socket.capturedCommands.single['command'], 'save_mcp_server');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['scope'], 'workspace');
    expect((payload['config'] as Map<String, dynamic>)['name'], 'filesystem');

    socket.debugEmitEvent({
      'type': 'device_event',
      'event': 'mcp_server_saved',
      'payload': {
        'request_id': payload['request_id'],
        'workspace_id': '/repo',
        'global': {
          'scope': 'global',
          'document': {'mcpServers': {}},
          'servers': [],
        },
        'workspace': {
          'scope': 'workspace',
          'document': {
            'mcpServers': {
              'filesystem': {
                'command': 'npx',
              },
            },
          },
          'servers': [
            {
              'name': 'filesystem',
              'source': 'workspace',
              'config': {'name': 'filesystem', 'command': 'npx'},
            },
          ],
        },
        'effective': {
          'scope': 'effective',
          'document': {
            'mcpServers': {
              'filesystem': {
                'command': 'npx',
              },
            },
          },
          'servers': [
            {
              'name': 'filesystem',
              'source': 'workspace',
              'config': {'name': 'filesystem', 'command': 'npx'},
            },
          ],
        },
      },
    });

    final snapshot = await future;
    expect(snapshot.workspace.servers.single.name, 'filesystem');
  });

  test('previewImport maps daemon response to typed draft models', () async {
    final future = client.previewImport(
      input: '{"mcpServers":{"demo":{"url":"https://example.test/mcp"}}}',
    );
    await Future<void>.delayed(Duration.zero);

    expect(socket.capturedCommands.single['command'], 'preview_mcp_import');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.debugEmitEvent({
      'type': 'device_event',
      'event': 'mcp_import_previewed',
      'payload': {
        'request_id': payload['request_id'],
        'servers': [
          {
            'name': 'demo',
            'config': {
              'url': 'https://example.test/mcp',
              'transport': 'auto',
              'authType': 'none',
            },
          },
        ],
        'warnings': ['normalized'],
        'unsupported_fields': ['demo.vendor'],
        'revision': 'abc123',
      },
    });

    final preview = await future;
    expect(preview.servers.single.config.serverUrl, 'https://example.test/mcp');
    expect(preview.warnings, ['normalized']);
    expect(preview.unsupportedFields, ['demo.vendor']);
    expect(preview.revision, 'abc123');
  });

  test('OAuth start returns only typed flow metadata', () async {
    final future = client.startOAuth(
      draft: McpServerConfig(
        name: 'oauth',
        serverUrl: 'https://example.test/mcp',
        authType: McpAuthType.oauth,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(socket.capturedCommands.single['command'], 'start_mcp_oauth');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.debugEmitEvent({
      'type': 'device_event',
      'event': 'mcp_oauth_started',
      'payload': {
        'request_id': payload['request_id'],
        'flow_id': 'flow-1',
        'status': 'authorization_required',
        'authorization_url': 'https://auth.example/authorize',
        'expires_at': '2026-08-09T12:00:00Z',
      },
    });

    final flow = await future;
    expect(flow.flowId, 'flow-1');
    expect(flow.status, McpOAuthStatus.authorizationRequired);
    expect(flow.authorizationUrl.toString(), 'https://auth.example/authorize');
  });

  test('inspectServer reads tool metadata from local runtime', () async {
    final future = client.inspectServer(serverName: 'github', scope: McpConfigScope.effective, workspaceId: '/repo');
    await Future<void>.delayed(Duration.zero);

    expect(socket.capturedCommands.single['command'], 'inspect_mcp_server');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['server_name'], 'github');

    socket.debugEmitEvent({
      'type': 'device_event',
      'event': 'mcp_server_inspected',
      'payload': {
        'request_id': payload['request_id'],
        'name': 'github',
        'scope': 'effective',
        'workspace_id': '/repo',
        'success': true,
        'tools': [
          {
            'name': 'create_issue',
            'description': 'Create a GitHub issue',
            'input_schema': {'type': 'object'},
          },
        ],
      },
    });

    final inspection = await future;
    expect(inspection.success, isTrue);
    expect(inspection.tools.single.name, 'create_issue');
  });
}
