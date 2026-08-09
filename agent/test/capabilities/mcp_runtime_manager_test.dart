import 'dart:io';

import 'package:test/test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';

class TestableMcpRuntimeManager extends McpRuntimeManager {
  TestableMcpRuntimeManager({required SanadSettingsStore settingsStore})
    : super(settingsStore: settingsStore);

  int connectCallCount = 0;
  int disconnectCallCount = 0;
  List<McpServerConfig> mockServers = [];

  @override
  Future<List<McpServerConfig>> listServers({String? workspacePath}) async {
    return mockServers;
  }

  @override
  Future<({dynamic client, String? error})> connectToClient(
    McpServerConfig config, {
    Map<String, String>? resolvedHeaders,
    Map<String, String>? resolvedEnvironment,
  }) async {
    connectCallCount++;
    return (client: FakeMcpClient(config), error: null);
  }

  @override
  Future<void> disconnectClient(dynamic client) async {
    disconnectCallCount++;
    if (client is FakeMcpClient) {
      client.isDisconnected = true;
    }
  }
}

class FakeMcpClient {
  FakeMcpClient(this.config);
  final McpServerConfig config;
  bool isDisconnected = false;

  Future<List<Tool>> listTools() async {
    return [
      const Tool(
        name: 'hello',
        description: 'Mock Hello',
        inputSchema: {'type': 'object'},
      ),
    ];
  }
}

void main() {
  group('McpRuntimeManager tests', () {
    late Directory tempDir;
    late SanadSettingsStore settingsStore;
    late TestableMcpRuntimeManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'mcp-runtime-manager-test',
      );
      settingsStore = SanadSettingsStore(homeDirectoryPath: tempDir.path);
      manager = TestableMcpRuntimeManager(settingsStore: settingsStore);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'listToolSpecs caches specs and uses 0ms cache on same fingerprint',
      () async {
        final config1 = McpServerConfig(
          name: 'test-server',
          enabled: true,
          command: 'node',
          args: ['server.js'],
          env: const {'ENV': 'test'},
          authType: McpAuthType.none,
          transport: McpTransportType.stdio,
        );
        manager.mockServers = [config1];

        // First run: should connect and fetch
        final specs1 = await manager.listToolSpecs(
          workspacePath: 'workspace-a',
        );
        expect(specs1, hasLength(1));
        expect(specs1.first.name, equals('mcp__test-server__hello'));
        expect(manager.connectCallCount, equals(1));

        // Second run: same config, fingerprint matches -> cache hit (no new connect)
        final specs2 = await manager.listToolSpecs(
          workspacePath: 'workspace-a',
        );
        expect(specs2, hasLength(1));
        expect(specs2.first.name, equals('mcp__test-server__hello'));
        expect(manager.connectCallCount, equals(1)); // Still 1!
      },
    );

    test(
      'listToolSpecs invalidates cache and reconnects if server config changes',
      () async {
        final config1 = McpServerConfig(
          name: 'test-server',
          enabled: true,
          command: 'node',
          args: ['server.js'],
          authType: McpAuthType.none,
          transport: McpTransportType.stdio,
        );
        manager.mockServers = [config1];

        // First run: connect
        await manager.listToolSpecs(workspacePath: 'workspace-b');
        expect(manager.connectCallCount, equals(1));

        // Update config arguments: fingerprint changes
        final config2 = McpServerConfig(
          name: 'test-server',
          enabled: true,
          command: 'node',
          args: ['different-args.js'], // changed
          authType: McpAuthType.none,
          transport: McpTransportType.stdio,
        );
        manager.mockServers = [config2];

        // Second run: config changed -> cache invalidated -> reconnects!
        await manager.listToolSpecs(workspacePath: 'workspace-b');
        expect(manager.connectCallCount, equals(2));
        expect(
          manager.disconnectCallCount,
          equals(1),
        ); // Old connection disconnected
      },
    );

    test('listToolSpecs disconnects removed/disabled servers', () async {
      final config1 = McpServerConfig(
        name: 'server-1',
        enabled: true,
        command: 'node',
        authType: McpAuthType.none,
        transport: McpTransportType.stdio,
      );
      final config2 = McpServerConfig(
        name: 'server-2',
        enabled: true,
        command: 'python',
        authType: McpAuthType.none,
        transport: McpTransportType.stdio,
      );
      manager.mockServers = [config1, config2];

      await manager.listToolSpecs(workspacePath: 'workspace-c');
      expect(manager.connectCallCount, equals(2));

      // Remove server-2 and disable server-1
      final config1Disabled = McpServerConfig(
        name: 'server-1',
        enabled: false,
        command: 'node',
        authType: McpAuthType.none,
        transport: McpTransportType.stdio,
      );
      manager.mockServers = [config1Disabled];

      await manager.listToolSpecs(workspacePath: 'workspace-c');
      // All connections of disabled/removed servers are cleaned up
      expect(manager.disconnectCallCount, equals(2));
    });
  });
}
