import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_security_policy_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';

/// Daemon-authoritative policy store over an in-memory state database.
///
/// Registered workspaces are the [paths] given (plus [bind] and [seed]); an
/// unmapped id resolves to itself, matching fixtures that use the workspace
/// root as its id. [seed] writes a
/// policy the way the explicit owner command would, without a transport.
class MemoryWorkspacePolicyStore extends WorkspacePolicyStore {
  MemoryWorkspacePolicyStore._(
    this.database,
    this._paths, [
    void Function(String workspaceId, WorkspacePolicy policy)? announceChange,
  ]) : super(
        announceChange: announceChange,
        database: () => database,
        resolveRegisteredPath: (id) async =>
            _paths.containsKey(id) ? _paths[id] : id,
        listRegisteredWorkspaces: () async => [
          for (final entry in _paths.entries)
            if (entry.value != null) (id: entry.key, path: entry.value!),
        ],
      );

  factory MemoryWorkspacePolicyStore({
    Map<String, String?> paths = const {},
    void Function(String workspaceId, WorkspacePolicy policy)? announceChange,
  }) => MemoryWorkspacePolicyStore._(
    AgentStateDatabase.inMemory(),
    Map<String, String?>.from(paths),
    announceChange,
  );

  /// Empty store for subclasses in tests.
  MemoryWorkspacePolicyStore.forTest()
    : this._(AgentStateDatabase.inMemory(), <String, String?>{});

  final AgentStateDatabase database;
  final Map<String, String?> _paths;

  /// Rebinds [workspaceId] to [path]; `null` makes it unregistered.
  void bind(String workspaceId, String? path) => _paths[workspaceId] = path;

  /// Seeds [policy] for [workspaceId]. A fixture that uses an existing
  /// directory as its own id is registered at that directory.
  Future<WorkspacePolicy> seed(
    String workspaceId,
    WorkspacePolicy policy,
  ) async {
    if (!_paths.containsKey(workspaceId) &&
        Directory(workspaceId).isAbsolute &&
        Directory(workspaceId).existsSync()) {
      _paths[workspaceId] = workspaceId;
    }
    final binding = await resolveBinding(workspaceId);
    if (binding == null) {
      throw StateError('Workspace $workspaceId is not bound.');
    }
    return WorkspaceSecurityPolicyRepository(
      database,
    ).update(binding, mutate: (_) => policy);
  }

  void dispose() => database.dispose();
}
