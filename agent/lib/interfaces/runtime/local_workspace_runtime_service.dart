import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/mcp/mcp_config_codec.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_oauth_service.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_boundary.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

class LocalWorkspaceRuntimeService {
  LocalWorkspaceRuntimeService({
    String? sanadHomePath,
    String? currentWorkingDirectory,
    SkillRegistry? skillRegistry,
    SkillLoadService? skillLoadService,
    McpRuntimeManager? mcpRuntimeManager,
    McpOAuthService? mcpOAuthService,
    SessionDB? sessionDb,
  }) : _sanadHomePath = sanadHomePath,
       _currentWorkingDirectory = currentWorkingDirectory,
       _skillRegistry = skillRegistry ?? const SkillRegistry(),
       _skillLoadService =
           skillLoadService ??
           SkillLoadService(registry: skillRegistry ?? const SkillRegistry()),
       _mcpRuntimeManager =
           mcpRuntimeManager ??
           McpRuntimeManager(
             settingsStore: SanadSettingsStore(
               homeDirectoryPath: sanadHomePath,
             ),
           ),
       _mcpOAuthService = mcpOAuthService ?? McpOAuthService(),
       _sessionDb = sessionDb;

  final String? _sanadHomePath;
  final String? _currentWorkingDirectory;
  final SkillRegistry _skillRegistry;
  final SkillLoadService _skillLoadService;
  final McpRuntimeManager _mcpRuntimeManager;
  final McpOAuthService _mcpOAuthService;
  final SessionDB? _sessionDb;
  SessionDB? _localDb;
  AgentStateDatabase? _localStateDb;
  Future<void> _mutationTail = Future<void>.value();

  SessionDB get _db {
    if (_sessionDb != null) return _sessionDb;
    try {
      if (getIt.isRegistered<SessionManager>()) {
        return getIt<SessionManager>().db;
      }
    } catch (_) {}
    final localState = _localStateDb ??= AgentStateDatabase.atPath(_sanadHome);
    return _localDb ??= SessionDB.fromState(localState);
  }

  static const List<Map<String, String>> _defaultSlashCommands = [
    {
      'command': 'compact',
      'description':
          'Compact conversation context while preserving the current goal.',
      'type': 'runtime_command',
    },
  ];

  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    final items = (await _readStoredWorkspaces())
        .map(_workspacePayload)
        .toList(growable: false);
    items.sort((left, right) {
      final leftCurrent = left['is_current'] == true ? 0 : 1;
      final rightCurrent = right['is_current'] == true ? 0 : 1;
      if (leftCurrent != rightCurrent) {
        return leftCurrent.compareTo(rightCurrent);
      }
      return (left['name'] as String).toLowerCase().compareTo(
        (right['name'] as String).toLowerCase(),
      );
    });
    return items;
  }

  Future<Map<String, dynamic>> createWorkspace({
    String? name,
    String? path,
    String? description,
    bool managedRemote = false,
  }) async {
    if (managedRemote) {
      return _createManagedRemoteWorkspace(
        name: name,
        path: path,
        description: description,
      );
    }
    final trimmedPath = path?.trim();
    final trimmedName = name?.trim() ?? '';
    final effectiveName = trimmedName.isNotEmpty
        ? trimmedName
        : _workspaceNameFromPath(trimmedPath);
    if (effectiveName == null || effectiveName.isEmpty) {
      throw const FormatException(
        'Workspace name or a valid target path is required.',
      );
    }

    final targetPath = _normalizePath(
      trimmedPath == null || trimmedPath.isEmpty
          ? p.join(_currentWorkspacePath, effectiveName)
          : trimmedPath,
    );
    final directory = Directory(targetPath);
    final existed = await directory.exists();
    if (!existed) {
      await directory.create(recursive: true);
    }
    final stored = await _storeWorkspace(
      targetPath,
      source: existed ? 'existing' : 'created',
      displayName: trimmedName.isEmpty ? null : trimmedName,
    );
    return _workspacePayload(stored);
  }

  Future<Map<String, dynamic>?> describeWorkspace(
    String workspaceIdOrPath,
  ) async {
    final workspace = _workspaceRecord(workspaceIdOrPath);
    return workspace == null ? null : _workspacePayload(workspace);
  }

  Future<Map<String, dynamic>?> describeWorkspaceById(
    String workspaceId,
  ) async {
    final normalizedId = workspaceId.trim();
    if (normalizedId.isEmpty) return null;
    final workspace = _db.getWorkspaceById(normalizedId);
    return workspace == null ? null : _workspacePayload(workspace);
  }

  Future<Map<String, dynamic>> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) async {
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty) {
      throw const FormatException('Workspace name is required.');
    }
    final workspace = _db.renameWorkspace(workspaceId.trim(), normalizedName);
    if (workspace == null) throw StateError('Workspace not found.');
    return _workspacePayload(workspace);
  }

  Future<String> removeWorkspace({
    required String workspaceId,
    bool managedRemote = false,
  }) async {
    final normalizedId = workspaceId.trim();
    if (normalizedId.isEmpty) {
      throw const FormatException('Workspace id is required.');
    }
    if (!_db.removeWorkspace(normalizedId)) {
      throw StateError('Workspace not found.');
    }
    return normalizedId;
  }

  Future<Map<String, dynamic>> relocateWorkspace({
    required String workspaceId,
    required String newPath,
    bool managedRemote = false,
    String? expectedFingerprint,
  }) async {
    if (managedRemote) {
      return _serialized(() async {
        final preview = await previewRelocateWorkspace(
          workspaceId: workspaceId,
          newPath: newPath,
        );
        if (expectedFingerprint != null &&
            expectedFingerprint != preview.fingerprint) {
          throw const WorkspaceCommandException(
            WorkspaceCommandErrorCodes.staleConfirmation,
            'The confirmation ticket is stale or does not match.',
          );
        }
        return _relocateWorkspaceUnchecked(
          workspaceId: workspaceId,
          newPath: newPath,
          managedRemote: true,
        );
      });
    }
    return _relocateWorkspaceUnchecked(
      workspaceId: workspaceId,
      newPath: newPath,
      managedRemote: false,
    );
  }

  Future<WorkspaceMutationPreview> previewRelocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) async {
    final normalizedId = workspaceId.trim();
    if (_db.getWorkspaceById(normalizedId) == null) {
      throw StateError('Workspace not found.');
    }
    final normalizedPath = await _requireAllowedExistingDirectory(
      newPath,
      label: 'Workspace directory',
    );
    return WorkspaceMutationPreview(
      operation: CanonicalEventTypes.relocateWorkspace,
      path: normalizedPath,
      fingerprint: _fingerprint(
        operation: CanonicalEventTypes.relocateWorkspace,
        path: '$normalizedId|$normalizedPath',
        extra: normalizedId,
      ),
      summary: 'Change this workspace folder to the selected allowed path.',
      entryCount: 0,
      truncated: false,
    );
  }

  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
    bool managedRemote = false,
  }) async {
    final trimmedPath = path?.trim();
    if (trimmedPath == null || trimmedPath.isEmpty) {
      if (workspaceId != null && workspaceId.trim().isNotEmpty) {
        final workspace = _workspaceRecordById(workspaceId);
        final resolvedWorkspacePath = await _resolveWorkspacePathById(
          workspaceId,
        );
        if (workspace == null || resolvedWorkspacePath == null) {
          throw StateError('Workspace not found or its folder is unavailable.');
        }
        if (managedRemote) {
          await _assertAllowedRemotePath(resolvedWorkspacePath);
        }
        return _buildDirectorySnapshot(
          directory: Directory(resolvedWorkspacePath),
          workspaceId: workspace['id'] as String,
          rootPath: resolvedWorkspacePath,
          path: resolvedWorkspacePath,
          parentPath: null,
          maxEntries: maxEntries,
          hideInternal: managedRemote,
        );
      }
      if (managedRemote) {
        return _browseAllowedRemoteRoots(maxEntries: maxEntries);
      }
      return _browseSystemRoots(maxEntries: maxEntries);
    }

    _rejectUnsafePathString(trimmedPath);
    final requestedPath = _normalizePath(trimmedPath);
    var workspacePath = '';
    var rootPath = _rootPathFor(requestedPath);
    var parentPath = _parentPathFor(requestedPath, rootPath: rootPath);

    if (managedRemote) {
      await _assertAllowedRemotePath(requestedPath);
      final allowedRoot = await _containingAllowedRoot(requestedPath);
      rootPath = allowedRoot ?? requestedPath;
      parentPath = requestedPath == rootPath
          ? null
          : _parentPathFor(requestedPath, rootPath: rootPath);
    }

    if (workspaceId != null && workspaceId.trim().isNotEmpty) {
      final workspace = _workspaceRecordById(workspaceId);
      final resolvedWorkspacePath = await _resolveWorkspacePathById(
        workspaceId,
      );
      if (workspace == null || resolvedWorkspacePath == null) {
        throw StateError('Workspace not found or its folder is unavailable.');
      }
      if (!_isWithinRoot(root: resolvedWorkspacePath, target: requestedPath)) {
        throw StateError('Requested path is outside the selected workspace.');
      }
      workspacePath = workspace['id'] as String;
      rootPath = resolvedWorkspacePath;
      parentPath = _parentPathFor(
        requestedPath,
        rootPath: resolvedWorkspacePath,
      );
    }

    final directory = Directory(requestedPath);
    if (!await directory.exists()) {
      throw StateError('Requested directory does not exist.');
    }

    return _buildDirectorySnapshot(
      directory: directory,
      workspaceId: workspacePath,
      rootPath: rootPath,
      path: requestedPath,
      parentPath: parentPath,
      maxEntries: maxEntries,
      hideInternal: managedRemote,
    );
  }

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
    final workspace = workspaceId == null
        ? null
        : _workspaceRecordById(workspaceId);
    final resolvedWorkspaceId = workspace?['id'] as String?;
    final resolvedWorkspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePathById(workspaceId);
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final globalDocument = await settingsStore.readUserMcpConfigDocument();
    final globalServers = settingsStore.parseMcpServersDocument(globalDocument);
    final workspaceDocument = resolvedWorkspacePath == null
        ? const <String, dynamic>{}
        : await settingsStore.readWorkspaceMcpConfigDocument(
            resolvedWorkspacePath,
          );
    final workspaceServers = resolvedWorkspacePath == null
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
        : _workspaceRecordById(workspaceId)?['id'] as String?;
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

  Future<List<Map<String, dynamic>>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) async {
    final normalizedQuery = query?.trim().toLowerCase() ?? '';
    final workspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePath(workspaceId);
    final skillsReport = await _skillRegistry.list(
      workspacePath: workspacePath,
      includeShadowed: false,
    );
    final skillCommands = skillsReport.skills
        .where((entry) => entry.active)
        .map(
          (entry) => <String, dynamic>{
            'command': entry.name,
            'description': entry.description ?? 'Load the ${entry.name} skill.',
            'source': 'skill',
            'path': entry.path,
          },
        )
        .toList(growable: false);

    final merged = [
      ..._defaultSlashCommands.map(
        (command) => <String, dynamic>{...command, 'source': 'sanad-agent'},
      ),
      ...skillCommands,
    ];

    return merged
        .where((command) {
          if (normalizedQuery.isEmpty) {
            return true;
          }
          final value = '${command['command']} ${command['description']}'
              .toLowerCase();
          return value.contains(normalizedQuery);
        })
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> listSkills({
    String? workspaceId,
    bool includeShadowed = false,
  }) async {
    final workspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePath(workspaceId);
    final report = await _skillRegistry.list(
      workspacePath: workspacePath,
      includeShadowed: includeShadowed,
    );
    return report.toJson();
  }

  Future<String> loadSkill({
    required String skill,
    String? workspaceId,
    String? workspacePath,
  }) async {
    final resolvedWorkspacePath =
        workspacePath ??
        (workspaceId == null ? null : await _resolveWorkspacePath(workspaceId));
    return _skillLoadService.load(
      skill: skill,
      workspacePath: resolvedWorkspacePath,
    );
  }

  Future<Map<String, dynamic>> _storeWorkspace(
    String workspacePath, {
    required String source,
    String? displayName,
  }) async {
    final normalized = _normalizePath(workspacePath);
    return _db.createOrGetWorkspace(
      displayName: displayName,
      path: normalized,
      source: source,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<List<Map<String, dynamic>>> _readStoredWorkspaces() async {
    return _db.getStoredWorkspaces();
  }

  Map<String, dynamic>? _workspaceRecord(String workspaceIdOrPath) {
    final trimmed = workspaceIdOrPath.trim();
    if (trimmed.isEmpty) return null;
    final byId = _db.getWorkspaceById(trimmed);
    if (byId != null) return byId;
    final normalizedPath = _normalizePath(trimmed);
    final byPath = _db.getWorkspaceByPath(normalizedPath);
    if (byPath != null) return byPath;
    if (Directory(normalizedPath).existsSync()) {
      return _db.createOrGetWorkspace(
        path: normalizedPath,
        source: 'legacy_path_request',
      );
    }
    return null;
  }

  Map<String, dynamic>? _workspaceRecordById(String workspaceId) {
    final normalizedId = workspaceId.trim();
    if (normalizedId.isEmpty) return null;
    return _db.getWorkspaceById(normalizedId);
  }

  Map<String, dynamic> _workspacePayload(Map<String, dynamic> workspace) {
    final path = workspace['path'] as String;
    final available = Directory(path).existsSync();
    return {
      'id': workspace['id'],
      'name': workspace['display_name'],
      'display_name': workspace['display_name'],
      'path': path,
      'source': workspace['source'],
      'is_current': available && path == _currentWorkspacePath,
      'is_missing': !available,
      'availability': available ? 'available' : 'missing',
    };
  }

  Future<String?> _resolveWorkspacePath(String workspaceIdOrPath) async {
    final workspace = _workspaceRecord(workspaceIdOrPath);
    if (workspace == null) return null;
    final path = workspace['path'] as String;
    return await Directory(path).exists() ? path : null;
  }

  Future<String?> _resolveWorkspacePathById(String workspaceId) async {
    final workspace = _workspaceRecordById(workspaceId);
    if (workspace == null) return null;
    final path = workspace['path'] as String;
    return await Directory(path).exists() ? path : null;
  }

  Future<Map<String, dynamic>> _browseSystemRoots({
    required int maxEntries,
  }) async {
    if (Platform.isWindows) {
      final roots = await _listWindowsRoots();
      return {
        'workspace_id': '',
        'root_path': '',
        'path': '',
        'parent_path': null,
        'entries': roots.take(maxEntries).toList(growable: false),
        'truncated': roots.length > maxEntries,
      };
    }

    return _buildDirectorySnapshot(
      directory: Directory(Platform.pathSeparator),
      workspaceId: '',
      rootPath: Platform.pathSeparator,
      path: Platform.pathSeparator,
      parentPath: null,
      maxEntries: maxEntries,
    );
  }

  Future<Map<String, dynamic>> _buildDirectorySnapshot({
    required Directory directory,
    required String workspaceId,
    required String rootPath,
    required String path,
    required String? parentPath,
    required int maxEntries,
    bool hideInternal = false,
  }) async {
    final entities = <FileSystemEntity>[];
    await for (final entity in directory.list(followLinks: false)) {
      entities.add(entity);
    }
    entities.sort((left, right) {
      final leftDir = left is Directory ? 0 : 1;
      final rightDir = right is Directory ? 0 : 1;
      if (leftDir != rightDir) {
        return leftDir.compareTo(rightDir);
      }
      return p
          .basename(left.path)
          .toLowerCase()
          .compareTo(p.basename(right.path).toLowerCase());
    });

    final items = <Map<String, dynamic>>[];
    for (final entity in entities.take(maxEntries)) {
      final entry = await _buildTreeEntry(entity, rootPath: rootPath);
      if (entry == null) {
        continue;
      }
      if (hideInternal && _isSanadInternalHidden(entry['path'] as String)) {
        continue;
      }
      items.add(entry);
    }

    return {
      'workspace_id': workspaceId,
      'root_path': rootPath,
      'path': path,
      'parent_path': parentPath,
      'entries': items,
      'truncated': entities.length > maxEntries,
    };
  }

  Future<Map<String, dynamic>?> _buildTreeEntry(
    FileSystemEntity entity, {
    required String rootPath,
  }) async {
    try {
      final stat = await entity.stat();
      final entityPath = _normalizePath(entity.path);
      return {
        'name': _entryDisplayName(entityPath),
        'path': entityPath,
        'relative_path': _relativePathFor(entityPath, rootPath: rootPath),
        'type': entity is Directory ? 'directory' : 'file',
        'size': stat.size,
        'modified_at': stat.modified.toIso8601String(),
      };
    } on FileSystemException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _listWindowsRoots() async {
    final roots = <Map<String, dynamic>>[];
    for (var codeUnit = 65; codeUnit <= 90; codeUnit++) {
      final drivePath = '${String.fromCharCode(codeUnit)}:\\';
      final directory = Directory(drivePath);
      if (!await directory.exists()) {
        continue;
      }
      final entry = await _buildTreeEntry(directory, rootPath: '');
      if (entry != null) {
        roots.add(entry);
      }
    }
    return roots;
  }

  String _rootPathFor(String targetPath) {
    if (Platform.isWindows) {
      return p.rootPrefix(targetPath);
    }
    return Platform.pathSeparator;
  }

  String? _parentPathFor(String targetPath, {required String rootPath}) {
    final normalizedTarget = _normalizePath(targetPath);
    if (rootPath.isNotEmpty) {
      final normalizedRoot = _normalizePath(rootPath);
      if (normalizedTarget == normalizedRoot) {
        return null;
      }

      final parentPath = _normalizePath(
        Directory(normalizedTarget).parent.path,
      );
      if (parentPath == normalizedTarget) {
        return null;
      }
      if (parentPath == normalizedRoot) {
        return normalizedRoot;
      }
      return _isWithinRoot(root: normalizedRoot, target: parentPath)
          ? parentPath
          : normalizedRoot;
    }

    final parentPath = _normalizePath(Directory(normalizedTarget).parent.path);
    return parentPath == normalizedTarget ? null : '';
  }

  String _relativePathFor(String entityPath, {required String rootPath}) {
    if (rootPath.isEmpty) {
      return entityPath;
    }
    return p.relative(entityPath, from: rootPath);
  }

  String _entryDisplayName(String entityPath) {
    final basename = p.basename(entityPath);
    if (basename.isNotEmpty) {
      return basename;
    }
    return entityPath;
  }

  String? _workspaceNameFromPath(String? path) {
    if (path == null || path.isEmpty) {
      return null;
    }

    final trimmedTrailing =
        path.endsWith(Platform.pathSeparator) &&
            path.length > Platform.pathSeparator.length
        ? path.substring(0, path.length - Platform.pathSeparator.length)
        : path;
    final basename = p.basename(trimmedTrailing).trim();
    if (basename.isNotEmpty) {
      return basename;
    }
    return null;
  }

  bool _isWithinRoot({required String root, required String target}) {
    final normalizedRoot = _normalizePath(root);
    final normalizedTarget = _normalizePath(target);
    return normalizedTarget == normalizedRoot ||
        p.isWithin(normalizedRoot, normalizedTarget);
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
        ? await _resolveWorkspacePath(_currentWorkspacePath)
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

  Future<String> createFolder({
    required String parentPath,
    required String name,
    bool managedRemote = false,
  }) async {
    return _serialized(() async {
      final folderName = _validateFolderName(name);
      final normalizedParent = managedRemote
          ? await _requireAllowedExistingDirectory(
              parentPath,
              label: 'Parent directory',
            )
          : _normalizeExistingDirectory(parentPath, label: 'Parent directory');
      final targetPath = p.normalize(p.join(normalizedParent, folderName));
      if (!p.isWithin(normalizedParent, targetPath)) {
        throw const FormatException(
          'Folder name must stay within the selected parent directory.',
        );
      }
      if (await FileSystemEntity.type(targetPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('A file or folder with that name already exists.');
      }

      await Directory(targetPath).create();
      return _normalizePath(targetPath);
    });
  }

  Future<String> renameFolder({
    required String path,
    required String newName,
    bool managedRemote = false,
  }) async {
    return _serialized(() async {
      final sourcePath = await _validateMutableDirectory(
        path,
        managedRemote: managedRemote,
      );
      final folderName = _validateFolderName(newName);
      final targetPath = p.normalize(p.join(p.dirname(sourcePath), folderName));
      if (targetPath == sourcePath) {
        return sourcePath;
      }
      if (await FileSystemEntity.type(targetPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('A file or folder with that name already exists.');
      }
      if (managedRemote) {
        await _assertAllowedRemotePath(p.dirname(sourcePath));
      }

      final renamed = await Directory(sourcePath).rename(targetPath);
      return _normalizePath(renamed.path);
    });
  }

  Future<WorkspaceMutationPreview> previewDeleteFolder(
    String path, {
    bool managedRemote = false,
  }) async {
    final targetPath = await _validateMutableDirectory(
      path,
      managedRemote: managedRemote,
    );
    final counts = await _countDirectoryEntries(Directory(targetPath));
    final name = p.basename(targetPath);
    return WorkspaceMutationPreview(
      operation: CanonicalEventTypes.deleteFolder,
      path: targetPath,
      fingerprint: _fingerprint(
        operation: CanonicalEventTypes.deleteFolder,
        path: targetPath,
        extra: '${counts.count}:${counts.truncated}',
      ),
      summary:
          'Delete "$name" and ${counts.count}${counts.truncated ? '+' : ''} items inside it. This cannot be undone.',
      entryCount: counts.count,
      truncated: counts.truncated,
    );
  }

  Future<String> deleteFolder(
    String path, {
    bool managedRemote = false,
    String? expectedFingerprint,
  }) async {
    return _serialized(() async {
      if (managedRemote) {
        final preview = await previewDeleteFolder(path, managedRemote: true);
        if (expectedFingerprint != null &&
            expectedFingerprint != preview.fingerprint) {
          throw const WorkspaceCommandException(
            WorkspaceCommandErrorCodes.staleConfirmation,
            'The confirmation ticket is stale or does not match.',
          );
        }
      }
      final targetPath = await _validateMutableDirectory(
        path,
        managedRemote: managedRemote,
      );
      await Directory(targetPath).delete(recursive: true);
      return targetPath;
    });
  }

  String _validateFolderName(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.contains('\u0000')) {
      throw const FormatException('Folder name must be a single path segment.');
    }
    return name;
  }

  String _normalizeExistingDirectory(String value, {required String label}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw FormatException('$label path is required.');
    }
    final type = FileSystemEntity.typeSync(trimmed, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw StateError('$label does not exist or is not a directory.');
    }
    return _normalizePath(trimmed);
  }

  Future<String> _validateMutableDirectory(
    String value, {
    bool managedRemote = false,
  }) async {
    _rejectUnsafePathString(value);
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Folder path is required.');
    }
    final type = await FileSystemEntity.type(trimmed, followLinks: false);
    if (type == FileSystemEntityType.link) {
      if (managedRemote) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Symbolic-link folders cannot be changed here.',
        );
      }
      throw StateError('Symbolic-link folders cannot be changed here.');
    }
    if (type != FileSystemEntityType.directory) {
      throw StateError('Folder does not exist or is not a directory.');
    }

    final normalized = _normalizePath(trimmed);
    if (_isFileSystemRoot(normalized)) {
      throw StateError('Filesystem roots cannot be renamed or deleted.');
    }
    if (managedRemote) {
      await _assertAllowedRemotePath(normalized);
      if (await _isProtectedRemoteRoot(normalized)) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Protected workspace roots cannot be renamed or deleted.',
        );
      }
    }
    return normalized;
  }

  bool _isFileSystemRoot(String path) {
    final parent = _normalizePath(Directory(path).parent.path);
    return parent == path;
  }

  String _normalizePath(String value) {
    final directory = Directory(value);
    try {
      return directory.resolveSymbolicLinksSync();
    } catch (_) {
      return directory.absolute.path;
    }
  }

  String get _sanadHome => _sanadHomePath ?? getSanadHome();

  String get _currentWorkspacePath =>
      _normalizePath(_currentWorkingDirectory ?? Directory.current.path);

  Future<Map<String, dynamic>> _createManagedRemoteWorkspace({
    String? name,
    String? path,
    String? description,
  }) async {
    if (path != null && path.trim().isNotEmpty) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.invalidRequest,
        'Remote workspace creation accepts a name, not a host path.',
      );
    }
    final folderName = _validateFolderName(name ?? '');
    final managedRoot = _ensureManagedWorkspacesRoot();
    final targetPath = p.normalize(p.join(managedRoot, folderName));
    if (!p.isWithin(managedRoot, targetPath)) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'Workspace name must stay inside the managed workspaces root.',
      );
    }
    if (await FileSystemEntity.type(targetPath, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'Symbolic-link folders cannot be used as a workspace.',
      );
    }
    final directory = Directory(targetPath);
    final existed = await directory.exists();
    if (!existed) {
      await directory.create();
    } else if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'A file with that workspace name already exists.',
      );
    }
    final displayName = description?.trim().isNotEmpty == true
        ? description!.trim()
        : folderName;
    final stored = await _storeWorkspace(
      targetPath,
      source: existed ? 'existing' : 'managed_remote',
      displayName: displayName,
    );
    return _workspacePayload(stored);
  }

  Future<Map<String, dynamic>> _relocateWorkspaceUnchecked({
    required String workspaceId,
    required String newPath,
    required bool managedRemote,
  }) async {
    final normalizedId = workspaceId.trim();
    if (_db.getWorkspaceById(normalizedId) == null) {
      throw StateError('Workspace not found.');
    }
    final normalizedPath = managedRemote
        ? await _requireAllowedExistingDirectory(
            newPath,
            label: 'Workspace directory',
          )
        : _normalizeExistingDirectory(newPath, label: 'Workspace directory');
    final owner = _db.getWorkspaceByPath(normalizedPath);
    if (owner != null && owner['id'] != normalizedId) {
      throw StateError(
        'That folder is already connected to another workspace.',
      );
    }
    final workspace = _db.relocateWorkspace(normalizedId, normalizedPath);
    if (workspace == null) throw StateError('Workspace not found.');
    return _workspacePayload(workspace);
  }

  String _ensureManagedWorkspacesRoot() {
    try {
      return SanadHomeBootstrap.atRoot(
        _sanadHome,
        scope: SanadHomeScope.identity,
      ).ensureDirectoryPathSync(
        SanadHomeBootstrap.managedWorkspacesDirectoryName,
      );
    } on SanadHomeBoundaryViolation {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'The managed workspaces root is not available.',
      );
    }
  }

  Future<Map<String, dynamic>> _browseAllowedRemoteRoots({
    required int maxEntries,
  }) async {
    final roots = await _allowedRemoteRoots();
    final entries = <Map<String, dynamic>>[];
    for (final root in roots.take(maxEntries)) {
      final entry = await _buildTreeEntry(Directory(root), rootPath: '');
      if (entry != null && !_isSanadInternalHidden(root)) {
        entries.add(entry);
      }
    }
    return {
      'workspace_id': '',
      'root_path': '',
      'path': '',
      'parent_path': null,
      'entries': entries,
      'truncated': roots.length > maxEntries,
    };
  }

  Future<List<String>> _allowedRemoteRoots() async {
    final roots = <String>{};
    final managed = _normalizePath(_ensureManagedWorkspacesRoot());
    roots.add(managed);
    for (final workspace in await _readStoredWorkspaces()) {
      final path = workspace['path'] as String?;
      if (path == null || path.trim().isEmpty) continue;
      if (!Directory(path).existsSync()) continue;
      final normalized = _normalizePath(path);
      if (_isSanadInternalHidden(normalized)) continue;
      if (_isWithinRoot(root: managed, target: normalized)) continue;
      roots.add(normalized);
    }
    return roots.toList(growable: false);
  }

  Future<String?> _containingAllowedRoot(String path) async {
    final normalized = _normalizePath(path);
    for (final root in await _allowedRemoteRoots()) {
      if (_isWithinRoot(root: root, target: normalized)) {
        return root;
      }
    }
    return null;
  }

  Future<void> _assertAllowedRemotePath(String path) async {
    _rejectUnsafePathString(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'Symbolic-link folders cannot be browsed or changed here.',
      );
    }
    final normalized = _normalizePath(path);
    if (_isSanadInternalHidden(normalized) || _isFileSystemRoot(normalized)) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'That path is outside the allowed workspace roots.',
      );
    }
    if (await _containingAllowedRoot(normalized) == null) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.pathNotAllowed,
        'That path is outside the allowed workspace roots.',
      );
    }
  }

  Future<String> _requireAllowedExistingDirectory(
    String value, {
    required String label,
  }) async {
    _rejectUnsafePathString(value);
    final normalized = _normalizeExistingDirectory(value, label: label);
    await _assertAllowedRemotePath(normalized);
    return normalized;
  }

  Future<bool> _isProtectedRemoteRoot(String path) async {
    final normalized = _normalizePath(path);
    if (normalized == _normalizePath(_ensureManagedWorkspacesRoot())) {
      return true;
    }
    if (normalized == _normalizePath(_sanadHome)) {
      return true;
    }
    final stateHome = _normalizePath(getSanadStateHome());
    if (normalized == stateHome) {
      return true;
    }
    for (final workspace in await _readStoredWorkspaces()) {
      final workspacePath = workspace['path'] as String?;
      if (workspacePath == null) continue;
      if (_normalizePath(workspacePath) == normalized) {
        return true;
      }
    }
    return false;
  }

  bool _isSanadInternalHidden(String path) {
    final normalized = _normalizePath(path);
    final home = _normalizePath(_sanadHome);
    final managed = _normalizePath(
      p.join(home, SanadHomeBootstrap.managedWorkspacesDirectoryName),
    );
    if (normalized == managed ||
        _isWithinRoot(root: managed, target: normalized)) {
      return false;
    }
    if (normalized == home || _isWithinRoot(root: home, target: normalized)) {
      return true;
    }
    final stateHome = _normalizePath(getSanadStateHome());
    if (stateHome != home &&
        (normalized == stateHome ||
            _isWithinRoot(root: stateHome, target: normalized))) {
      return true;
    }
    return false;
  }

  void _rejectUnsafePathString(String value) {
    if (value.contains('\u0000')) {
      throw const FormatException('Invalid path.');
    }
  }

  String _fingerprint({
    required String operation,
    required String path,
    String extra = '',
  }) {
    var modified = '';
    try {
      modified = FileStat.statSync(path).modified.toUtc().toIso8601String();
    } catch (_) {}
    return '$operation|$path|$modified|$extra';
  }

  Future<({int count, bool truncated})> _countDirectoryEntries(
    Directory directory,
  ) async {
    var count = 0;
    const limit = 500;
    try {
      await for (final _ in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        count += 1;
        if (count >= limit) {
          return (count: count, truncated: true);
        }
      }
    } on FileSystemException {
      return (count: count, truncated: false);
    }
    return (count: count, truncated: false);
  }

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final previous = _mutationTail;
    final done = Completer<void>();
    _mutationTail = done.future;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }
}

Map<String, String> _runtimeStringMap(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item.toString()))
    : const {};
