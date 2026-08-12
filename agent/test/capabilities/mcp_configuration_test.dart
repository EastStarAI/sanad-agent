import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_config_codec.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_secret_store.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

class _CapturingMcpRuntimeManager extends McpRuntimeManager {
  Map<String, String>? headers;
  Map<String, String>? environment;

  @override
  Future<
    ({
      bool success,
      String? error,
      List<Tool>? tools,
      McpTransportType? transport,
      String authState,
    })
  >
  verifyMcpConnection(
    McpServerConfig serverConfig, {
    Map<String, String>? resolvedHeaders,
    Map<String, String>? resolvedEnvironment,
  }) async {
    headers = resolvedHeaders;
    environment = resolvedEnvironment;
    return (
      success: true,
      error: null,
      tools: const <Tool>[],
      transport: serverConfig.transport,
      authState: 'not_required',
    );
  }
}

void main() {
  late Directory home;
  late SanadSettingsStore settings;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('mcp-configuration-test-');
    settings = SanadSettingsStore(homeDirectoryPath: home.path);
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  test('typed transport and auth shapes round-trip without secret values', () {
    final shapes = [
      McpServerConfig(
        name: 'local',
        transport: McpTransportType.stdio,
        command: 'npx',
        args: const ['-y', 'server'],
        env: const {'MODE': 'safe'},
        secretEnv: const {'API_KEY': 'mcp-secret://env'},
      ),
      McpServerConfig(name: 'public', serverUrl: 'https://example.test/mcp'),
      McpServerConfig(
        name: 'bearer',
        serverUrl: 'https://example.test/mcp',
        authType: McpAuthType.bearer,
        bearerTokenRef: 'mcp-secret://bearer',
      ),
      McpServerConfig(
        name: 'oauth',
        serverUrl: 'https://example.test/mcp',
        authType: McpAuthType.oauth,
        oauthClientId: 'public-client',
        oauthAccessTokenRef: 'mcp-secret://access',
      ),
      McpServerConfig(
        name: 'headers',
        serverUrl: 'https://example.test/mcp',
        authType: McpAuthType.customHeaders,
        headers: const {'X-Tenant': 'east'},
        secretHeaders: const {'X-Key': 'mcp-secret://header'},
      ),
    ];

    for (final shape in shapes) {
      final decoded = McpServerConfig.fromJson({
        'name': shape.name,
        ...shape.toConfigJson(),
      });
      expect(decoded.transport, shape.transport);
      expect(decoded.authType, shape.authType);
      final snapshot = jsonEncode(decoded.toSnapshotJson());
      expect(snapshot, isNot(contains('mcp-secret://')));
      expect(snapshot, isNot(contains('token-value')));
    }
  });

  test(
    'secret store writes atomically with owner-only Unix permissions',
    () async {
      final store = McpSecretStore(homeDirectoryPath: home.path);
      final reference = await store.put('token-value');
      expect(store.resolve(reference), 'token-value');
      expect(reference, startsWith('mcp-secret://'));
      if (!Platform.isWindows) {
        final stat = await File('${home.path}/mcp_secrets.json').stat();
        expect(stat.mode & 0x1ff, 0x180); // 0600
      }
      await store.remove(reference);
      expect(store.resolve(reference), isNull);
    },
  );

  test(
    'legacy migration is idempotent and redacts config after verified copy',
    () async {
      await File('${home.path}/mcp_config.json').writeAsString(
        jsonEncode({
          'mcpServers': {
            'legacy': {
              'url': 'https://example.test/mcp',
              'authType': 'oauth',
              'accessToken': 'access-value',
              'refreshToken': 'refresh-value',
              'oauth': {'clientSecret': 'client-value'},
              'headers': {'Authorization': 'Bearer header-value'},
            },
            'stdio': {
              'command': 'node',
              'args': ['server', '--api-key', 'argument-value'],
              'env': {'MODE': 'safe', 'API_KEY': 'env-value'},
            },
          },
        }),
      );

      final first = await settings.readUserMcpConfigDocument();
      final second = await settings.readUserMcpConfigDocument();
      expect(second, first);
      final serialized = jsonEncode(first);
      for (final secret in [
        'access-value',
        'refresh-value',
        'client-value',
        'header-value',
        'env-value',
        'argument-value',
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
      expect(serialized, contains('mcp-secret://'));
      final stdio = settings
          .parseMcpServersDocument(first)
          .singleWhere((server) => server.name == 'stdio');
      expect(stdio.args, ['server', '--api-key', '<secret>']);
      expect(settings.resolveArguments(stdio), [
        'server',
        '--api-key',
        'argument-value',
      ]);
      final snapshot = settings.encodeMcpSnapshotDocument(
        settings.parseMcpServersDocument(first),
      );
      expect(jsonEncode(snapshot), isNot(contains('mcp-secret://')));
    },
  );

  test(
    'secret mutations preserve unrelated secrets and require explicit removal',
    () async {
      var config = McpServerConfig(
        name: 'secure',
        serverUrl: 'https://example.test/mcp',
        authType: McpAuthType.bearer,
      );
      config = await settings.applySecretMutations(config, {
        'bearer_token': 'first-token',
        'secret_headers': {'X-Key': 'header-value'},
      });
      final bearerRef = config.bearerTokenRef;
      final headerRef = config.secretHeaders['X-Key'];
      config = await settings.applySecretMutations(config, {
        'bearer_token': 'replacement-token',
      });
      expect(config.bearerTokenRef, bearerRef);
      expect(config.secretHeaders['X-Key'], headerRef);
      expect(
        settings.resolveHeaders(config)['Authorization'],
        'Bearer replacement-token',
      );
      config = await settings.applySecretMutations(config, {
        'remove_secret_headers': ['X-Key'],
      });
      expect(config.secretHeaders, isEmpty);
    },
  );

  test('draft inspection keeps entered credentials transient', () async {
    final manager = _CapturingMcpRuntimeManager();
    final runtime = LocalWorkspaceRuntimeService(
      sanadHomePath: home.path,
      mcpRuntimeManager: manager,
    );

    final result = await runtime.inspectMcpDraft(
      serverName: 'draft',
      scope: 'global',
      draftConfig: {
        'url': 'https://example.test/mcp',
        'transport': 'streamableHttp',
        'authType': 'bearer',
      },
      secretMutations: {
        'bearer_token': 'transient-token',
        'secret_headers': {'X-Key': 'transient-header'},
      },
    );

    expect(result['success'], isTrue);
    expect(manager.headers?['Authorization'], 'Bearer transient-token');
    expect(manager.headers?['X-Key'], 'transient-header');
    expect(File('${home.path}/mcp_secrets.json').existsSync(), isFalse);
    expect(File('${home.path}/mcp_config.json').existsSync(), isFalse);
  });

  group('import and Advanced JSON codec', () {
    const codec = McpConfigCodec();

    test(
      'accepts supported roots and reports aliases and unsupported fields',
      () {
        final wrapped = codec.previewImport(
          jsonEncode({
            'mcpServers': {
              'remote': {
                'url': 'https://example.test/mcp',
                'type': 'sse',
                'vendorOption': true,
              },
            },
          }),
        );
        expect(wrapped.servers.single.transport, McpTransportType.sse);
        expect(
          wrapped.warnings,
          contains('remote.type was normalized to transport.'),
        );
        expect(wrapped.unsupportedFields, contains('remote.vendorOption'));

        final bare = codec.previewImport(
          jsonEncode({
            'local': {
              'command': 'node',
              'args': ['server.js'],
            },
          }),
        );
        expect(bare.servers.single.name, 'local');

        final single = codec.previewImport(
          jsonEncode({'name': 'named', 'url': 'https://example.test/mcp'}),
        );
        expect(single.servers.single.name, 'named');
      },
    );

    test(
      'rejects duplicates, contradictions, inline credentials, and oversized input',
      () {
        expect(
          () => codec.previewImport(
            '{"mcpServers":{"Demo":{"url":"https://example.test"},"demo":{"url":"https://example.test"}}}',
          ),
          throwsFormatException,
        );
        expect(
          () => codec.previewImport(
            '{"mcpServers":{"bad":{"command":"node","url":"https://example.test"}}}',
          ),
          throwsFormatException,
        );
        expect(
          () => codec.previewImport(
            '{"name":"bad","url":"https://example.test","accessToken":"secret"}',
          ),
          throwsFormatException,
        );
        expect(
          () => codec.previewImport(
            List.filled(McpConfigCodec.maxInputBytes + 1, ' ').join(),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'Advanced JSON is single-server scoped and produces stable preview parity',
      () {
        final current = McpServerConfig(
          name: 'demo',
          serverUrl: 'https://example.test/mcp',
        );
        final input = jsonEncode({
          'mcpServers': {
            'demo': {
              'url': 'https://example.test/v2',
              'transport': 'streamableHttp',
            },
          },
        });
        final first = codec.previewAdvanced(
          serverName: 'demo',
          current: current,
          input: input,
        );
        final second = codec.previewAdvanced(
          serverName: 'demo',
          current: current,
          input: input,
        );
        expect(first.revision, second.revision);
        expect(first.servers.single.serverUrl, 'https://example.test/v2');
        expect(first.diff.map((entry) => entry['field']), contains('url'));
        expect(
          () => codec.previewAdvanced(
            serverName: 'other',
            current: current,
            input: input,
          ),
          throwsFormatException,
        );
      },
    );
  });

  test('codec enforces header policy and bounded redacted export', () {
    const codec = McpConfigCodec();
    expect(
      () => codec.validateHeaderName('Authorization'),
      throwsFormatException,
    );
    expect(() => codec.validateHeaderName('X-Tenant'), returnsNormally);
    final config = McpServerConfig(
      name: 'secure',
      serverUrl: 'https://example.test/mcp',
      authType: McpAuthType.customHeaders,
      secretHeaders: const {'X-Key': 'mcp-secret://header'},
    );
    final exported = codec.exportServers([config]);
    expect(exported, isNot(contains('mcp-secret://')));
    expect(exported, isNot(contains('X-Key')));
  });
}
