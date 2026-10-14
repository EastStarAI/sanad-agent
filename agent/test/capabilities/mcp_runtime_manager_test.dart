import 'dart:io';

import 'package:test/test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_windows_path/windows_path.dart';

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

    test('MCP stdio environment receives resolved Windows PATH once', () async {
      var reads = 0;
      final manager = McpRuntimeManager(
        settingsStore: settingsStore,
        windowsSystemPath: WindowsSystemPath(
          isWindows: true,
          runPowerShell: () async {
            reads++;
            return r'C:\system\bin';
          },
        ),
      );

      final first = await manager.buildSafeEnvironment(
        const {'TOKEN': 'configured'},
        platformEnvironment: const {
          'Path': r'C:\stale',
          'HOME': r'C:\home',
          'SECRET': 'excluded',
        },
      );
      final second = await manager.buildSafeEnvironment(
        null,
        platformEnvironment: const {'PATH': r'C:\other-stale'},
      );

      expect(first, {
        'HOME': r'C:\home',
        'PATH': r'C:\system\bin',
        'TOKEN': 'configured',
      });
      expect(second, {'PATH': r'C:\system\bin'});
      expect(reads, 1);
    });

    test(
      'explicit MCP server PATH overrides the resolved system PATH',
      () async {
        final manager = McpRuntimeManager(
          settingsStore: settingsStore,
          windowsSystemPath: WindowsSystemPath(
            isWindows: true,
            runPowerShell: () async => r'C:\system\bin',
          ),
        );

        final environment = await manager.buildSafeEnvironment(
          const {'Path': r'C:\server\bin'},
          platformEnvironment: const {'PATH': r'C:\stale'},
        );

        expect(environment, {'PATH': r'C:\server\bin'});
      },
    );
  });
}
