import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';

import '../models/local_tool_spec.dart';
import 'mcp_oauth_service.dart';
import 'mcp_server_config.dart';
import 'sanad_settings_store.dart';

class McpRuntimeManager {
  McpRuntimeManager({
    SanadSettingsStore? settingsStore,
    McpOAuthService? oauthService,
  }) : _settingsStore = settingsStore ?? const SanadSettingsStore(),
       _oauthService = oauthService ?? McpOAuthService();

  final SanadSettingsStore _settingsStore;
  final McpOAuthService _oauthService;
  final Map<String, DateTime> _refreshedOAuthExpiry = {};

  // Active persistent connection instances map: serverName -> client
  final Map<String, dynamic> _activeClients = {};

  // Config used to establish the active connections: serverName -> config
  final Map<String, McpServerConfig> _connectedConfigs = {};

  // Last concrete transport selected by a bounded inspection.
  McpTransportType? _lastConnectedTransport;

  // Cached tool specs: workspacePath (or 'global') -> specs list
  final Map<String, List<LocalToolSpec>> _specsCache = {};

  // Fingerprint of effective servers when cached: workspacePath (or 'global') -> fingerprint
  final Map<String, String> _specsCacheFingerprints = {};

  Future<List<McpServerConfig>> listServers({String? workspacePath}) async {
    return _settingsStore.readEffectiveMcpServers(workspacePath: workspacePath);
  }

  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async {
    final workspaceKey = workspacePath ?? 'global';
    final servers = await listServers(workspacePath: workspacePath);
    final enabledServers = servers.where((s) => s.enabled).toList();

    // Generate a fingerprint of the enabled configurations
    final currentFingerprint = _calculateFingerprint(enabledServers);

    if (_specsCache.containsKey(workspaceKey) &&
        _specsCacheFingerprints[workspaceKey] == currentFingerprint) {
      // 0ms Latency Cache Hit!
      return _specsCache[workspaceKey]!;
    }

    // Clean up connections for servers that are no longer enabled or present
    final enabledNames = enabledServers
        .map((s) => s.name.trim().toLowerCase())
        .toSet();
    final namesToDisconnect = _activeClients.keys
        .where((name) => !enabledNames.contains(name.trim().toLowerCase()))
        .toList();
    for (final name in namesToDisconnect) {
      await _closeConnection(name);
    }

    final specs = <LocalToolSpec>[];
    for (final server in enabledServers) {
      try {
        final client = await _getOrConnectClient(server);
        final toolsDynamic = await (client as dynamic).listTools();
        final List<Tool> tools = (toolsDynamic as List).cast<Tool>().toList(
          growable: false,
        );

        for (final tool in tools) {
          if (server.isToolDisabled(tool.name)) {
            continue;
          }
          specs.add(
            LocalToolSpec(
              name: 'mcp__${server.name}__${tool.name}',
              displayName: tool.name,
              description: tool.description,
              inputSchema: Map<String, dynamic>.from(tool.inputSchema),
              source: {
                'type': 'mcp_server',
                'id': server.name,
                'original_name': tool.name,
              },
              category: 'mcp',
              workspaceRequired: false,
              approval: const {'mode': 'default', 'sensitive': true},
              execution: const {'target': 'local_runtime', 'timeout_ms': 60000},
              serverName: server.name,
            ),
          );
        }
      } catch (error) {
        // If query fails, mark the connection as dead, close it, and continue to not block others.
        await _closeConnection(server.name);
      }
    }

    // Cache the resolved specs and update the fingerprint
    _specsCache[workspaceKey] = List<LocalToolSpec>.unmodifiable(specs);
    _specsCacheFingerprints[workspaceKey] = currentFingerprint;

    return specs;
  }

  Future<String> executeTool(
    String namespacedToolName,
    Map<String, dynamic> arguments, {
    String? workspacePath,
  }) async {
    final resolution = _resolveToolName(namespacedToolName);
    final serverName = resolution.serverName;
    final toolName = resolution.toolName;

    final servers = await listServers(workspacePath: workspacePath);
    final server = servers
        .where((candidate) => candidate.name == serverName)
        .firstOrNull;
    if (server == null) {
      throw StateError("MCP server '$serverName' not found.");
    }
    if (!server.enabled) {
      throw StateError("MCP server '$serverName' is disabled.");
    }
    if (server.isToolDisabled(toolName)) {
      throw StateError(
        "Tool '$toolName' is disabled for server '$serverName'.",
      );
    }

    dynamic client;
    try {
      client = await _getOrConnectClient(server);
    } catch (connectError) {
      throw StateError(
        _sanitizeError(
          "Failed to connect to MCP server '$serverName': $connectError",
        ),
      );
    }

    try {
      final dynamicClient = client as dynamic;
      final result = await dynamicClient
          .callTool(toolName, arguments)
          .timeout(const Duration(seconds: 60));
      return _formatResult(result, toolName, serverName);
    } catch (executionError) {
      // Self-healing: if the execution failed, the persistent socket might have closed.
      // Clean up the dead connection, reconnect, and try once more.
      await _closeConnection(serverName);
      try {
        final freshClient = await _getOrConnectClient(server);
        final dynamicClient = freshClient as dynamic;
        final result = await dynamicClient
            .callTool(toolName, arguments)
            .timeout(const Duration(seconds: 60));
        return _formatResult(result, toolName, serverName);
      } catch (retryError) {
        throw StateError(
          _sanitizeError(
            "Failed to execute tool '$toolName' on MCP server '$serverName' after retry: $retryError",
          ),
        );
      }
    }
  }

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
    // Inspection always uses a fresh connection and may receive ephemeral
    // credentials that must never be persisted merely to test a draft.
    try {
      final result = await connectToClient(
        serverConfig,
        resolvedHeaders: resolvedHeaders,
        resolvedEnvironment: resolvedEnvironment,
      );
      if (result.client == null) {
        return (
          success: false,
          error: _sanitizeError(result.error),
          tools: null,
          transport: null,
          authState: _authStateForFailure(serverConfig, result.error),
        );
      }

      final client = result.client!;
      try {
        final toolsDynamic = await (client as dynamic).listTools();
        final tools = (toolsDynamic as List).cast<Tool>().toList(
          growable: false,
        );
        return (
          success: true,
          error: null,
          tools: tools,
          transport: _lastConnectedTransport ?? serverConfig.transport,
          authState: serverConfig.authType == McpAuthType.oauth
              ? 'approved'
              : 'not_required',
        );
      } catch (error) {
        return (
          success: false,
          error: _sanitizeError('Failed to list tools: $error'),
          tools: null,
          transport: _lastConnectedTransport,
          authState: _authStateForFailure(serverConfig, error),
        );
      } finally {
        await disconnectClient(client);
      }
    } catch (error) {
      return (
        success: false,
        error: _sanitizeError(error.toString()),
        tools: null,
        transport: _lastConnectedTransport,
        authState: _authStateForFailure(serverConfig, error),
      );
    }
  }

  Future<dynamic> _getOrConnectClient(McpServerConfig server) async {
    final name = server.name;
    final existingClient = _activeClients[name];
    final existingConfig = _connectedConfigs[name];

    if (existingClient != null && existingConfig != null) {
      if (!_isConfigChanged(existingConfig, server)) {
        return existingClient;
      }
      // Config changed (e.g. env vars, arguments, command or URL). Close old process first.
      await _closeConnection(name);
    }

    final connection = await connectToClient(server);
    if (connection.client == null) {
      throw StateError(
        _sanitizeError(
          connection.error ?? "Failed to connect to MCP server '$name'.",
        ),
      );
    }

    _activeClients[name] = connection.client!;
    _connectedConfigs[name] = server;
    return connection.client!;
  }

  bool _isConfigChanged(McpServerConfig oldConfig, McpServerConfig newConfig) {
    if (oldConfig.command != newConfig.command ||
        oldConfig.serverUrl != newConfig.serverUrl ||
        oldConfig.transport != newConfig.transport ||
        oldConfig.authType != newConfig.authType ||
        oldConfig.bearerTokenRef != newConfig.bearerTokenRef ||
        oldConfig.oauthAccessTokenRef != newConfig.oauthAccessTokenRef) {
      return true;
    }
    return jsonEncode(oldConfig.args) != jsonEncode(newConfig.args) ||
        jsonEncode(oldConfig.env) != jsonEncode(newConfig.env) ||
        jsonEncode(oldConfig.secretEnv) != jsonEncode(newConfig.secretEnv) ||
        jsonEncode(oldConfig.headers) != jsonEncode(newConfig.headers) ||
        jsonEncode(oldConfig.secretHeaders) !=
            jsonEncode(newConfig.secretHeaders);
  }

  Future<void> _closeConnection(String serverName) async {
    final client = _activeClients.remove(serverName);
    _connectedConfigs.remove(serverName);
    if (client != null) {
      await disconnectClient(client);
    }
  }

  String _calculateFingerprint(List<McpServerConfig> servers) {
    final List<Map<String, dynamic>> configs = servers
        .map((s) => s.toConfigJson())
        .toList(growable: false);
    return jsonEncode(configs);
  }

  String _formatResult(dynamic result, String toolName, String serverName) {
    final buffer = StringBuffer();
    for (final chunk in result.content) {
      String? text;
      try {
        text = (chunk as dynamic).text?.toString();
      } catch (_) {}
      text ??= chunk.toString();
      final cleanText = text.trim();
      if (cleanText.isNotEmpty) {
        if (buffer.isNotEmpty) {
          buffer.writeln();
        }
        buffer.write(cleanText);
      }
    }

    if (buffer.isEmpty) {
      return jsonEncode({
        'ok': result.isError != true,
        'tool': toolName,
        'server': serverName,
      });
    }
    return buffer.toString().trimRight();
  }

  Future<({dynamic client, String? error})> connectToClient(
    McpServerConfig config, {
    Map<String, String>? resolvedHeaders,
    Map<String, String>? resolvedEnvironment,
  }) async {
    final clientConfig = McpClient.simpleConfig(
      name: 'Sanad Agent',
      version: '1.0.0',
    );

    _lastConnectedTransport = null;
    if (config.transport == McpTransportType.stdio) {
      if (config.command == null || config.command!.trim().isEmpty) {
        return (client: null, error: 'STDIO server missing command.');
      }
      final result = await McpClient.createAndConnect(
        config: clientConfig,
        transportConfig: TransportConfig.stdio(
          command: config.command!,
          arguments: config.args,
          environment: _buildSafeEnvironment(
            resolvedEnvironment ?? _settingsStore.resolveEnvironment(config),
          ),
        ),
      ).timeout(const Duration(seconds: 20));
      return result.fold((client) {
        _lastConnectedTransport = McpTransportType.stdio;
        return (client: client, error: null);
      }, (error) => (client: null, error: error.toString()));
    }

    if (config.serverUrl.trim().isEmpty) {
      return (
        client: null,
        error: 'Missing server URL for networked MCP transport.',
      );
    }

    final headers = resolvedHeaders ?? await _resolvedHeaders(config);
    final candidates = config.transport == McpTransportType.auto
        ? const [McpTransportType.streamableHttp, McpTransportType.sse]
        : [config.transport];
    String? lastError;
    for (final candidate in candidates) {
      final transportConfig = candidate == McpTransportType.sse
          ? TransportConfig.sse(serverUrl: config.serverUrl, headers: headers)
          : TransportConfig.streamableHttp(
              baseUrl: config.serverUrl,
              headers: headers,
            );
      try {
        final result = await McpClient.createAndConnect(
          config: clientConfig,
          transportConfig: transportConfig,
        ).timeout(const Duration(seconds: 20));
        final connection = result.fold<dynamic>((client) => client, (error) {
          lastError = error.toString();
          return null;
        });
        if (connection != null) {
          _lastConnectedTransport = candidate;
          return (client: connection, error: null);
        }
      } on TimeoutException {
        lastError = 'Connection timed out.';
      }
    }
    return (client: null, error: lastError ?? 'MCP connection failed.');
  }

  Future<void> disconnectClient(dynamic client) async {
    try {
      final result = client.disconnect();
      if (result is Future) {
        await result;
      }
    } catch (_) {}
  }

  ({String serverName, String toolName}) _resolveToolName(
    String namespacedToolName,
  ) {
    if (!namespacedToolName.startsWith('mcp__')) {
      throw FormatException(
        'Expected an MCP tool name, got: $namespacedToolName',
      );
    }

    final segments = namespacedToolName.split('__');
    if (segments.length < 3) {
      throw FormatException('Invalid MCP tool namespace: $namespacedToolName');
    }

    return (serverName: segments[1], toolName: segments.sublist(2).join('__'));
  }

  final RegExp _credentialPattern = RegExp(
    r'(ghp_[A-Za-z0-9_]{1,255}|sk-[A-Za-z0-9_]{1,255}|Bearer\s+\S+|token=[^\s&,;"]+|password=[^\s&,;"]+|API_KEY=[^\s&,;"]+|secret=[^\s&,;"]+)',
    caseSensitive: false,
  );

  String _sanitizeError(dynamic error) {
    final text = error.toString();
    return text.replaceAll(_credentialPattern, '[REDACTED]');
  }

  Future<Map<String, String>> _resolvedHeaders(McpServerConfig config) async {
    final headers = _settingsStore.resolveHeaders(config);
    if (config.authType != McpAuthType.oauth) return headers;
    final persistedExpiry = config.tokenExpiry;
    final refreshedExpiry = _refreshedOAuthExpiry[config.name];
    final expiresAt = refreshedExpiry ?? persistedExpiry;
    if (expiresAt == null || expiresAt.isAfter(DateTime.now())) return headers;

    final refreshToken = _settingsStore.resolveOAuthRefreshToken(config);
    if (refreshToken == null) return headers;
    final grant = await _oauthService.refresh(
      config: config,
      refreshToken: refreshToken,
      clientSecret: _settingsStore.resolveOAuthClientSecret(config),
    );
    await _settingsStore.applySecretMutations(config, {
      'oauth': {
        'access_token': grant.accessToken,
        if (grant.refreshToken != null) 'refresh_token': grant.refreshToken!,
      },
    });
    _refreshedOAuthExpiry[config.name] = DateTime.now().add(
      Duration(seconds: grant.expiresIn ?? 3600),
    );
    return {...headers, 'Authorization': 'Bearer ${grant.accessToken}'};
  }

  String _authStateForFailure(McpServerConfig config, Object? error) {
    if (config.authType != McpAuthType.oauth) return 'not_required';
    final text = error?.toString().toLowerCase() ?? '';
    if (text.contains('401') ||
        text.contains('403') ||
        text.contains('unauthorized') ||
        !config.hasConfiguredOAuth) {
      return 'authorization_required';
    }
    return 'error';
  }

  Map<String, String> _buildSafeEnvironment(Map<String, String>? userEnv) {
    const safeKeys = {
      'PATH',
      'HOME',
      'USER',
      'LANG',
      'TERM',
      'SHELL',
      'TMPDIR',
    };
    final env = <String, String>{};
    for (final key in Platform.environment.keys) {
      if (safeKeys.contains(key) || key.startsWith('XDG_')) {
        env[key] = Platform.environment[key]!;
      }
    }
    if (userEnv != null) {
      env.addAll(userEnv);
    }
    return env;
  }
}
