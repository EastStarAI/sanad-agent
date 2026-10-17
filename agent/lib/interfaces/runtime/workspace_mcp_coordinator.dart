import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/mcp_client.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_config_codec.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_oauth_service.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';

/// Coordinates MCP configuration snapshotting, mutations, export,
/// OAuth authorization flows, and live server connection inspections.
class WorkspaceMcpCoordinator {
  WorkspaceMcpCoordinator({
    required String Function() getSanadHome,
    required String? Function() getCurrentWorkspacePath,
    required Map<String, dynamic>? Function(String workspaceId)
    getWorkspaceRecordById,
    required Future<String?> Function(String workspaceId)
    resolveWorkspacePathById,
    required Future<String?> Function(String workspaceIdOrPath)
    resolveWorkspacePath,
    McpRuntimeManager? mcpRuntimeManager,
    McpOAuthService? mcpOAuthService,
  })  : _getSanadHome = getSanadHome,
        _getCurrentWorkspacePath = getCurrentWorkspacePath,
        _getWorkspaceRecordById = getWorkspaceRecordById,
        _resolveWorkspacePathById = resolveWorkspacePathById,
        _resolveWorkspacePath = resolveWorkspacePath,
        _mcpRuntimeManager =
            mcpRuntimeManager ??
            McpRuntimeManager(
              settingsStore: SanadSettingsStore(
                homeDirectoryPath: getSanadHome(),
              ),
            ),
        _mcpOAuthService = mcpOAuthService ?? McpOAuthService();

  final String Function() _getSanadHome;
  final String? Function() _getCurrentWorkspacePath;
  final Map<String, dynamic>? Function(String workspaceId)
  _getWorkspaceRecordById;
  final Future<String?> Function(String workspaceId) _resolveWorkspacePathById;
  final Future<String?> Function(String workspaceIdOrPath)
  _resolveWorkspacePath;

  final McpRuntimeManager _mcpRuntimeManager;
  final McpOAuthService _mcpOAuthService;

  McpRuntimeManager get mcpRuntimeManager => _mcpRuntimeManager;
  McpOAuthService get mcpOAuthService => _mcpOAuthService;

  String get _sanadHome => _getSanadHome();
  String? get _currentWorkspacePath => _getCurrentWorkspacePath();

  Future<List<Map<String, dynamic>>> listMcpServers({
    String? workspaceId,
  }) async {
    final snapshot = await readMcpSnapshot(workspaceId: workspaceId);
    final effectiveSection =
        snapshot['effective'] as Map<String, dynamic>? ?? const {};
    final servers = effectiveSection['servers'] as List<dynamic>? ?? const [];
    return servers
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> readMcpSnapshot({String? workspaceId}) async {
    final workspace =
        workspaceId == null ? null : _getWorkspaceRecordById(workspaceId);
    final resolvedWorkspaceId = workspace?['id'] as String?;
    final resolvedWorkspacePath =
        workspaceId == null ? null : await _resolveWorkspacePathById(workspaceId);
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final globalDocument = await settingsStore.readUserMcpConfigDocument();
    final globalServers = settingsStore.parseMcpServersDocument(globalDocument);
    final workspaceDocument =
        resolvedWorkspacePath == null
            ? const <String, dynamic>{}
            : await settingsStore.readWorkspaceMcpConfigDocument(
                resolvedWorkspacePath,
              );
    final workspaceServers =
        resolvedWorkspacePath == null
            ? const <McpServerConfig>[]
            : settingsStore.parseMcpServersDocument(workspaceDocument);
    final effectiveServers = await settingsStore.readEffectiveMcpServers(
      workspacePath: resolvedWorkspacePath,
    );
    final effectiveDocument = settingsStore.encodeMcpSnapshotDocument(
      effectiveServers,
    );
    final workspaceOverrides = workspaceServers
        .map((server) => server.name.trim().toLowerCase())
        .toSet();

    return {
      'workspace_id': resolvedWorkspaceId,
      'global': {
        'scope': 'global',
        'document': settingsStore.encodeMcpSnapshotDocument(globalServers),
        'servers': globalServers
            .map(
              (server) => _encodeMcpServerEntry(
                server: server,
                source: 'global',
                workspaceId: resolvedWorkspaceId,
              ),
            )
            .toList(growable: false),
      },
      'workspace': {
        'scope': 'workspace',
        'document': settingsStore.encodeMcpSnapshotDocument(workspaceServers),
        'servers': workspaceServers
            .map(
              (server) => _encodeMcpServerEntry(
                server: server,
                source: 'workspace',
                workspaceId: resolvedWorkspaceId,
              ),
            )
            .toList(growable: false),
      },
      'effective': {
        'scope': 'effective',
        'document': effectiveDocument.isEmpty
            ? {'mcpServers': <String, dynamic>{}}
            : effectiveDocument,
        'servers': effectiveServers
            .map(
              (server) => _encodeMcpServerEntry(
                server: server,
                source:
                    workspaceOverrides.contains(
                          server.name.trim().toLowerCase(),
                        )
                        ? 'workspace'
                        : 'global',
                workspaceId: resolvedWorkspaceId,
              ),
            )
            .toList(growable: false),
      },
    };
  }

  Future<Map<String, dynamic>> saveMcpServer({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> config,
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final normalizedScope = _normalizeMcpScope(scope);
    final resolvedWorkspacePath = await _resolveWorkspacePathForMcpMutation(
      scope: normalizedScope,
      workspaceId: workspaceId,
    );
    final currentDocument = await _readMcpDocumentForScope(
      settingsStore: settingsStore,
      scope: normalizedScope,
      workspacePath: resolvedWorkspacePath,
    );
    final servers = settingsStore
        .parseMcpServersDocument(currentDocument)
        .toList(growable: true);
    final normalizedConfig = Map<String, dynamic>.from(config);
    final secretMutations = Map<String, dynamic>.from(
      normalizedConfig.remove('_secretMutations') as Map? ?? const {},
    );
    var server = McpServerConfig.fromJson(normalizedConfig);
    final serverKey = server.name.trim().toLowerCase();
    final existingIndex = servers.indexWhere(
      (entry) => entry.name.trim().toLowerCase() == serverKey,
    );
    if (existingIndex >= 0) {
      final existing = servers[existingIndex];
      server = server.copyWith(
        bearerTokenRef: existing.bearerTokenRef,
        secretEnv: {...existing.secretEnv, ...server.secretEnv},
        secretHeaders: {...existing.secretHeaders, ...server.secretHeaders},
        oauthClientSecretRef: existing.oauthClientSecretRef,
        oauthAccessTokenRef: existing.oauthAccessTokenRef,
        oauthRefreshTokenRef: existing.oauthRefreshTokenRef,
      );
    }
    server = await settingsStore.applySecretMutations(server, secretMutations);
    const McpConfigCodec().validate(server);

    if (existingIndex >= 0) {
      servers[existingIndex] = server;
    } else {
      servers.add(server);
    }

    await _writeMcpDocumentForScope(
      settingsStore: settingsStore,
      scope: normalizedScope,
      workspacePath: resolvedWorkspacePath,
      document: settingsStore.encodeMcpServersDocument(servers),
    );

    return readMcpSnapshot(workspaceId: workspaceId);
  }

  Future<Map<String, dynamic>> deleteMcpServer({
    required String scope,
    String? workspaceId,
    required String serverName,
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final normalizedScope = _normalizeMcpScope(scope);
    final resolvedWorkspacePath = await _resolveWorkspacePathForMcpMutation(
      scope: normalizedScope,
      workspaceId: workspaceId,
    );
    final currentDocument = await _readMcpDocumentForScope(
      settingsStore: settingsStore,
      scope: normalizedScope,
      workspacePath: resolvedWorkspacePath,
    );
    final servers =
        settingsStore
            .parseMcpServersDocument(currentDocument)
            .toList(growable: true)
          ..removeWhere(
            (entry) =>
                entry.name.trim().toLowerCase() ==
                serverName.trim().toLowerCase(),
          );

    await _writeMcpDocumentForScope(
      settingsStore: settingsStore,
      scope: normalizedScope,
      workspacePath: resolvedWorkspacePath,
      document: settingsStore.encodeMcpServersDocument(servers),
    );

    return readMcpSnapshot(workspaceId: workspaceId);
  }

  Future<String> mcpMutationFingerprint({
    required String operation,
    required String scope,
    String? workspaceId,
    String? serverName,
    Map<String, dynamic> intent = const {},
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final fingerprintScope = scope.trim().toLowerCase() == 'workspace'
        ? 'workspace'
        : 'global';
    Map<String, dynamic> document;
    try {
      final workspacePath = await _resolveWorkspacePathForMcpMutation(
        scope: fingerprintScope,
        workspaceId: workspaceId,
      );
      document = await _readMcpDocumentForScope(
        settingsStore: settingsStore,
        scope: fingerprintScope,
        workspacePath: workspacePath,
      );
    } catch (_) {
      document = const {'mcpServers': <String, dynamic>{}};
    }
    final revision = const McpConfigCodec().revisionFor(document);
    return '$operation|$fingerprintScope|${serverName ?? ''}|$revision|${jsonEncode(intent)}';
  }

  Future<Map<String, dynamic>> replaceMcpConfig({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> document,
  }) async {
    throw const FormatException(
      'Whole-document MCP replacement is disabled. Use reviewed server mutations.',
    );
  }

  Map<String, dynamic> previewMcpImport(String input) =>
      const McpConfigCodec().previewImport(input).toJson();

  Future<Map<String, dynamic>> exportMcpServers({
    required List<String> serverNames,
    String scope = 'effective',
    String? workspaceId,
  }) async {
    if (serverNames.isEmpty) {
      throw const FormatException('Select at least one MCP server to export.');
    }
    final servers = await _serversForScope(
      scope: scope,
      workspaceId: workspaceId,
    );
    final selected = servers
        .where(
          (server) => serverNames.any(
            (name) =>
                name.trim().toLowerCase() == server.name.trim().toLowerCase(),
          ),
        )
        .toList(growable: false);
    if (selected.length != serverNames.length) {
      throw StateError('One or more selected MCP servers were not found.');
    }
    return {
      'json': const McpConfigCodec().exportServers(selected),
      'credentials_excluded': true,
    };
  }

  Future<Map<String, dynamic>> readAdvancedMcpServer({
    required String serverName,
    required String scope,
    String? workspaceId,
  }) async {
    final server = await _serverForScope(
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
    );
    final codec = const McpConfigCodec();
    final json = codec.advancedJson(server);
    return {
      'server_name': server.name,
      'json': json,
      'base_revision': codec.previewImport(json).revision,
      'credentials_excluded': true,
    };
  }

  Future<Map<String, dynamic>> previewAdvancedMcpServer({
    required String serverName,
    required String scope,
    required String input,
    String? workspaceId,
  }) async {
    final current = await _serverForScope(
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
    );
    return const McpConfigCodec()
        .previewAdvanced(serverName: serverName, current: current, input: input)
        .toJson();
  }

  Future<Map<String, dynamic>> saveAdvancedMcpServer({
    required String serverName,
    required String scope,
    required String input,
    required String baseRevision,
    required String previewRevision,
    String? workspaceId,
  }) async {
    final current = await _serverForScope(
      serverName: serverName,
      scope: scope,
      workspaceId: workspaceId,
    );
    final codec = const McpConfigCodec();
    final currentRevision = codec
        .previewImport(codec.advancedJson(current))
        .revision;
    if (currentRevision != baseRevision) {
      throw StateError(
        'The MCP server changed after editing began. Reload and retry.',
      );
    }
    final preview = codec.previewAdvanced(
      serverName: serverName,
      current: current,
      input: input,
    );
    if (preview.revision != previewRevision) {
      throw StateError('Advanced JSON no longer matches the reviewed preview.');
    }
    final candidate = preview.servers.single;
    return saveMcpServer(
      scope: scope,
      workspaceId: workspaceId,
      config: {'name': candidate.name, ...candidate.toConfigJson()},
    );
  }

  Future<Map<String, dynamic>> startMcpOAuth({
    required String serverName,
    required Map<String, dynamic> draftConfig,
    Map<String, dynamic> secretMutations = const {},
  }) async {
    final config = McpServerConfig.fromJson({
      'name': serverName,
      ...draftConfig,
    });
    final oauth = _runtimeStringMap(secretMutations['oauth']);
    return _mcpOAuthService.start(
      config: config,
      clientSecret: oauth['client_secret'],
    );
  }

  Map<String, dynamic> mcpOAuthStatus(String flowId) =>
      _mcpOAuthService.status(flowId);

  Future<Map<String, dynamic>> cancelMcpOAuth(String flowId) =>
      _mcpOAuthService.cancel(flowId);

  Future<Map<String, dynamic>> completeMcpOAuth({
    required String flowId,
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> config,
  }) async {
    final grant = _mcpOAuthService.consumeApproved(flowId);
    final normalized = Map<String, dynamic>.from(config);
    normalized['oauth'] = {
      ...Map<String, dynamic>.from(normalized['oauth'] as Map? ?? const {}),
      'clientId': grant.clientId,
      'authorizationUrl': grant.authorizationUrl,
      'tokenUrl': grant.tokenUrl,
      if (grant.expiresIn != null)
        'tokenExpiry': DateTime.now()
            .add(Duration(seconds: grant.expiresIn!))
            .toUtc()
            .toIso8601String(),
    };
    normalized['_secretMutations'] = {
      'oauth': {
        'access_token': grant.accessToken,
        if (grant.refreshToken != null) 'refresh_token': grant.refreshToken,
        if (grant.clientSecret != null) 'client_secret': grant.clientSecret,
      },
    };
    return saveMcpServer(
      scope: scope,
      workspaceId: workspaceId,
      config: normalized,
    );
  }

  Future<Map<String, dynamic>> inspectMcpServer({
    required String serverName,
    String scope = 'effective',
    String? workspaceId,
  }) => inspectMcpDraft(
    serverName: serverName,
    scope: scope,
    workspaceId: workspaceId,
  );

  Future<Map<String, dynamic>> inspectMcpDraft({
    required String serverName,
    String scope = 'effective',
    String? workspaceId,
    Map<String, dynamic>? draftConfig,
    Map<String, dynamic> secretMutations = const {},
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final normalizedScope = _normalizeMcpScope(scope);
    final resolvedWorkspaceId = workspaceId == null
        ? null
        : _getWorkspaceRecordById(workspaceId)?['id'] as String?;
    final resolvedWorkspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePathById(workspaceId);
    final servers = switch (normalizedScope) {
      'global' => await settingsStore.readUserMcpServers(),
      'workspace' =>
        resolvedWorkspacePath == null
            ? const <McpServerConfig>[]
            : await settingsStore.readWorkspaceMcpServers(
                resolvedWorkspacePath,
              ),
      _ => await settingsStore.readEffectiveMcpServers(
        workspacePath: resolvedWorkspacePath,
      ),
    };

    final existing = servers
        .where(
          (entry) =>
              entry.name.trim().toLowerCase() ==
              serverName.trim().toLowerCase(),
        )
        .firstOrNull;
    McpServerConfig? server;
    Map<String, String>? transientHeaders;
    Map<String, String>? transientEnvironment;
    if (draftConfig != null) {
      server = McpServerConfig.fromJson({'name': serverName, ...draftConfig});
      if (existing != null) {
        server = server.copyWith(
          bearerTokenRef: existing.bearerTokenRef,
          secretEnv: existing.secretEnv,
          secretHeaders: existing.secretHeaders,
          oauthClientSecretRef: existing.oauthClientSecretRef,
          oauthAccessTokenRef: existing.oauthAccessTokenRef,
          oauthRefreshTokenRef: existing.oauthRefreshTokenRef,
        );
      }
      final transientBearer = secretMutations['bearer_token'];
      const McpConfigCodec().validate(
        server,
        allowMissingBearer:
            transientBearer is String && transientBearer.isNotEmpty,
      );
      transientHeaders = {
        ...settingsStore.resolveHeaders(server),
        ..._runtimeStringMap(secretMutations['secret_headers']),
        if (transientBearer is String && transientBearer.isNotEmpty)
          'Authorization': 'Bearer $transientBearer',
      };
      transientEnvironment = {
        ...settingsStore.resolveEnvironment(server),
        ..._runtimeStringMap(secretMutations['secret_env']),
      };
    } else {
      server = existing;
    }
    if (server == null) {
      throw StateError("MCP server '$serverName' not found.");
    }

    final result = await _mcpRuntimeManager.verifyMcpConnection(
      server,
      resolvedHeaders: transientHeaders,
      resolvedEnvironment: transientEnvironment,
    );
    return {
      'name': server.name,
      'scope': normalizedScope,
      'workspace_id': resolvedWorkspaceId,
      'success': result.success,
      if (result.transport != null) 'transport': result.transport!.name,
      'auth_state': result.authState,
      if (result.error != null) 'error': result.error,
      'tools': (result.tools ?? const <Tool>[])
          .map(
            (tool) => {
              'name': tool.name,
              'description': tool.description,
              'input_schema': Map<String, dynamic>.from(tool.inputSchema),
            },
          )
          .toList(growable: false),
    };
  }

  Future<List<McpServerConfig>> _serversForScope({
    required String scope,
    String? workspaceId,
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final normalizedScope = _normalizeMcpScope(scope);
    final workspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePathById(workspaceId);
    return switch (normalizedScope) {
      'global' => settingsStore.readUserMcpServers(),
      'workspace' =>
        workspacePath == null
            ? Future.value(const <McpServerConfig>[])
            : settingsStore.readWorkspaceMcpServers(workspacePath),
      _ => settingsStore.readEffectiveMcpServers(workspacePath: workspacePath),
    };
  }

  Future<McpServerConfig> _serverForScope({
    required String serverName,
    required String scope,
    String? workspaceId,
  }) async {
    final normalizedName = serverName.trim().toLowerCase();
    final server =
        (await _serversForScope(scope: scope, workspaceId: workspaceId))
            .where((entry) => entry.name.trim().toLowerCase() == normalizedName)
            .firstOrNull;
    if (server == null) throw StateError("MCP server '$serverName' not found.");
    return server;
  }

  Map<String, dynamic> _encodeMcpServerEntry({
    required McpServerConfig server,
    required String source,
    required String? workspaceId,
  }) {
    return {
      'name': server.name,
      'source': source,
      'workspace_id': workspaceId,
      'config': server.toSnapshotJson(),
    };
  }

  String _normalizeMcpScope(String scope) {
    final normalized = scope.trim().toLowerCase();
    switch (normalized) {
      case 'global':
      case 'workspace':
      case 'effective':
        return normalized;
      default:
        throw FormatException('Unsupported MCP scope: $scope');
    }
  }

  Future<String?> _resolveWorkspacePathForMcpMutation({
    required String scope,
    required String? workspaceId,
  }) async {
    if (scope != 'workspace') {
      return workspaceId == null
          ? null
          : _resolveWorkspacePathById(workspaceId);
    }

    final resolvedWorkspacePath = workspaceId == null
        ? await _resolveWorkspacePath(_currentWorkspacePath ?? '')
        : await _resolveWorkspacePathById(workspaceId);
    if (resolvedWorkspacePath == null) {
      throw StateError('Workspace scope requires a selected workspace.');
    }
    return resolvedWorkspacePath;
  }

  Future<Map<String, dynamic>> _readMcpDocumentForScope({
    required SanadSettingsStore settingsStore,
    required String scope,
    required String? workspacePath,
  }) async {
    switch (scope) {
      case 'global':
        return settingsStore.readUserMcpConfigDocument();
      case 'workspace':
        return settingsStore.readWorkspaceMcpConfigDocument(workspacePath!);
      default:
        throw const FormatException('Effective MCP scope is read-only.');
    }
  }

  Future<void> _writeMcpDocumentForScope({
    required SanadSettingsStore settingsStore,
    required String scope,
    required String? workspacePath,
    required Map<String, dynamic> document,
  }) async {
    switch (scope) {
      case 'global':
        await settingsStore.saveUserMcpConfigDocument(document);
        return;
      case 'workspace':
        await settingsStore.saveWorkspaceMcpConfigDocument(
          workspacePath!,
          document,
        );
        return;
      default:
        throw const FormatException('Effective MCP scope is read-only.');
    }
  }

  Map<String, String> _runtimeStringMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value.toString()));
  }
}
