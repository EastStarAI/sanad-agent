import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_security_policy_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late WorkspaceSecurityPolicyRepository repository;
  const binding = WorkspacePolicyBinding(
    workspaceId: 'ws-1',
    canonicalPath: '/projects/alpha',
  );

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repository = WorkspaceSecurityPolicyRepository(state);
  });

  tearDown(() => state.dispose());

  test('an unknown workspace reads clean defaults at revision 0', () {
    final policy = repository.read(binding);
    expect(policy.permissionMode, WorkspacePermissionMode.defaultMode);
    expect(policy.executionMode, ExecutionMode.direct);
    expect(policy.hostDiscoveryPolicy, HostDiscoveryPolicy.ownerOnly);
    expect(policy.permissions.isEmpty, isTrue);
    expect(policy.revision, 0);
  });

  test('updates are revisioned and compare-and-swap guarded', () {
    final first = repository.update(
      binding,
      expectedRevision: 0,
      mutate: (p) =>
          p.copyWith(permissionMode: WorkspacePermissionMode.fullAccess),
    );
    expect(first.revision, 1);
    expect(
      () => repository.update(
        binding,
        expectedRevision: 0,
        mutate: (p) => p.copyWith(executionMode: ExecutionMode.protected),
      ),
      throwsA(
        isA<WorkspacePolicyConflict>().having(
          (e) => e.currentRevision,
          'currentRevision',
          1,
        ),
      ),
    );
    final stored = repository.read(binding);
    expect(stored.revision, 1);
    expect(stored.executionMode, ExecutionMode.direct);
  });

  test('a no-op update does not bump the revision', () {
    repository.update(
      binding,
      mutate: (p) =>
          p.copyWith(permissionMode: WorkspacePermissionMode.fullAccess),
    );
    final again = repository.update(
      binding,
      mutate: (p) =>
          p.copyWith(permissionMode: WorkspacePermissionMode.fullAccess),
    );
    expect(again.revision, 1);
  });

  test('a mutation that throws writes nothing', () {
    expect(
      () => repository.update(binding, mutate: (_) => throw StateError('no')),
      throwsStateError,
    );
    expect(repository.read(binding).revision, 0);
  });

  test('a relocated workspace keeps its policy and revision history', () {
    repository.update(
      binding,
      mutate: (p) => p.copyWith(
        executionMode: ExecutionMode.protected,
        permissions: const WorkspaceToolPermissions(deny: ['shell_execute::ls']),
      ),
    );
    const moved = WorkspacePolicyBinding(
      workspaceId: 'ws-1',
      canonicalPath: '/projects/other',
    );
    final relocated = repository.read(moved);
    expect(relocated.executionMode, ExecutionMode.protected);
    expect(relocated.permissions.deny, ['shell_execute::ls']);
    final rebound = repository.update(
      moved,
      mutate: (p) => p.copyWith(
        hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
      ),
    );
    expect(rebound.revision, 2);
    expect(rebound.executionMode, ExecutionMode.protected);
  });

  test('unknown stored values resolve to the restrictive posture', () {
    final now = DateTime.now().toUtc().toIso8601String();
    state.db.execute(
      'INSERT INTO workspace_security_policies (workspace_id, canonical_path, '
      'permission_mode, execution_mode, host_discovery_policy, '
      'permissions_json, revision, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'ws-1',
        '/projects/alpha',
        'god_mode',
        'host',
        'everyone',
        '{bad',
        3,
        now,
        now,
      ],
    );
    final policy = repository.read(binding);
    expect(policy.permissionMode, WorkspacePermissionMode.defaultMode);
    expect(policy.executionMode, ExecutionMode.protected);
    expect(policy.hostDiscoveryPolicy, HostDiscoveryPolicy.disabled);
    expect(policy.permissions.isEmpty, isTrue);
    expect(policy.revision, 3);
  });

  test(
    'the table is additive and reopening an existing state db keeps rows',
    () {
      final dir = Directory.systemTemp.createTempSync('sanad-policy-db');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = AgentStateDatabase.atPath(dir.path);
      WorkspaceSecurityPolicyRepository(first).update(
        binding,
        mutate: (p) => p.copyWith(executionMode: ExecutionMode.protected),
      );
      final columnsBefore = first.db
          .select("SELECT name FROM pragma_table_info('workspaces')")
          .map((row) => row['name'])
          .toList();
      first.dispose();

      final reopened = AgentStateDatabase.atPath(dir.path);
      addTearDown(reopened.dispose);
      expect(
        WorkspaceSecurityPolicyRepository(reopened).read(binding).executionMode,
        ExecutionMode.protected,
      );
      expect(
        reopened.db
            .select("SELECT name FROM pragma_table_info('workspaces')")
            .map((row) => row['name'])
            .toList(),
        columnsBefore,
      );
    },
  );

  group('WorkspacePolicyStore', () {
    late Directory root;
    late WorkspacePolicyStore store;
    late List<(String, WorkspacePolicy)> announced;

    setUp(() {
      root = Directory.systemTemp.createTempSync('sanad-policy-store');
      announced = [];
      store = WorkspacePolicyStore(
        database: () => state,
        resolveRegisteredPath: (id) async => id == 'ws-1' ? root.path : null,
        announceChange: (id, policy) => announced.add((id, policy)),
      );
    });

    test('every mutation announces the new revision, grants included', () async {
      await store.recordDecision('ws-1', approvalKey: 'shell_execute::ls', allowed: true);
      expect(announced.single.$1, 'ws-1');
      expect(announced.single.$2.revision, 1);
      expect(announced.single.$2.permissions.allow, ['shell_execute::ls']);
      final updated = await store.updateModes(
        'ws-1',
        authority: CommandAuthority.owner,
        expectedRevision: 1,
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      expect(updated.revision, 2);
      expect(announced.last.$2.revision, 2);
      expect(announced, hasLength(2));
      // A no-op does not announce.
      await store.updateModes(
        'ws-1',
        authority: CommandAuthority.owner,
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      expect(announced, hasLength(2));
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('unverified authority can narrow but not widen', () async {
      await store.updateModes(
        'ws-1',
        authority: CommandAuthority.owner,
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      await expectLater(
        store.updateModes(
          'ws-1',
          authority: CommandAuthority.unverified,
          hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
          executionMode: ExecutionMode.protected,
        ),
        completes,
      );
      for (final widen in [
        () => store.updateModes(
          'ws-1',
          authority: CommandAuthority.unverified,
          executionMode: ExecutionMode.direct,
        ),
        () => store.updateModes(
          'ws-1',
          authority: CommandAuthority.unverified,
          hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
        ),
      ]) {
        await expectLater(widen(), throwsA(isA<WorkspacePolicyDenied>()));
      }
      final stored = await store.readPolicy('ws-1');
      expect(stored.executionMode, ExecutionMode.protected);
      expect(stored.hostDiscoveryPolicy, HostDiscoveryPolicy.disabled);
    });

    test('an unregistered id reads defaults and cannot be written', () async {
      expect((await store.readPolicy('ghost')).revision, 0);
      await expectLater(
        store.updateModes(
          'ghost',
          authority: CommandAuthority.owner,
          permissionMode: WorkspacePermissionMode.fullAccess,
        ),
        throwsStateError,
      );
      await expectLater(
        store.recordDecision('ghost', approvalKey: 'k', allowed: true),
        throwsStateError,
      );
    });

    test('an exec_root key binds to its validated root only', () async {
      final key = 'exec_root:${root.path}';
      await store.updateModes(
        key,
        authority: CommandAuthority.owner,
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      expect(
        (await store.readPolicy(key)).permissionMode,
        WorkspacePermissionMode.fullAccess,
      );
      expect(await store.resolveBinding('exec_root:/no/such/root'), isNull);
    });

    test('a recorded decision replaces the opposite decision', () async {
      await store.recordDecision('ws-1', approvalKey: 'k', allowed: false);
      await store.recordDecision('ws-1', approvalKey: 'k', allowed: true);
      final stored = await store.readPolicy('ws-1');
      expect(stored.permissions.allow, ['k']);
      expect(stored.permissions.deny, isEmpty);
      expect(stored.permissionMode, WorkspacePermissionMode.defaultMode);
    });
  });
}
