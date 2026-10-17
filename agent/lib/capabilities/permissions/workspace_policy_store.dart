import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';

import 'workspace_policy.dart';
import 'workspace_security_policy_repository.dart';

/// Service providing access to Workspace security policies.
///
/// Under Plan 83 (Task 83b), authoritative workspace security policy is owned
/// exclusively by the daemon state database under [WorkspaceSecurityPolicyRepository].
/// Workspace-local `.sanad/settings.json` is never read as an authoritative policy source.
class WorkspacePolicyStore {
  const WorkspacePolicyStore({
    WorkspaceSecurityPolicyRepository? repository,
    @Deprecated('Workspace settings files are non-authoritative under Plan 83')
    SanadSettingsStore? settingsStore,
  }) : _repository = repository;

  final WorkspaceSecurityPolicyRepository? _repository;

  static final Map<String, WorkspaceSecurityPolicy> _inMemoryStore = {};

  WorkspaceSecurityPolicyRepository? _resolveRepository() {
    if (_repository != null) return _repository;
    final getIt = GetIt.instance;
    if (getIt.isRegistered<WorkspaceSecurityPolicyRepository>()) {
      return getIt<WorkspaceSecurityPolicyRepository>();
    }
    if (getIt.isRegistered<AgentStateDatabase>()) {
      return WorkspaceSecurityPolicyRepository(getIt<AgentStateDatabase>().db);
    }
    return null;
  }

  static String _resolveSymlink(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      final dir = Directory(trimmed);
      if (dir.existsSync()) {
        return dir.resolveSymbolicLinksSync();
      }
    } catch (_) {}
    return trimmed;
  }

  Future<WorkspacePolicy> readPolicy(String workspacePath) async {
    final repo = _resolveRepository();
    if (repo != null) {
      final sec = repo.getPolicyByPath(workspacePath);
      return WorkspacePolicy(
        permissionMode: sec.permissionMode,
        executionMode: sec.executionMode,
        hostDiscoveryPolicy: sec.hostDiscoveryPolicy,
        revision: sec.revision,
        editableByOwner: true,
        permissions: sec.permissions,
      );
    }
    final resolvedPath = _resolveSymlink(workspacePath);
    final cached = _inMemoryStore[workspacePath] ?? _inMemoryStore[resolvedPath];
    if (cached != null) {
      return WorkspacePolicy(
        permissionMode: cached.permissionMode,
        executionMode: cached.executionMode,
        hostDiscoveryPolicy: cached.hostDiscoveryPolicy,
        revision: cached.revision,
        editableByOwner: true,
        permissions: cached.permissions,
      );
    }
    return const WorkspacePolicy();
  }

  Future<void> savePolicy(String workspacePath, WorkspacePolicy policy) async {
    final repo = _resolveRepository();
    if (repo != null) {
      final existing = repo.getPolicyByPath(workspacePath);
      final updated = existing.copyWith(
        canonicalPath: workspacePath,
        permissionMode: policy.permissionMode,
        permissions: policy.permissions,
      );
      repo.savePolicy(updated);
      return;
    }
    final sec = WorkspaceSecurityPolicy(
      workspaceId: _inMemoryStore[workspacePath]?.workspaceId ?? '',
      canonicalPath: workspacePath,
      permissionMode: policy.permissionMode,
      permissions: policy.permissions,
    );
    _inMemoryStore[workspacePath] = sec;
    final resolved = _resolveSymlink(workspacePath);
    if (resolved.isNotEmpty) {
      _inMemoryStore[resolved] = sec;
    }
  }

  Future<void> savePermissionMode(
    String workspacePath,
    WorkspacePermissionMode permissionMode,
  ) async {
    final current = await readPolicy(workspacePath);
    if (current.permissionMode == permissionMode) {
      return;
    }
    await savePolicy(
      workspacePath,
      current.copyWith(permissionMode: permissionMode),
    );
  }

  Future<WorkspaceSecurityPolicy> readSecurityPolicy(
    String workspaceId, {
    String? canonicalPath,
  }) async {
    final repo = _resolveRepository();
    if (repo != null) {
      return repo.getPolicy(workspaceId, canonicalPath: canonicalPath);
    }
    final key = workspaceId.isNotEmpty ? workspaceId : (canonicalPath ?? '');
    final resolvedPath =
        canonicalPath != null ? _resolveSymlink(canonicalPath) : null;
    return _inMemoryStore[key] ??
        (canonicalPath != null ? _inMemoryStore[canonicalPath] : null) ??
        (resolvedPath != null ? _inMemoryStore[resolvedPath] : null) ??
        WorkspaceSecurityPolicy.cleanDefault(
          workspaceId: workspaceId,
          canonicalPath: canonicalPath ?? '',
        );
  }

  Future<WorkspaceSecurityPolicy> saveSecurityPolicy(
    WorkspaceSecurityPolicy policy,
  ) async {
    final repo = _resolveRepository();
    if (repo != null) {
      return repo.savePolicy(policy);
    }
    final key = policy.workspaceId.isNotEmpty
        ? policy.workspaceId
        : policy.canonicalPath;
    _inMemoryStore[key] = policy;
    if (policy.canonicalPath.isNotEmpty) {
      _inMemoryStore[policy.canonicalPath] = policy;
      final resolved = _resolveSymlink(policy.canonicalPath);
      if (resolved.isNotEmpty) {
        _inMemoryStore[resolved] = policy;
      }
    }
    return policy;
  }

  /// Clears transient memory cache (for test isolation).
  static void clearMemoryCache() {
    _inMemoryStore.clear();
  }

  static Directory sanadDirectoryForWorkspace(String workspacePath) {
    return SanadSettingsStore.sanadDirectoryForWorkspace(workspacePath);
  }

  static File settingsFileForWorkspace(String workspacePath) {
    return SanadSettingsStore.settingsFileForWorkspace(workspacePath);
  }
}
