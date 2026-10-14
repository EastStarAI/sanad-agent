import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_security_policy_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceSecurityPolicyRepository', () {
    late AgentStateDatabase db;
    late WorkspaceSecurityPolicyRepository repository;

    setUp(() {
      db = AgentStateDatabase.inMemory();
      repository = WorkspaceSecurityPolicyRepository(db.db);
    });

    tearDown(() {
      db.dispose();
    });

    test('returns clean default policy for unknown workspace', () {
      final policy = repository.getPolicy('non-existent-uuid', canonicalPath: '/tmp/ws');
      expect(policy.workspaceId, equals('non-existent-uuid'));
      expect(policy.canonicalPath, equals('/tmp/ws'));
      expect(policy.permissionMode, equals(WorkspacePermissionMode.defaultMode));
      expect(policy.executionMode, equals(ExecutionMode.direct));
      expect(policy.hostDiscoveryPolicy, equals(HostDiscoveryPolicy.ownerOnly));
      expect(policy.revision, equals(1));
    });

    test('saves and retrieves policy with monotonic revision increments', () {
      final initialPolicy = WorkspaceSecurityPolicy(
        workspaceId: 'ws-123',
        canonicalPath: '/projects/repo-1',
        permissionMode: WorkspacePermissionMode.defaultMode,
        executionMode: ExecutionMode.direct,
        hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
        permissions: const WorkspaceToolPermissions(allow: ['shell_execute']),
      );

      final saved1 = repository.savePolicy(initialPolicy);
      expect(saved1.revision, equals(1));

      final retrieved1 = repository.getPolicy('ws-123');
      expect(retrieved1.workspaceId, equals('ws-123'));
      expect(retrieved1.canonicalPath, equals('/projects/repo-1'));
      expect(retrieved1.permissionMode, equals(WorkspacePermissionMode.defaultMode));
      expect(retrieved1.permissions.allow, contains('shell_execute'));
      expect(retrieved1.revision, equals(1));

      // Update policy
      final updatedPolicy = retrieved1.copyWith(
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      final saved2 = repository.savePolicy(updatedPolicy);
      expect(saved2.revision, equals(2));

      final retrieved2 = repository.getPolicy('ws-123');
      expect(retrieved2.permissionMode, equals(WorkspacePermissionMode.fullAccess));
      expect(retrieved2.revision, equals(2));
    });

    test('retrieves policy by canonical path', () {
      final policy = WorkspaceSecurityPolicy(
        workspaceId: 'ws-abc',
        canonicalPath: '/var/repos/test-project',
        permissionMode: WorkspacePermissionMode.fullAccess,
        executionMode: ExecutionMode.protected,
        hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
      );
      repository.savePolicy(policy);

      final byPath = repository.getPolicyByPath('/var/repos/test-project');
      expect(byPath.workspaceId, equals('ws-abc'));
      expect(byPath.executionMode, equals(ExecutionMode.protected));
      expect(byPath.hostDiscoveryPolicy, equals(HostDiscoveryPolicy.disabled));
    });

    test('setPermissionMode updates mode and increments revision', () {
      final policy = WorkspaceSecurityPolicy(
        workspaceId: 'ws-mode',
        canonicalPath: '/tmp/mode-test',
      );
      repository.savePolicy(policy);

      final updated = repository.setPermissionMode('ws-mode', WorkspacePermissionMode.fullAccess);
      expect(updated.permissionMode, equals(WorkspacePermissionMode.fullAccess));
      expect(updated.revision, equals(2));

      // No-op update does not increment revision
      final same = repository.setPermissionMode('ws-mode', WorkspacePermissionMode.fullAccess);
      expect(same.revision, equals(2));
    });

    test('setExecutionMode and setHostDiscoveryPolicy update correctly', () {
      final policy = WorkspaceSecurityPolicy(
        workspaceId: 'ws-modes',
        canonicalPath: '/tmp/modes-test',
      );
      repository.savePolicy(policy);

      final execUpdated = repository.setExecutionMode('ws-modes', ExecutionMode.protected);
      expect(execUpdated.executionMode, equals(ExecutionMode.protected));
      expect(execUpdated.revision, equals(2));

      final hostUpdated = repository.setHostDiscoveryPolicy('ws-modes', HostDiscoveryPolicy.disabled);
      expect(hostUpdated.hostDiscoveryPolicy, equals(HostDiscoveryPolicy.disabled));
      expect(hostUpdated.revision, equals(3));
    });

    test('deletePolicy removes record from database', () {
      final policy = WorkspaceSecurityPolicy(
        workspaceId: 'ws-del',
        canonicalPath: '/tmp/del',
      );
      repository.savePolicy(policy);
      expect(repository.getPolicy('ws-del').workspaceId, equals('ws-del'));

      final deleted = repository.deletePolicy('ws-del');
      expect(deleted, isTrue);

      // Subsequent fetch returns clean default
      final after = repository.getPolicy('ws-del');
      expect(after.permissionMode, equals(WorkspacePermissionMode.defaultMode));
      expect(after.revision, equals(1));
    });

    test('WorkspacePolicyStore delegates directly to repository without file mutation', () async {
      final store = WorkspacePolicyStore(repository: repository);

      final secPolicy = WorkspaceSecurityPolicy(
        workspaceId: 'ws-store',
        canonicalPath: '/tmp/ws-store',
        permissionMode: WorkspacePermissionMode.fullAccess,
      );
      await store.saveSecurityPolicy(secPolicy);

      final readSec = await store.readSecurityPolicy('ws-store');
      expect(readSec.permissionMode, equals(WorkspacePermissionMode.fullAccess));
      expect(readSec.revision, equals(1));

      final readPolicy = await store.readPolicy('/tmp/ws-store');
      expect(readPolicy.permissionMode, equals(WorkspacePermissionMode.fullAccess));
    });
  });
}
