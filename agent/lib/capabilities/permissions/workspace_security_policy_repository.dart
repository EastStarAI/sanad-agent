import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

import 'workspace_policy.dart';

/// Repository managing authoritative [WorkspaceSecurityPolicy] records
/// in the daemon state SQLite database.
class WorkspaceSecurityPolicyRepository {
  WorkspaceSecurityPolicyRepository(this._db);

  final Database _db;

  /// Retrieves the authoritative security policy for [workspaceId].
  ///
  /// If no policy row exists for this workspace, returns a clean default policy
  /// ([WorkspaceSecurityPolicy.cleanDefault]).
  WorkspaceSecurityPolicy getPolicy(
    String workspaceId, {
    String? canonicalPath,
  }) {
    final normalizedId = workspaceId.trim();
    if (normalizedId.isEmpty) {
      if (canonicalPath != null && canonicalPath.trim().isNotEmpty) {
        return getPolicyByPath(canonicalPath);
      }
      return WorkspaceSecurityPolicy.cleanDefault(
        workspaceId: normalizedId,
        canonicalPath: canonicalPath ?? '',
      );
    }

    final results = _db.select(
      'SELECT workspace_id, canonical_path, permission_mode, execution_mode, '
      'host_discovery_policy, permissions_json, revision, updated_at '
      'FROM workspace_security_policies WHERE workspace_id = ? LIMIT 1',
      [normalizedId],
    );

    if (results.isEmpty) {
      if (canonicalPath != null && canonicalPath.trim().isNotEmpty) {
        final byPath = getPolicyByPath(canonicalPath);
        if (byPath.workspaceId.isNotEmpty) {
          return byPath;
        }
      }
      return WorkspaceSecurityPolicy.cleanDefault(
        workspaceId: normalizedId,
        canonicalPath: canonicalPath ?? '',
      );
    }

    return _policyFromRow(results.first);
  }

  /// Retrieves the authoritative security policy by registered [canonicalPath].
  WorkspaceSecurityPolicy getPolicyByPath(String canonicalPath) {
    final normalizedPath = canonicalPath.trim();
    if (normalizedPath.isEmpty) {
      return WorkspaceSecurityPolicy.cleanDefault(
        workspaceId: '',
        canonicalPath: '',
      );
    }

    final results = _db.select(
      'SELECT workspace_id, canonical_path, permission_mode, execution_mode, '
      'host_discovery_policy, permissions_json, revision, updated_at '
      'FROM workspace_security_policies WHERE canonical_path = ? LIMIT 1',
      [normalizedPath],
    );

    if (results.isEmpty) {
      return WorkspaceSecurityPolicy.cleanDefault(
        workspaceId: '',
        canonicalPath: normalizedPath,
      );
    }

    return _policyFromRow(results.first);
  }

  /// Atomically saves [policy] with an incremented revision.
  WorkspaceSecurityPolicy savePolicy(WorkspaceSecurityPolicy policy) {
    final now = DateTime.now().toUtc();
    final permissionsJson = jsonEncode(policy.permissions.toJson());
    final workspaceId = policy.workspaceId.trim();

    final existing = _db.select(
      'SELECT revision FROM workspace_security_policies WHERE workspace_id = ? LIMIT 1',
      [workspaceId],
    );

    final int nextRevision;
    if (existing.isNotEmpty) {
      final currentRevision = (existing.first['revision'] as num).toInt();
      nextRevision = currentRevision + 1;
      _db.execute(
        'UPDATE workspace_security_policies SET '
        'canonical_path = ?, '
        'permission_mode = ?, '
        'execution_mode = ?, '
        'host_discovery_policy = ?, '
        'permissions_json = ?, '
        'revision = ?, '
        'updated_at = ? '
        'WHERE workspace_id = ?',
        [
          policy.canonicalPath,
          policy.permissionMode.value,
          policy.executionMode.value,
          policy.hostDiscoveryPolicy.value,
          permissionsJson,
          nextRevision,
          now.toIso8601String(),
          workspaceId,
        ],
      );
    } else {
      nextRevision = 1;
      _db.execute(
        'INSERT INTO workspace_security_policies ('
        'workspace_id, canonical_path, permission_mode, execution_mode, '
        'host_discovery_policy, permissions_json, revision, created_at, updated_at'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          workspaceId,
          policy.canonicalPath,
          policy.permissionMode.value,
          policy.executionMode.value,
          policy.hostDiscoveryPolicy.value,
          permissionsJson,
          nextRevision,
          now.toIso8601String(),
          now.toIso8601String(),
        ],
      );
    }

    return policy.copyWith(
      revision: nextRevision,
      updatedAt: now,
    );
  }

  /// Sets permission mode for [workspaceId].
  WorkspaceSecurityPolicy setPermissionMode(
    String workspaceId,
    WorkspacePermissionMode mode, {
    String? canonicalPath,
  }) {
    final current = getPolicy(workspaceId, canonicalPath: canonicalPath);
    if (current.permissionMode == mode && (canonicalPath == null || current.canonicalPath == canonicalPath)) {
      return current;
    }
    final updated = current.copyWith(
      canonicalPath: canonicalPath ?? current.canonicalPath,
      permissionMode: mode,
    );
    return savePolicy(updated);
  }

  /// Sets execution posture for [workspaceId].
  WorkspaceSecurityPolicy setExecutionMode(
    String workspaceId,
    ExecutionMode mode,
  ) {
    final current = getPolicy(workspaceId);
    if (current.executionMode == mode) return current;
    final updated = current.copyWith(executionMode: mode);
    return savePolicy(updated);
  }

  /// Sets host discovery policy for [workspaceId].
  WorkspaceSecurityPolicy setHostDiscoveryPolicy(
    String workspaceId,
    HostDiscoveryPolicy policy,
  ) {
    final current = getPolicy(workspaceId);
    if (current.hostDiscoveryPolicy == policy) return current;
    final updated = current.copyWith(hostDiscoveryPolicy: policy);
    return savePolicy(updated);
  }

  /// Deletes policy record for [workspaceId] upon workspace removal.
  bool deletePolicy(String workspaceId) {
    _db.execute(
      'DELETE FROM workspace_security_policies WHERE workspace_id = ?',
      [workspaceId.trim()],
    );
    return _db.updatedRows > 0;
  }

  WorkspaceSecurityPolicy _policyFromRow(Row row) {
    Map<String, dynamic> permissionsMap = const {};
    final permissionsRaw = row['permissions_json']?.toString();
    if (permissionsRaw != null && permissionsRaw.isNotEmpty) {
      try {
        permissionsMap = jsonDecode(permissionsRaw) as Map<String, dynamic>;
      } catch (_) {}
    }

    return WorkspaceSecurityPolicy(
      workspaceId: row['workspace_id']?.toString() ?? '',
      canonicalPath: row['canonical_path']?.toString() ?? '',
      permissionMode: WorkspacePermissionMode.fromValue(
        row['permission_mode']?.toString(),
      ),
      executionMode: ExecutionMode.fromValue(row['execution_mode']?.toString()),
      hostDiscoveryPolicy: HostDiscoveryPolicy.fromValue(
        row['host_discovery_policy']?.toString(),
      ),
      permissions: WorkspaceToolPermissions.fromJson(permissionsMap),
      revision: (row['revision'] as num?)?.toInt() ?? 1,
      updatedAt: row['updated_at'] != null
          ? DateTime.tryParse(row['updated_at'].toString())
          : null,
    );
  }
}
