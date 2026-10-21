import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AgentStateDatabase state;
  late LocalWorkspaceRuntimeService runtime;
  late WorkspacePolicyStore store;

  setUp(() async {
    await getIt.reset();
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-ws-removal')
          .resolveSymbolicLinksSync(),
    );
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    final sessions = SessionDB.fromState(state);
    runtime = LocalWorkspaceRuntimeService(
      sanadHomePath: root.path,
      sessionDb: sessions,
    );
    store = WorkspacePolicyStore(
      database: () => state,
      resolveRegisteredPath: (id) async =>
          (await runtime.describeWorkspaceById(id))?['path']?.toString(),
      listRegisteredWorkspaces: () async => [
        for (final w in sessions.getStoredWorkspaces())
          (id: w['id'] as String, path: w['path'] as String),
      ],
    );
  });

  tearDown(() async {
    await runtime.dispose();
    await getIt.reset();
    state.dispose();
    root.deleteSync(recursive: true);
  });

  int policyRows(String id) => state.db.select(
    'SELECT 1 FROM workspace_security_policies WHERE workspace_id = ?',
    [id],
  ).length;

  test(
    'removing a workspace deletes its policy and grants; re-adding starts clean',
    () async {
      final folder = Directory('${root.path}/project')..createSync();
      final first = await runtime.createWorkspace(path: folder.path);
      final id = first['id'] as String;
      await store.updateModes(
        id,
        authority: CommandAuthority.owner,
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      await store.recordDecision(
        id,
        approvalKey: 'shell_execute::ls',
        allowed: true,
      );
      expect(policyRows(id), 1);

      await runtime.removeWorkspace(workspaceId: id);
      expect(policyRows(id), 0);

      final again = await runtime.createWorkspace(path: folder.path);
      final effective = (await store.resolveForRoot(folder.path))!;
      expect(effective.key, again['id']);
      expect(
        effective.policy.permissionMode,
        WorkspacePermissionMode.defaultMode,
      );
      expect(effective.policy.permissions.allow, isEmpty);
      expect((await store.readPolicy(id)).revision, 0);
    },
  );

  test('an exec_root row for an unregistered root is kept', () async {
    final loose = Directory('${root.path}/loose')..createSync();
    final ws = await runtime.createWorkspace(
      path: (Directory('${root.path}/other')..createSync()).path,
    );
    await store.updateModes(
      'exec_root:${loose.path}',
      authority: CommandAuthority.owner,
      permissionMode: WorkspacePermissionMode.fullAccess,
    );
    await runtime.removeWorkspace(workspaceId: ws['id'] as String);
    expect(policyRows('exec_root:${loose.path}'), 1);
  });
}
