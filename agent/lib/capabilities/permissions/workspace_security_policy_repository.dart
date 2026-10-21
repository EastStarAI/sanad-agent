import 'dart:convert';

import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sqlite3/sqlite3.dart';

import 'workspace_policy.dart';

/// A policy key and the canonical root it currently resolves to.
///
/// [workspaceId] is a registered workspace UUID or an `exec_root:` key. The
/// policy stays with the workspace id across relocation so restrictions are
/// never silently reset; [canonicalPath] is recorded on every write for
/// diagnostics. An `exec_root:` key embeds its root, so it cannot move.
class WorkspacePolicyBinding {
  const WorkspacePolicyBinding({
    required this.workspaceId,
    required this.canonicalPath,
  });

  final String workspaceId;
  final String canonicalPath;
}

/// A mutation lost a compare-and-swap race against [currentRevision].
class WorkspacePolicyConflict implements Exception {
  const WorkspacePolicyConflict(this.currentRevision);

  final int currentRevision;

  @override
  String toString() =>
      'Workspace policy changed (revision $currentRevision). Refresh and retry.';
}

/// Sole owner of the `workspace_security_policies` table.
///
/// The table is created by [AgentStateDatabase] and is additive: older Agents
/// on the same Sanad Home ignore it and keep their previous behaviour. Rows and
/// columns are never renamed or dropped.
class WorkspaceSecurityPolicyRepository {
  WorkspaceSecurityPolicyRepository(this._state);

  final AgentStateDatabase _state;

  static const _columns =
      'workspace_id, canonical_path, permission_mode, execution_mode, '
      'host_discovery_policy, permissions_json, revision';

  /// Reads the policy stored for [binding]; clean defaults when none exists.
  WorkspacePolicy read(WorkspacePolicyBinding binding) =>
      _readBound(_state.db, binding);

  /// Applies [mutate] atomically. When [expectedRevision] is supplied it must
  /// equal the current bound revision (`0` for defaults) or the call throws
  /// [WorkspacePolicyConflict] and nothing is written.
  WorkspacePolicy update(
    WorkspacePolicyBinding binding, {
    int? expectedRevision,
    required WorkspacePolicy Function(WorkspacePolicy current) mutate,
  }) {
    return _state.transaction((tx) {
      final current = _readBound(tx.db, binding);
      if (expectedRevision != null && expectedRevision != current.revision) {
        throw WorkspacePolicyConflict(current.revision);
      }
      final next = mutate(current);
      if (_samePolicy(current, next)) return current;
      final revision = _storedRevision(tx.db, binding.workspaceId) + 1;
      final now = DateTime.now().toUtc().toIso8601String();
      tx.db.execute(
        'INSERT INTO workspace_security_policies ($_columns, created_at, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET '
        'canonical_path = excluded.canonical_path, '
        'permission_mode = excluded.permission_mode, '
        'execution_mode = excluded.execution_mode, '
        'host_discovery_policy = excluded.host_discovery_policy, '
        'permissions_json = excluded.permissions_json, '
        'revision = excluded.revision, '
        'updated_at = excluded.updated_at',
        [
          binding.workspaceId,
          binding.canonicalPath,
          next.permissionMode.value,
          next.executionMode.value,
          next.hostDiscoveryPolicy.value,
          jsonEncode(next.permissions.toJson()),
          revision,
          now,
          now,
        ],
      );
      return next.copyWith(revision: revision);
    });
  }

  /// Deletes the policy and grants of a removed registered workspace.
  /// Composes inside the caller's [AgentStateDatabase.transaction] so the
  /// workspace record and its authority disappear together. `exec_root:`
  /// rows are never touched: they belong to their root, not a workspace.
  bool deleteForWorkspace(String workspaceId) {
    if (workspaceId.startsWith('exec_root:')) return false;
    return _state.transaction((tx) {
      tx.db.execute(
        'DELETE FROM workspace_security_policies WHERE workspace_id = ?',
        [workspaceId],
      );
      return tx.db.updatedRows > 0;
    });
  }

  WorkspacePolicy _readBound(Database db, WorkspacePolicyBinding binding) {
    final rows = db.select(
      'SELECT $_columns FROM workspace_security_policies '
      'WHERE workspace_id = ? LIMIT 1',
      [binding.workspaceId],
    );
    if (rows.isEmpty) return WorkspacePolicy.defaults;
    final row = rows.first;
    return WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.fromValue(
        row['permission_mode']?.toString(),
      ),
      executionMode: ExecutionMode.fromStored(
        row['execution_mode']?.toString(),
      ),
      hostDiscoveryPolicy: HostDiscoveryPolicy.fromStored(
        row['host_discovery_policy']?.toString(),
      ),
      permissions: _decodePermissions(row['permissions_json']),
      revision: (row['revision'] as num).toInt(),
    );
  }

  /// Revision numbers stay monotonic across a re-binding so a stale client
  /// revision from the previous root can never match the new one.
  int _storedRevision(Database db, String workspaceId) {
    final rows = db.select(
      'SELECT revision FROM workspace_security_policies '
      'WHERE workspace_id = ? LIMIT 1',
      [workspaceId],
    );
    return rows.isEmpty ? 0 : (rows.first['revision'] as num).toInt();
  }

  static WorkspaceToolPermissions _decodePermissions(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return const WorkspaceToolPermissions();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return WorkspaceToolPermissions.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } on FormatException {
      // A corrupt grant list grants nothing.
    }
    return const WorkspaceToolPermissions();
  }

  static bool _samePolicy(WorkspacePolicy a, WorkspacePolicy b) =>
      a.revision > 0 &&
      a.permissionMode == b.permissionMode &&
      a.executionMode == b.executionMode &&
      a.hostDiscoveryPolicy == b.hostDiscoveryPolicy &&
      jsonEncode(a.permissions.toJson()) == jsonEncode(b.permissions.toJson());
}
