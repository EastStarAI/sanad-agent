import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

import 'command_authority.dart';
import 'workspace_policy.dart';
import 'workspace_security_policy_repository.dart';

export 'workspace_security_policy_repository.dart'
    show WorkspacePolicyBinding, WorkspacePolicyConflict;

/// A policy mutation that would widen authority was attempted without
/// proven owner authority.
class WorkspacePolicyDenied implements Exception {
  const WorkspacePolicyDenied();

  @override
  String toString() =>
      'Only an authenticated owner client can widen workspace security policy.';
}

/// Resolves a registered workspace id to its current root, or `null` when the
/// workspace is unknown or its folder is missing.
typedef RegisteredWorkspacePathResolver =
    Future<String?> Function(String workspaceId);

/// Announces a stored policy change (modes or grants) to every client.
///
/// Registered by the composition root; the capability layer never depends on
/// a transport.
class WorkspacePolicyAnnouncer {
  const WorkspacePolicyAnnouncer(this.announce);

  final void Function(String workspaceId, WorkspacePolicy policy) announce;
}

/// Lists every registered workspace with its current root.
typedef RegisteredWorkspacesLister =
    Future<List<({String id, String path})>> Function();

/// The policy that governs one tool root.
///
/// [key] owns writes for that root (durable grants): the innermost registered
/// workspace containing it, else its `exec_root:` key. [policy] is the most
/// restrictive combination of every containing registered workspace (and the
/// root's own `exec_root:` row when one exists).
class EffectiveWorkspacePolicy {
  const EffectiveWorkspacePolicy({required this.key, required this.policy});

  final String key;
  final WorkspacePolicy policy;
}

/// Daemon-authoritative workspace security policy facade.
///
/// Policy is keyed by a registered workspace UUID (or an `exec_root:` key)
/// and stored in the Agent state database. `<workspace>/.sanad/settings.json`
/// is never read as authority, never seeded from, and never written.
class WorkspacePolicyStore {
  WorkspacePolicyStore({
    AgentStateDatabase Function()? database,
    RegisteredWorkspacePathResolver? resolveRegisteredPath,
    RegisteredWorkspacesLister? listRegisteredWorkspaces,
    void Function(String workspaceId, WorkspacePolicy policy)? announceChange,
    WorkspacePathResolver pathResolver = const WorkspacePathResolver(),
  }) : _announceChange = announceChange,
       _database = database,
       _resolveRegisteredPath = resolveRegisteredPath,
       _listRegisteredWorkspaces = listRegisteredWorkspaces,
       _pathResolver = pathResolver;

  static const execRootPrefix = 'exec_root:';

  final AgentStateDatabase Function()? _database;
  final RegisteredWorkspacePathResolver? _resolveRegisteredPath;
  final RegisteredWorkspacesLister? _listRegisteredWorkspaces;
  final void Function(String workspaceId, WorkspacePolicy policy)?
  _announceChange;

  /// Every write that changed the stored revision is announced, so clients
  /// never keep a stale revision (a grant raises it too).
  WorkspacePolicy _announced(
    String workspaceId,
    int previousRevision,
    WorkspacePolicy stored,
  ) {
    if (stored.revision == previousRevision) return stored;
    final announce =
        _announceChange ??
        (getIt.isRegistered<WorkspacePolicyAnnouncer>()
            ? getIt<WorkspacePolicyAnnouncer>().announce
            : null);
    announce?.call(workspaceId, stored);
    return stored;
  }
  final WorkspacePathResolver _pathResolver;

  WorkspaceSecurityPolicyRepository? _repository() {
    final explicit = _database;
    if (explicit != null) {
      return WorkspaceSecurityPolicyRepository(explicit());
    }
    if (getIt.isRegistered<AgentStateDatabase>()) {
      return WorkspaceSecurityPolicyRepository(getIt<AgentStateDatabase>());
    }
    return null;
  }

  Future<String?> _registeredPath(String workspaceId) async {
    final explicit = _resolveRegisteredPath;
    if (explicit != null) return explicit(workspaceId);
    if (!getIt.isRegistered<SessionManager>()) return null;
    final record = getIt<SessionManager>().db.getWorkspaceById(workspaceId);
    final path = record?['path']?.toString();
    if (path == null || path.isEmpty) return null;
    return Directory(path).existsSync() ? path : null;
  }

  Future<List<({String id, String path})>> _registeredWorkspaces() async {
    final explicit = _listRegisteredWorkspaces;
    if (explicit != null) return explicit();
    if (!getIt.isRegistered<SessionManager>()) return const [];
    return [
      for (final record in getIt<SessionManager>().db.getStoredWorkspaces())
        if ((record['id']?.toString() ?? '').isNotEmpty &&
            (record['path']?.toString() ?? '').isNotEmpty)
          (id: record['id'].toString(), path: record['path'].toString()),
    ];
  }

  static String _canonical(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) return dir.resolveSymbolicLinksSync();
    } on FileSystemException {
      // Fall through to the lexical form.
    }
    return p.normalize(path);
  }

  /// Resolves the policy that governs a validated tool [root].
  ///
  /// The scope is derived only from the root a tool actually operates on,
  /// never from client-supplied workspace metadata. Returns `null` when
  /// [root] is empty or the storage owner is unavailable.
  Future<EffectiveWorkspacePolicy?> resolveForRoot(String? root) async {
    final trimmed = root?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final repository = _repository();
    if (repository == null) return null;
    final canonicalRoot = _canonical(trimmed);

    final containing = <({String id, String path})>[];
    for (final workspace in await _registeredWorkspaces()) {
      final workspaceRoot = _canonical(workspace.path);
      if (canonicalRoot == workspaceRoot ||
          p.isWithin(workspaceRoot, canonicalRoot)) {
        containing.add((id: workspace.id, path: workspaceRoot));
      }
    }
    // Innermost first; records of the same folder (different stored
    // spellings) order by id so the owning key is stable across restarts.
    containing.sort((a, b) {
      final byDepth = b.path.length.compareTo(a.path.length);
      return byDepth != 0 ? byDepth : a.id.compareTo(b.id);
    });

    final policies = <WorkspacePolicy>[
      for (final workspace in containing)
        repository.read(
          WorkspacePolicyBinding(
            workspaceId: workspace.id,
            canonicalPath: workspace.path,
          ),
        ),
    ];
    final execBinding = await resolveBinding('$execRootPrefix$canonicalRoot');
    final execPolicy = execBinding == null
        ? null
        : repository.read(execBinding);
    final hasExecRow = execPolicy != null && execPolicy.revision > 0;
    if (hasExecRow) policies.add(execPolicy);

    final key = containing.isNotEmpty
        ? containing.first.id
        : '$execRootPrefix$canonicalRoot';
    // Every record of the innermost folder (different stored spellings) is
    // the same scope. Only records with a stored policy speak for it, so a
    // duplicate the daemon registered on its own cannot cancel the owner's
    // choice; explicit restrictions on any of them still combine.
    final ownerRecords = containing.isEmpty
        ? 0
        : containing.where((w) => w.path == containing.first.path).length;
    final ownerGroup = policies.take(ownerRecords).toList();
    final explicitOwners = ownerGroup.where((policy) => policy.revision > 0);
    final ownerScopes = explicitOwners.isNotEmpty
        ? explicitOwners.toList()
        : ownerGroup.take(1).toList();
    final ownerPolicy = ownerScopes.isNotEmpty
        ? ownerScopes.first
        : (execPolicy ?? WorkspacePolicy.defaults);
    final primary = ownerPolicy.copyWith(
      permissions: WorkspaceToolPermissions(
        allow: {
          for (final policy in ownerRecords > 0 ? ownerGroup : [ownerPolicy])
            ...policy.permissions.allow,
        }.toList(growable: false),
        deny: ownerPolicy.permissions.deny,
        ask: ownerPolicy.permissions.ask,
      ),
    );
    final combined = [...ownerScopes, ...policies.skip(ownerRecords)];
    return EffectiveWorkspacePolicy(
      key: key,
      policy: _mostRestrictive(primary, combined),
    );
  }

  /// Combines [policies] so no containing scope can be loosened by another:
  /// Full Access only when every scope grants it, Protected and disabled
  /// discovery when any scope requires them, denies from every scope, and
  /// allows only from the [primary] scope that owns the root's grants.
  static WorkspacePolicy _mostRestrictive(
    WorkspacePolicy primary,
    List<WorkspacePolicy> policies,
  ) {
    if (policies.isEmpty) return primary;
    final deny = <String>{
      for (final policy in policies) ...policy.permissions.deny,
    };
    return WorkspacePolicy(
      permissionMode:
          policies.every(
            (policy) =>
                policy.permissionMode == WorkspacePermissionMode.fullAccess,
          )
          ? WorkspacePermissionMode.fullAccess
          : WorkspacePermissionMode.defaultMode,
      executionMode:
          policies.any(
            (policy) => policy.executionMode == ExecutionMode.protected,
          )
          ? ExecutionMode.protected
          : ExecutionMode.direct,
      hostDiscoveryPolicy:
          policies.any(
            (policy) =>
                policy.hostDiscoveryPolicy == HostDiscoveryPolicy.disabled,
          )
          ? HostDiscoveryPolicy.disabled
          : HostDiscoveryPolicy.ownerOnly,
      permissions: WorkspaceToolPermissions(
        allow: [
          for (final grant in primary.permissions.allow)
            if (!deny.contains(grant)) grant,
        ],
        deny: deny.toList(growable: false),
        ask: primary.permissions.ask,
      ),
      revision: primary.revision,
    );
  }

  /// Resolves the policy key for [workspaceId]; `null` when it is not a
  /// registered workspace or a valid execution root.
  Future<WorkspacePolicyBinding?> resolveBinding(String? workspaceId) async {
    final id = workspaceId?.trim() ?? '';
    if (id.isEmpty) return null;
    if (id.startsWith(execRootPrefix)) {
      final String? root;
      try {
        root = _pathResolver.validateAndNormalizeExecutionRoot(
          id.substring(execRootPrefix.length),
        );
      } on Exception {
        return null;
      }
      if (root == null || root.isEmpty) return null;
      return WorkspacePolicyBinding(
        workspaceId: '$execRootPrefix$root',
        canonicalPath: root,
      );
    }
    final path = await _registeredPath(id);
    if (path == null) return null;
    return WorkspacePolicyBinding(workspaceId: id, canonicalPath: path);
  }

  /// Reads the effective policy; clean defaults when the key is unbound or
  /// the storage owner is unavailable.
  Future<WorkspacePolicy> readPolicy(String? workspaceId) async {
    final binding = await resolveBinding(workspaceId);
    final repository = _repository();
    if (binding == null || repository == null) return WorkspacePolicy.defaults;
    return repository.read(binding);
  }

  /// Applies an explicit policy-mode mutation.
  ///
  /// Throws [WorkspacePolicyDenied] when the change widens any axis without
  /// owner [authority], [WorkspacePolicyConflict] on a stale
  /// [expectedRevision], and [StateError] when the key is unbound.
  Future<WorkspacePolicy> updateModes(
    String workspaceId, {
    required CommandAuthority authority,
    int? expectedRevision,
    WorkspacePermissionMode? permissionMode,
    ExecutionMode? executionMode,
    HostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async {
    final (binding, repository) = await _requireStorage(workspaceId);
    var previousRevision = 0;
    final stored = repository.update(
      binding,
      expectedRevision: expectedRevision,
      mutate: (current) {
        previousRevision = current.revision;
        final next = current.copyWith(
          permissionMode: permissionMode,
          executionMode: executionMode,
          hostDiscoveryPolicy: hostDiscoveryPolicy,
        );
        if (!authority.isOwner && current.isWidenedBy(next)) {
          throw const WorkspacePolicyDenied();
        }
        return next;
      },
    );
    return _announced(binding.workspaceId, previousRevision, stored);
  }

  /// Records the winning workspace-scope approval decision for [approvalKey].
  ///
  /// The caller is the permission owner after the user explicitly approved or
  /// denied this exact action; the decision never changes any mode axis.
  Future<void> recordDecision(
    String workspaceId, {
    required String approvalKey,
    required bool allowed,
  }) async {
    final (binding, repository) = await _requireStorage(workspaceId);
    var previousRevision = 0;
    final stored = repository.update(
      binding,
      mutate: (current) {
        previousRevision = current.revision;
        final allow = [...current.permissions.allow]..remove(approvalKey);
        final deny = [...current.permissions.deny]..remove(approvalKey);
        (allowed ? allow : deny).add(approvalKey);
        return current.copyWith(
          permissions: WorkspaceToolPermissions(
            allow: allow,
            deny: deny,
            ask: current.permissions.ask,
          ),
        );
      },
    );
    _announced(binding.workspaceId, previousRevision, stored);
  }

  Future<(WorkspacePolicyBinding, WorkspaceSecurityPolicyRepository)>
  _requireStorage(String workspaceId) async {
    final binding = await resolveBinding(workspaceId);
    if (binding == null) {
      throw StateError('Workspace is not registered or its folder is missing.');
    }
    final repository = _repository();
    if (repository == null) {
      throw StateError('Workspace policy storage is unavailable.');
    }
    return (binding, repository);
  }

  static Directory sanadDirectoryForWorkspace(String workspacePath) {
    return SanadSettingsStore.sanadDirectoryForWorkspace(workspacePath);
  }

  static File settingsFileForWorkspace(String workspacePath) {
    return SanadSettingsStore.settingsFileForWorkspace(workspacePath);
  }
}
