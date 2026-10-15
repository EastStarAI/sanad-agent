import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_security_policy_repository.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  group('Task 83i — Gate I0: Static and Ownership Audit Evidence', () {
    late Directory tempDir;
    late AgentStateDatabase db;
    late WorkspaceSecurityPolicyRepository repository;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sanad-gate-i0-audit-');
      db = AgentStateDatabase.inMemory();
      repository = WorkspaceSecurityPolicyRepository(db.db);
    });

    tearDown(() async {
      db.dispose();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('I0.1: Workspace-local settings.json cannot alter policy; daemon DB owns authority', () async {
      final sanadDir = Directory('${tempDir.path}/.sanad')..createSync(recursive: true);
      final settingsFile = File('${sanadDir.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode({
        'permissionMode': 'full_access',
        'executionMode': 'direct',
      }));

      final store = WorkspacePolicyStore(repository: repository);
      final policy = await store.readPolicy(tempDir.path);

      // Must default to daemon DB defaults (defaultMode), ignoring file
      expect(policy.permissionMode, equals(WorkspacePermissionMode.defaultMode));
      expect(policy.executionMode, equals(ExecutionMode.direct));
      expect(policy.hostDiscoveryPolicy, equals(HostDiscoveryPolicy.ownerOnly));
      expect(policy.editableByOwner, isTrue);
    });

    test('I0.2: ProcessEnvironmentPolicy strips daemon control plane and provider tokens from Platform.environment', () {
      const policy = ProcessEnvironmentPolicy();
      final mockEnv = {
        'PATH': '/usr/bin:/bin',
        'HOME': '/Users/dev',
        'SANAD_AUTH_TOKEN': 'secret-control-plane-token',
        'OPENAI_API_KEY': 'sk-provider-secret',
        'ANTHROPIC_API_KEY': 'sk-ant-secret',
        'GEMINI_API_KEY': 'ai-gemini-secret',
      };

      final childEnv = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: mockEnv,
      );

      expect(childEnv.containsKey('SANAD_AUTH_TOKEN'), isFalse);
      expect(childEnv.containsKey('OPENAI_API_KEY'), isFalse);
      expect(childEnv.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(childEnv.containsKey('GEMINI_API_KEY'), isFalse);
      expect(childEnv['PATH'], equals('/usr/bin:/bin'));
      expect(childEnv['HOME'], equals('/Users/dev'));
    });

    test('I0.3: Secret namespaces strictly segregate auth, provider, and MCP tokens', () {
      expect(AgentSecretNamespaces.authKey('token'), equals('agent:auth:token'));
      expect(AgentSecretNamespaces.providerKey('uuid'), equals('providers:uuid'));
      expect(AgentSecretNamespaces.mcpKey('ref'), equals('mcp:ref'));

      expect(AgentSecretNamespaces.isAuthKey('agent:auth:token'), isTrue);
      expect(AgentSecretNamespaces.isProviderKey('providers:uuid'), isTrue);
      expect(AgentSecretNamespaces.isMcpKey('mcp:ref'), isTrue);

      expect(AgentSecretNamespaces.isAuthKey('providers:uuid'), isFalse);
      expect(AgentSecretNamespaces.isProviderKey('agent:auth:token'), isFalse);
    });

    test('I0.4: Host discovery tool catalog omission invariants', () {
      // Disabled policy -> omitted
      expect(
        WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
          policy: HostDiscoveryPolicy.disabled,
          isOwner: true,
          hasEquivalentHostAccess: false,
        ),
        isFalse,
      );

      // Non-owner -> omitted
      expect(
        WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
          policy: HostDiscoveryPolicy.ownerOnly,
          isOwner: false,
          hasEquivalentHostAccess: false,
        ),
        isFalse,
      );

      // Redundant in Direct mode -> omitted
      expect(
        WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
          policy: HostDiscoveryPolicy.ownerOnly,
          isOwner: true,
          hasEquivalentHostAccess: true,
        ),
        isFalse,
      );

      // Permitted only in Protected for owner with non-disabled policy
      expect(
        WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
          policy: HostDiscoveryPolicy.ownerOnly,
          isOwner: true,
          hasEquivalentHostAccess: false,
        ),
        isTrue,
      );
    });
  });
}
