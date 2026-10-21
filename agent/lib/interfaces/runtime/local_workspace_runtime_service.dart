import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/permissions/workspace_security_policy_repository.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_oauth_service.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

import 'workspace_mcp_coordinator.dart';
import 'workspace_file_system_coordinator.dart';

export 'workspace_mcp_coordinator.dart' show WorkspaceMcpCoordinator;
export 'workspace_file_system_coordinator.dart'
    show WorkspaceFileSystemCoordinator;

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
       _ownsMcpRuntimeManager = mcpRuntimeManager == null,
       _ownsMcpOAuthService = mcpOAuthService == null,
       _sessionDb = sessionDb {
    _mcpCoordinator = WorkspaceMcpCoordinator(
      getSanadHome: () => _sanadHome,
      getCurrentWorkspacePath: () => _currentWorkspacePath,
      getWorkspaceRecordById: _workspaceRecordById,
      resolveWorkspacePathById: _resolveWorkspacePathById,
      resolveWorkspacePath: _resolveWorkspacePath,
      mcpRuntimeManager: _mcpRuntimeManager,
      mcpOAuthService: _mcpOAuthService,
    );
    _fsCoordinator = WorkspaceFileSystemCoordinator(
      getSanadHome: () => _sanadHome,
      getWorkspaceRecordById: _workspaceRecordById,
      resolveWorkspacePathById: _resolveWorkspacePathById,
      readStoredWorkspaces: _readStoredWorkspaces,
    );
  }

  /// Releases the workspace resources this service owns.
  ///
  /// Pending filesystem mutations are drained first so a workspace write can
  /// never land after its database or runtime manager has been disposed.
  Future<void> dispose() async {
    await _fsCoordinator.drainMutations();
    if (_ownsMcpRuntimeManager) {
      await _mcpRuntimeManager.dispose();
    }
    if (_ownsMcpOAuthService) {
      await _mcpOAuthService.dispose();
    }
    _localDb?.dispose();
    _localStateDb?.dispose();
    _localDb = null;
    _localStateDb = null;
  }

  final String? _sanadHomePath;
  final String? _currentWorkingDirectory;
  final SkillRegistry _skillRegistry;
  final SkillLoadService _skillLoadService;
  final McpRuntimeManager _mcpRuntimeManager;
  final McpOAuthService _mcpOAuthService;
  final bool _ownsMcpRuntimeManager;
  final bool _ownsMcpOAuthService;
  late final WorkspaceMcpCoordinator _mcpCoordinator;
  late final WorkspaceFileSystemCoordinator _fsCoordinator;
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

  /// The Agent state database that owns this service's workspace records.
  ///
  /// It is always the connection of this service's [SessionDB], so aggregate
  /// mutations (workspace removal with its security policy) commit together.
  AgentStateDatabase get stateDatabase => _db.state;

  static const List<Map<String, String>> _defaultSlashCommands = [
    {
      'command': 'compact',
      'description':
          'Compact conversation context while preserving the current goal.',
      'type': 'runtime_action',
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
    // The workspace record and its security policy (mode, grants) are
    // removed together so a removed workspace leaves no authority behind.
    final state = stateDatabase;
    final removed = state.transaction((_) {
      if (!_db.removeWorkspace(normalizedId)) return false;
      WorkspaceSecurityPolicyRepository(state).deleteForWorkspace(normalizedId);
      return true;
    });
    if (!removed) {
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
    final normalizedPath = await _fsCoordinator
        .requireManagedWorkspaceDirectory(newPath);
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
  }) =>
      _fsCoordinator.browseWorkspaceTree(
        workspaceId: workspaceId,
        path: path,
        maxEntries: maxEntries,
        managedRemote: managedRemote,
      );

  Future<List<Map<String, dynamic>>> listMcpServers({
    String? workspaceId,
  }) =>
      _mcpCoordinator.listMcpServers(workspaceId: workspaceId);

  Future<Map<String, dynamic>> readMcpSnapshot({String? workspaceId}) =>
      _mcpCoordinator.readMcpSnapshot(workspaceId: workspaceId);

  Future<Map<String, dynamic>> saveMcpServer({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> config,
  }) =>
      _mcpCoordinator.saveMcpServer(
        scope: scope,
        workspaceId: workspaceId,
        config: config,
      );

  Future<Map<String, dynamic>> deleteMcpServer({
    required String scope,
    String? workspaceId,
    required String serverName,
  }) =>
      _mcpCoordinator.deleteMcpServer(
        scope: scope,
        workspaceId: workspaceId,
        serverName: serverName,
      );

  Future<String> mcpMutationFingerprint({
    required String operation,
    required String scope,
    String? workspaceId,
    String? serverName,
    Map<String, dynamic> intent = const {},
  }) =>
      _mcpCoordinator.mcpMutationFingerprint(
        operation: operation,
        scope: scope,
        workspaceId: workspaceId,
        serverName: serverName,
        intent: intent,
      );

  Future<Map<String, dynamic>> replaceMcpConfig({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> document,
  }) =>
      _mcpCoordinator.replaceMcpConfig(
        scope: scope,
        workspaceId: workspaceId,
        document: document,
      );

  Map<String, dynamic> previewMcpImport(String input) =>
      _mcpCoordinator.previewMcpImport(input);

  Future<Map<String, dynamic>> exportMcpServers({
    required List<String> serverNames,
    String scope = 'effective',
    String? workspaceId,
  }) =>
      _mcpCoordinator.exportMcpServers(
        serverNames: serverNames,
        scope: scope,
        workspaceId: workspaceId,
      );

  Future<Map<String, dynamic>> readAdvancedMcpServer({
    required String serverName,
    required String scope,
    String? workspaceId,
  }) =>
      _mcpCoordinator.readAdvancedMcpServer(
        serverName: serverName,
        scope: scope,
        workspaceId: workspaceId,
      );

  Future<Map<String, dynamic>> previewAdvancedMcpServer({
    required String serverName,
    required String scope,
    required String input,
    String? workspaceId,
  }) =>
      _mcpCoordinator.previewAdvancedMcpServer(
        serverName: serverName,
        scope: scope,
        input: input,
        workspaceId: workspaceId,
      );

  Future<Map<String, dynamic>> saveAdvancedMcpServer({
    required String serverName,
    required String scope,
    required String input,
    required String baseRevision,
    required String previewRevision,
    String? workspaceId,
  }) =>
      _mcpCoordinator.saveAdvancedMcpServer(
        serverName: serverName,
        scope: scope,
        input: input,
        baseRevision: baseRevision,
        previewRevision: previewRevision,
        workspaceId: workspaceId,
      );

  Future<Map<String, dynamic>> startMcpOAuth({
    required String serverName,
    required Map<String, dynamic> draftConfig,
    Map<String, dynamic> secretMutations = const {},
  }) =>
      _mcpCoordinator.startMcpOAuth(
        serverName: serverName,
        draftConfig: draftConfig,
        secretMutations: secretMutations,
      );

  Map<String, dynamic> mcpOAuthStatus(String flowId) =>
      _mcpCoordinator.mcpOAuthStatus(flowId);

  Future<Map<String, dynamic>> cancelMcpOAuth(String flowId) =>
      _mcpCoordinator.cancelMcpOAuth(flowId);

  Future<Map<String, dynamic>> completeMcpOAuth({
    required String flowId,
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> config,
  }) =>
      _mcpCoordinator.completeMcpOAuth(
        flowId: flowId,
        scope: scope,
        workspaceId: workspaceId,
        config: config,
      );

  Future<Map<String, dynamic>> inspectMcpServer({
    required String serverName,
    String scope = 'effective',
    String? workspaceId,
  }) =>
      _mcpCoordinator.inspectMcpServer(
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
  }) =>
      _mcpCoordinator.inspectMcpDraft(
        serverName: serverName,
        scope: scope,
        workspaceId: workspaceId,
        draftConfig: draftConfig,
        secretMutations: secretMutations,
      );

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
            'type': 'skill',
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

  Future<String> createFolder({
    required String parentPath,
    required String name,
    bool managedRemote = false,
  }) =>
      _fsCoordinator.createFolder(
        parentPath: parentPath,
        name: name,
        managedRemote: managedRemote,
      );

  Future<String> renameFolder({
    required String path,
    required String newName,
    bool managedRemote = false,
  }) =>
      _fsCoordinator.renameFolder(
        path: path,
        newName: newName,
        managedRemote: managedRemote,
      );

  Future<WorkspaceMutationPreview> previewDeleteFolder(
    String path, {
    bool managedRemote = false,
  }) =>
      _fsCoordinator.previewDeleteFolder(path, managedRemote: managedRemote);

  Future<String> deleteFolder(
    String path, {
    bool managedRemote = false,
    String? expectedFingerprint,
  }) =>
      _fsCoordinator.deleteFolder(
        path,
        managedRemote: managedRemote,
        expectedFingerprint: expectedFingerprint,
      );

  String _validateFolderName(String value) =>
      _fsCoordinator.validateFolderName(value);

  String _normalizeExistingDirectory(String value, {required String label}) =>
      _fsCoordinator.normalizeExistingDirectory(value, label: label);

  String _normalizePath(String value) => _fsCoordinator.normalizePath(value);

  String get _sanadHome => _sanadHomePath ?? getSanadHome();

  String get _currentWorkspacePath =>
      _normalizePath(_currentWorkingDirectory ?? Directory.current.path);

  /// Managed-remote (cloud) workspace creation, confined to the managed
  /// workspaces root. Takes exactly one of [name] (create a direct child of
  /// the root) or [path] (register an existing folder inside the root, as
  /// returned by a managed `workspace_tree` reply and revalidated here).
  Future<Map<String, dynamic>> _createManagedRemoteWorkspace({
    String? name,
    String? path,
    String? description,
  }) async {
    final hasName = name != null && name.trim().isNotEmpty;
    final hasPath = path != null && path.trim().isNotEmpty;
    if (hasName == hasPath) {
      throw const WorkspaceCommandException(
        WorkspaceCommandErrorCodes.invalidRequest,
        'Remote workspace creation takes exactly one of a name or a folder.',
      );
    }
    final trimmedDescription = description?.trim() ?? '';
    return _serialized(() async {
      if (hasPath) {
        final folder = await _fsCoordinator.requireManagedWorkspaceDirectory(
          path,
        );
        final stored = await _storeWorkspace(
          folder,
          source: 'existing',
          displayName: trimmedDescription.isNotEmpty
              ? trimmedDescription
              : p.basename(folder),
        );
        return _workspacePayload(stored);
      }
      final folderName = _validateFolderName(name!);
      final managedRoot = _fsCoordinator.managedRootPath();
      final targetPath = p.normalize(p.join(managedRoot, folderName));
      if (!p.isWithin(managedRoot, targetPath)) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Workspace name must stay inside the managed workspaces root.',
        );
      }
      final type = await FileSystemEntity.type(targetPath, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'Symbolic-link folders cannot be used as a workspace.',
        );
      }
      final existed = type != FileSystemEntityType.notFound;
      if (!existed) {
        await Directory(targetPath).create();
      } else if (type != FileSystemEntityType.directory) {
        throw const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.pathNotAllowed,
          'A file with that workspace name already exists.',
        );
      }
      final stored = await _storeWorkspace(
        targetPath,
        source: existed ? 'existing' : 'managed_remote',
        displayName: trimmedDescription.isNotEmpty
            ? trimmedDescription
            : folderName,
      );
      return _workspacePayload(stored);
    });
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
        ? await _fsCoordinator.requireManagedWorkspaceDirectory(newPath)
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

  Future<T> _serialized<T>(Future<T> Function() operation) =>
      _fsCoordinator.serialized(operation);

  String _fingerprint({
    required String operation,
    required String path,
    String extra = '',
  }) =>
      _fsCoordinator.fingerprint(
        operation: operation,
        path: path,
        extra: extra,
      );
}
