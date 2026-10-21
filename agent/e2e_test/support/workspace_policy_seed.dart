import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_security_policy_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// Writes [policy] for the workspace registered at [workspacePath] directly
/// into the daemon state database under [stateHomePath], registering the
/// workspace when needed. Mirrors the owner command without a transport.
void seedWorkspacePolicy({
  required String stateHomePath,
  required String workspacePath,
  required WorkspacePolicy policy,
}) {
  // Attach without migrations: opening normally would run the orphan-path
  // workspace migration against a live daemon's sessions and register a
  // duplicate workspace record for the same folder.
  final dbFile = File(
    '$stateHomePath/${AgentStateDatabase.stateDatabaseFileName}',
  );
  final state = dbFile.existsSync()
      ? AgentStateDatabase.attached(sqlite3.open(dbFile.path))
      : AgentStateDatabase.atPath(stateHomePath);
  try {
    final sessions = SessionDB.fromState(state);
    // Match the daemon's own record whatever spelling it registered.
    String canonical(String path) => Directory(path).existsSync()
        ? Directory(path).resolveSymbolicLinksSync()
        : path;
    final target = canonical(workspacePath);
    Map<String, dynamic>? record;
    for (final stored in sessions.getStoredWorkspaces()) {
      if (canonical(stored['path'] as String) == target) record = stored;
    }
    if (record == null) {
      sessions.saveWorkspace(path: target, source: 'test');
      record = sessions.getWorkspaceByPath(target)!;
    }
    WorkspaceSecurityPolicyRepository(state).update(
      WorkspacePolicyBinding(
        workspaceId: record['id'] as String,
        canonicalPath: record['path'] as String,
      ),
      mutate: (_) => policy,
    );
  } finally {
    state.dispose();
    if (dbFile.existsSync()) state.db.dispose();
  }
}
