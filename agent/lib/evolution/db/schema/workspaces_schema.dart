import 'package:sqlite3/sqlite3.dart';

/// Workspace records and the daemon-private workspace security policy table.
///
/// `AgentStateDatabase` calls [apply] and then, at the pinned position this
/// module occupied before the SRP 138-11 split, [applySecurityPolicies]. The
/// two entry points exist only because the compaction migration runs between
/// them today; neither may be reordered.
class WorkspacesSchema {
  const WorkspacesSchema._();

  /// Creates the `workspaces` table.
  static void apply(Database db) {
    // ── workspaces ────────────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  /// Plan 83: daemon-private workspace security policy, owned by
  /// `WorkspaceSecurityPolicyRepository`. Additive only: older Agents on the
  /// same Sanad Home never read it, and no column is renamed or dropped.
  static void applySecurityPolicies(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS workspace_security_policies (
        workspace_id TEXT PRIMARY KEY,
        canonical_path TEXT NOT NULL,
        permission_mode TEXT NOT NULL,
        execution_mode TEXT NOT NULL,
        host_discovery_policy TEXT NOT NULL,
        permissions_json TEXT NOT NULL DEFAULT '{}',
        revision INTEGER NOT NULL CHECK (revision > 0),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
  }
}
