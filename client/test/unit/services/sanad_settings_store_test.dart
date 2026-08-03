import 'dart:convert';
import 'dart:io';

import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/infrastructure/local_tools/sanad_settings_store.dart';
import 'package:sanad_client/infrastructure/mcp/mcp_server_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory fakeHome;
  late Directory workspace;
  late SanadSettingsStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('sanad-settings-store-');
    fakeHome = Directory('${tempRoot.path}${Platform.pathSeparator}home')..createSync(recursive: true);
    workspace = Directory('${tempRoot.path}${Platform.pathSeparator}workspace')..createSync(recursive: true);
    store = SanadSettingsStore(homeDirectoryPath: fakeHome.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('readEffectiveMcpServers merges user and workspace config with workspace override', () async {
    await _writeSettings(
      File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}mcp_config.json'),
      {
        'mcpServers': {
          'shared-server': {
            'id': 'user-shared',
            'name': 'shared-server',
            'url': 'https://user.example/mcp',
          },
          'user-only': {
            'id': 'user-only',
            'name': 'user-only',
            'command': 'uvx',
            'args': ['user-tool'],
          },
        },
      },
    );

    await _writeSettings(
      File('${workspace.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}mcp_config.json'),
      {
        'mcpServers': {
          'shared-server': {
            'id': 'workspace-shared',
            'name': 'shared-server',
            'url': 'https://workspace.example/sse',
          },
          'workspace-only': {
            'id': 'workspace-only',
            'name': 'workspace-only',
            'command': 'uvx',
            'args': ['workspace-tool'],
            'disabledTools': ['dangerous_write'],
          },
        },
      },
    );

    final servers = await store.readEffectiveMcpServers(workspacePath: workspace.path);
    final byName = {for (final server in servers) server.name: server};

    expect(byName.keys, containsAll(['shared-server', 'user-only', 'workspace-only']));
    expect(byName['shared-server']?.serverUrl, 'https://workspace.example/sse');
    expect(byName['shared-server']?.detectedTransport, McpTransportType.streamableHttp);
    expect(byName['user-only']?.command, 'uvx');
    expect(byName['workspace-only']?.args, ['workspace-tool']);
    expect(byName['workspace-only']?.disabledTools, ['dangerous_write']);
  });

  test('manager migrates legacy shared preferences config into ~/.sanad/mcp_config.json', () async {
    final legacyServers = [
      <String, dynamic>{
        'id': 'legacy-server',
        'name': 'legacy-server',
        'url': 'https://legacy.example/mcp',
      },
    ];

    SharedPreferences.setMockInitialValues({
      'mcp_servers': jsonEncode(legacyServers),
    });

    final prefs = await SharedPreferences.getInstance();
    final manager = McpServerManager(prefs, settingsStore: store);

    final servers = await manager.loadServers();
    final savedFile = File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}mcp_config.json');
    final savedJson = jsonDecode(await savedFile.readAsString()) as Map<String, dynamic>;
    final migratedServers = savedJson['mcpServers'] as Map<String, dynamic>;

    expect(servers, hasLength(1));
    expect(servers.single.name, 'legacy-server');
    expect(migratedServers.containsKey('legacy-server'), isTrue);
    expect(prefs.getString('mcp_servers'), isNull);
  });

  test('readEffectiveMcpServers ignores mcpServers nested in settings.json', () async {
    await _writeSettings(
      File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}settings.json'),
      {
        'mcpServers': {
          'legacy-settings-server': {
            'id': 'legacy-settings-server',
            'name': 'legacy-settings-server',
            'url': 'https://ignored.example/mcp',
          },
        },
      },
    );

    final servers = await store.readEffectiveMcpServers(workspacePath: workspace.path);

    expect(servers, isEmpty);
  });

  test('saveUserMcpServers writes both stdio and remote servers to one mcp_config file', () async {
    await store.saveUserMcpServers([
      McpServerConfig(
        id: 'stdio-server',
        name: 'stdio-server',
        authType: McpAuthType.noAuth,
        detectedTransport: McpTransportType.stdio,
        command: 'npx',
        args: const ['-y', '@modelcontextprotocol/server-filesystem'],
        disabledTools: const ['delete_file'],
      ),
      McpServerConfig(
        id: 'remote-server',
        name: 'remote-server',
        serverUrl: 'https://example.com/mcp',
        authType: McpAuthType.noAuth,
        detectedTransport: McpTransportType.streamableHttp,
      ),
    ]);

    final savedFile = File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}mcp_config.json');
    final savedJson = jsonDecode(await savedFile.readAsString()) as Map<String, dynamic>;
    final servers = savedJson['mcpServers'] as Map<String, dynamic>;
    final stdioServer = servers['stdio-server'] as Map<String, dynamic>;
    final remoteServer = servers['remote-server'] as Map<String, dynamic>;

    expect(servers.keys, containsAll(['stdio-server', 'remote-server']));
    expect(stdioServer.containsKey('type'), isFalse);
    expect(stdioServer.containsKey('id'), isFalse);
    expect(stdioServer.containsKey('name'), isFalse);
    expect(stdioServer.containsKey('authType'), isFalse);
    expect(stdioServer.containsKey('oauthAuthUrl'), isFalse);
    expect(stdioServer.containsKey('detectedTransport'), isFalse);
    expect(stdioServer['disabledTools'], ['delete_file']);
    expect(remoteServer.containsKey('type'), isFalse);
    expect(remoteServer['url'], 'https://example.com/mcp');
    expect(remoteServer.containsKey('createdAt'), isFalse);
    expect(remoteServer.containsKey('lastUsedAt'), isFalse);
    expect(
      savedFile.parent.listSync().where((entry) => entry.path.contains('.tmp.')),
      isEmpty,
    );
    if (!Platform.isWindows) {
      expect((await savedFile.stat()).mode & 0x1ff, 0x180);
      expect((await savedFile.parent.stat()).mode & 0x1ff, 0x1c0);
    }
  });

  test('saveUserMcpServers writes disabled instead of enabled', () async {
    await store.saveUserMcpServers([
      McpServerConfig(
        id: 'disabled-server',
        name: 'disabled-server',
        authType: McpAuthType.noAuth,
        detectedTransport: McpTransportType.stdio,
        command: 'docker',
        enabled: false,
      ),
    ]);

    final savedFile = File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}mcp_config.json');
    final savedJson = jsonDecode(await savedFile.readAsString()) as Map<String, dynamic>;
    final server = (savedJson['mcpServers'] as Map<String, dynamic>)['disabled-server'] as Map<String, dynamic>;

    expect(server['disabled'], isTrue);
    expect(server.containsKey('enabled'), isFalse);
  });

  test('parser ignores legacy enabled and type keys', () {
    final servers = store.parseMcpServersDocument({
      'mcpServers': {
        'legacy-remote': {
          'url': 'https://example.com/mcp',
          'type': 'sse',
          'enabled': false,
        },
        'legacy-stdio': {
          'command': 'npx',
          'args': ['-y', 'demo-server'],
          'type': 'http',
        },
      },
    });

    final byName = {for (final server in servers) server.name: server};

    expect(byName['legacy-remote']?.enabled, isTrue);
    expect(byName['legacy-remote']?.detectedTransport, McpTransportType.streamableHttp);
    expect(byName['legacy-stdio']?.detectedTransport, McpTransportType.stdio);
  });

  test('manager saveServer does not replace sibling stdio servers with empty URLs', () async {
    final prefs = await SharedPreferences.getInstance();
    final manager = McpServerManager(prefs, settingsStore: store);

    await manager.saveServer(
      McpServerConfig(
        id: 'server-a',
        name: 'server-a',
        authType: McpAuthType.noAuth,
        detectedTransport: McpTransportType.stdio,
        command: 'npx',
        args: const ['server-a'],
      ),
    );

    await manager.saveServer(
      McpServerConfig(
        id: 'server-b',
        name: 'server-b',
        authType: McpAuthType.noAuth,
        detectedTransport: McpTransportType.stdio,
        command: 'docker',
        args: const ['server-b'],
      ),
    );

    final servers = await manager.loadServers();
    final names = servers.map((server) => server.name).toList();

    expect(names, containsAll(['server-a', 'server-b']));
    expect(servers, hasLength(2));
  });

  test('explicit Sanad Home stores files directly without a nested .sanad', () async {
    final isolatedHome = Directory(
      '${tempRoot.path}${Platform.pathSeparator}isolated-sanad-home',
    );
    final isolatedStore = SanadSettingsStore(sanadHomePath: isolatedHome.path);

    await isolatedStore.saveAuthDocument({'hardware_id': 'isolated-device'});
    await isolatedStore.saveUserMcpServers([]);

    expect(
      File('${isolatedHome.path}${Platform.pathSeparator}auth.json').existsSync(),
      isTrue,
    );
    expect(
      File(
        '${isolatedHome.path}${Platform.pathSeparator}mcp_config.json',
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(
        '${isolatedHome.path}${Platform.pathSeparator}.sanad',
      ).existsSync(),
      isFalse,
    );
  });

  group('auth.json operations', () {
    test('saveAuthDocument writes to ~/.sanad/auth.json', () async {
      final authData = {
        'access_token': 'abc',
        'hardware_id': 'dev123',
      };

      await store.saveAuthDocument(authData);

      final authFile = File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}auth.json');
      expect(await authFile.exists(), isTrue);

      final content = await authFile.readAsString();
      final decoded = jsonDecode(content);
      expect(decoded['access_token'], equals('abc'));
      expect(decoded['hardware_id'], equals('dev123'));

      if (!Platform.isWindows) {
        final mode = (await authFile.stat()).mode & 0x1ff;
        expect(mode, equals(0x180)); // 0600
      }
      expect(
        authFile.parent.listSync().where((entry) => entry.path.contains('.tmp.')),
        isEmpty,
      );
    });

    test('readAuthDocument returns empty map if file missing', () async {
      final data = await store.readAuthDocument();
      expect(data, isEmpty);
    });

    test('deleteAuthDocument removes the file', () async {
      await store.saveAuthDocument({'test': 'data'});
      await store.deleteAuthDocument();

      final authFile = File('${fakeHome.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}auth.json');
      expect(await authFile.exists(), isFalse);
    });

    test('refuses a symlink target without touching its contents', () async {
      if (Platform.isWindows) return;
      final sanadHome = Directory(
        '${fakeHome.path}${Platform.pathSeparator}.sanad',
      )..createSync(recursive: true);
      final outside = File(
        '${tempRoot.path}${Platform.pathSeparator}outside-auth.json',
      )..writeAsStringSync('{"preserved":true}');
      await Link(
        '${sanadHome.path}${Platform.pathSeparator}auth.json',
      ).create(outside.path);

      await expectLater(
        store.saveAuthDocument({'hardware_id': 'must-not-write'}),
        throwsA(isA<Exception>()),
      );
      expect(await outside.readAsString(), '{"preserved":true}');
    });
  });
}

Future<void> _writeSettings(File file, Map<String, dynamic> settings) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(settings));
}
