import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
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
       _sessionDb = sessionDb;

  final String? _sanadHomePath;
  final String? _currentWorkingDirectory;
  final SkillRegistry _skillRegistry;
  final SkillLoadService _skillLoadService;
  final McpRuntimeManager _mcpRuntimeManager;
  final SessionDB? _sessionDb;
  SessionDB? _localDb;
  AgentStateDatabase? _localStateDb;

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
      'command': 'model',
      'description':
          'Change or inspect the active model for the current thread.',
    },
    {
      'command': 'think',
      'description': 'Adjust thinking mode for the next local turn.',
    },
    {
      'command': 'workspace',
      'description': 'Inspect or switch the active workspace context.',
    },
    {
      'command': 'mcp',
      'description': 'Inspect configured MCP servers for the local runtime.',
    },
    {
      'command': 'sessions',
      'description': 'Browse local conversation threads.',
    },
    {'command': 'stop', 'description': 'Stop the current run.'},
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
  }) async {
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

  Future<Map<String, dynamic>> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) async {
    final normalizedId = workspaceId.trim();
    if (_db.getWorkspaceById(normalizedId) == null) {
      throw StateError('Workspace not found.');
    }
    final normalizedPath = _normalizeExistingDirectory(
      newPath,
      label: 'Workspace directory',
    );
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

  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
  }) async {
    final trimmedPath = path?.trim();
    if (trimmedPath == null || trimmedPath.isEmpty) {
      if (workspaceId != null && workspaceId.trim().isNotEmpty) {
        final workspace = _workspaceRecord(workspaceId);
        final resolvedWorkspacePath = await _resolveWorkspacePath(workspaceId);
        if (workspace == null || resolvedWorkspacePath == null) {
          throw StateError('Workspace not found or its folder is unavailable.');
        }
        return _buildDirectorySnapshot(
          directory: Directory(resolvedWorkspacePath),
          workspaceId: workspace['id'] as String,
          rootPath: resolvedWorkspacePath,
          path: resolvedWorkspacePath,
          parentPath: null,
          maxEntries: maxEntries,
        );
      }
      return _browseSystemRoots(maxEntries: maxEntries);
    }

    final requestedPath = _normalizePath(trimmedPath);
    var workspacePath = '';
    var rootPath = _rootPathFor(requestedPath);
    var parentPath = _parentPathFor(requestedPath, rootPath: rootPath);

    if (workspaceId != null && workspaceId.trim().isNotEmpty) {
      final workspace = _workspaceRecord(workspaceId);
      final resolvedWorkspacePath = await _resolveWorkspacePath(workspaceId);
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
        : _workspaceRecord(workspaceId);
    final resolvedWorkspaceId = workspace?['id'] as String?;
    final resolvedWorkspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePath(workspaceId);
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
    final effectiveDocument = settingsStore.encodeMcpServersDocument(
      effectiveServers,
    );
    final workspaceOverrides = workspaceServers
        .map((server) => server.name.trim().toLowerCase())
        .toSet();

    return {
      'workspace_id': resolvedWorkspaceId,
      'global': {
        'scope': 'global',
        'document': globalDocument.isEmpty
            ? {'mcpServers': <String, dynamic>{}}
            : globalDocument,
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
        'document': workspaceDocument.isEmpty
            ? {'mcpServers': <String, dynamic>{}}
            : workspaceDocument,
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
    final server = McpServerConfig.fromJson(Map<String, dynamic>.from(config));
    final serverKey = server.name.trim().toLowerCase();
    final existingIndex = servers.indexWhere(
      (entry) => entry.name.trim().toLowerCase() == serverKey,
    );

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
    final servers = settingsStore.parseMcpServersDocument(currentDocument)
      ..removeWhere(
        (entry) =>
            entry.name.trim().toLowerCase() == serverName.trim().toLowerCase(),
      );

    await _writeMcpDocumentForScope(
      settingsStore: settingsStore,
      scope: normalizedScope,
      workspacePath: resolvedWorkspacePath,
      document: settingsStore.encodeMcpServersDocument(servers),
    );

    return readMcpSnapshot(workspaceId: workspaceId);
  }

  Future<Map<String, dynamic>> replaceMcpConfig({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> document,
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final normalizedScope = _normalizeMcpScope(scope);
    final resolvedWorkspacePath = await _resolveWorkspacePathForMcpMutation(
      scope: normalizedScope,
      workspaceId: workspaceId,
    );
    final normalizedDocument = Map<String, dynamic>.from(document);

    settingsStore.parseMcpServersDocument(normalizedDocument);
    await _writeMcpDocumentForScope(
      settingsStore: settingsStore,
      scope: normalizedScope,
      workspacePath: resolvedWorkspacePath,
      document: normalizedDocument,
    );

    return readMcpSnapshot(workspaceId: workspaceId);
  }

  Future<Map<String, dynamic>> inspectMcpServer({
    required String serverName,
    String scope = 'effective',
    String? workspaceId,
  }) async {
    final settingsStore = SanadSettingsStore(homeDirectoryPath: _sanadHome);
    final normalizedScope = _normalizeMcpScope(scope);
    final resolvedWorkspaceId = workspaceId == null
        ? null
        : _workspaceRecord(workspaceId)?['id'] as String?;
    final resolvedWorkspacePath = workspaceId == null
        ? null
        : await _resolveWorkspacePath(workspaceId);
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

    final server = servers
        .where(
          (entry) =>
              entry.name.trim().toLowerCase() ==
              serverName.trim().toLowerCase(),
        )
        .firstOrNull;
    if (server == null) {
      throw StateError("MCP server '$serverName' not found.");
    }

    final result = await _mcpRuntimeManager.verifyMcpConnection(server);
    return {
      'name': server.name,
      'scope': normalizedScope,
      'workspace_id': resolvedWorkspaceId,
      'success': result.success,
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
    String? args,
    String? workspaceId,
    String? workspacePath,
  }) async {
    final resolvedWorkspacePath =
        workspacePath ??
        (workspaceId == null ? null : await _resolveWorkspacePath(workspaceId));
    return _skillLoadService.load(
      skill: skill,
      args: args,
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
      if (entry != null) {
        items.add(entry);
      }
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

  Map<String, dynamic> _encodeMcpServerEntry({
    required McpServerConfig server,
    required String source,
    required String? workspaceId,
  }) {
    return {
      'name': server.name,
      'source': source,
      'workspace_id': workspaceId,
      'config': server.toConfigJson(),
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
      return workspaceId == null ? null : _resolveWorkspacePath(workspaceId);
    }

    final resolvedWorkspacePath = await _resolveWorkspacePath(
      workspaceId ?? _currentWorkspacePath,
    );
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
  }) async {
    final folderName = _validateFolderName(name);
    final normalizedParent = _normalizeExistingDirectory(
      parentPath,
      label: 'Parent directory',
    );
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
  }

  Future<String> renameFolder({
    required String path,
    required String newName,
  }) async {
    final sourcePath = await _validateMutableDirectory(path);
    final folderName = _validateFolderName(newName);
    final targetPath = p.normalize(p.join(p.dirname(sourcePath), folderName));
    if (targetPath == sourcePath) {
      return sourcePath;
    }
    if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('A file or folder with that name already exists.');
    }

    final renamed = await Directory(sourcePath).rename(targetPath);
    return _normalizePath(renamed.path);
  }

  Future<String> deleteFolder(String path) async {
    final targetPath = await _validateMutableDirectory(path);
    await Directory(targetPath).delete(recursive: true);
    return targetPath;
  }

  String _validateFolderName(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\')) {
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

  Future<String> _validateMutableDirectory(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Folder path is required.');
    }
    final type = await FileSystemEntity.type(trimmed, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError('Symbolic-link folders cannot be changed here.');
    }
    if (type != FileSystemEntityType.directory) {
      throw StateError('Folder does not exist or is not a directory.');
    }

    final normalized = _normalizePath(trimmed);
    if (_isFileSystemRoot(normalized)) {
      throw StateError('Filesystem roots cannot be renamed or deleted.');
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
}
