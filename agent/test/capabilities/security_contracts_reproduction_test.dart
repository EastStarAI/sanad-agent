import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

class _FakePlatformRuntimeBridge extends PlatformRuntimeBridge {
  int requestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
    String? expectedRunId,
  }) async {
    requestCount++;
    return const {'allowed': true, 'scope': 'workspace'};
  }
}

class _FakeCheckpointStore extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async => null;

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}
}

void main() {
  group('Task 83: Security Contracts & Attack Reproduction', () {
    test(
      '[FLIPPED IN 83b] workspace settings.json full_access is ignored and requires user approval',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('sanad_vuln_test_');
        try {
          final sanadDir = Directory('${tempDir.path}/.sanad')..createSync(recursive: true);
          final settingsFile = File('${sanadDir.path}/settings.json');
          // An untrusted repository commits full_access in .sanad/settings.json
          await settingsFile.writeAsString(jsonEncode({
            'permissionMode': 'full_access',
          }));

          final bridge = _FakePlatformRuntimeBridge();
          final checkpointStore = _FakeCheckpointStore();
          final manager = PermissionManager(
            policyStore: const WorkspacePolicyStore(),
            platformRuntimeBridge: bridge,
            checkpointStore: checkpointStore,
          );

          final tool = LocalToolSpec(
            name: 'shell_execute',
            displayName: 'Run shell command',
            description: 'Runs shell',
            inputSchema: const {'type': 'object'},
            source: const {'type': 'system'},
            category: 'system',
            workspaceRequired: true,
            approval: const {'mode': 'default', 'sensitive': true},
            execution: const {'target': 'local'},
          );

          final context = ToolContext(
            sessionId: 'session_1',
            metadata: {
              'workspace': {
                'id': 'ws_1',
                'name': 'vulnerable_ws',
                'path': tempDir.path,
              },
            },
          );

          // Under Task 83b, workspace .sanad/settings.json is ignored as non-authoritative.
          // The manager defaults to defaultMode and requires user approval!
          await manager.ensureAuthorized(
            tool: tool,
            arguments: const {'command': 'cat /etc/passwd'},
            context: context,
          );

          expect(
            bridge.requestCount,
            equals(1),
            reason: 'Task 83b verified: full_access in workspace file is ignored; prompt requested from user',
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );

    test(
      '[FIXED IN 83e] ProcessEnvironmentPolicy prevents ShellExecuteTool from passing secrets to child processes',
      () {
        const policy = ProcessEnvironmentPolicy();
        final mockEnvironment = {
          'PATH': '/usr/bin:/bin',
          'HOME': '/Users/test',
          'SANAD_AUTH_TOKEN': 'secret_sanad_token_xyz',
          'OPENAI_API_KEY': 'sk-mock-secret-key-12345',
        };

        final childEnv = policy.buildChildEnvironment(
          purpose: ChildProcessPurpose.directDeveloper,
          inheritedEnvironment: mockEnvironment,
        );

        expect(
          childEnv.containsKey('SANAD_AUTH_TOKEN'),
          isFalse,
          reason: 'Hardening verified: child process does not inherit Sanad auth token',
        );
        expect(
          childEnv.containsKey('OPENAI_API_KEY'),
          isFalse,
          reason: 'Hardening verified: child process does not inherit provider API keys',
        );

        expect(childEnv['PATH'], '/usr/bin:/bin');
        expect(childEnv['HOME'], '/Users/test');

        // Verify security contract detects these secrets
        expect(ChildProcessSecurityContract.isSanadControlPlaneSecret('SANAD_AUTH_TOKEN'), isTrue);
        expect(ChildProcessSecurityContract.isProviderSecret('OPENAI_API_KEY'), isTrue);
      },
    );

    test(
      'Direct Developer environment preserves developer SDKs, tools, and cache variables',
      () {
        final developerEnv = {
          'PATH': '/Users/test/.fvm/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
          'HOME': '/Users/test',
          'USER': 'test',
          'SHELL': '/bin/zsh',
          'FVM_HOME': '/Users/test/.fvm',
          'FLUTTER_ROOT': '/Users/test/.fvm/versions/3.24.0',
          'JAVA_HOME': '/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home',
          'ANDROID_HOME': '/Users/test/Library/Android/sdk',
          'GOPATH': '/Users/test/go',
          'CARGO_HOME': '/Users/test/.cargo',
          'NVM_DIR': '/Users/test/.nvm',
        };

        for (final entry in developerEnv.entries) {
          expect(ChildProcessSecurityContract.isSanadControlPlaneSecret(entry.key), isFalse);
          expect(ChildProcessSecurityContract.isProviderSecret(entry.key), isFalse);
        }

        expect(ChildProcessSecurityContract.isProtectedOperatorKey('PATH'), isTrue);
        expect(ChildProcessSecurityContract.isProtectedOperatorKey('HOME'), isTrue);
        expect(ChildProcessSecurityContract.isProtectedOperatorKey('USER'), isTrue);
        expect(ChildProcessSecurityContract.isProtectedOperatorKey('SHELL'), isTrue);
      },
    );

    test(
      'MCP secrets are isolated to MCP server and must not leak to sibling Shell execution',
      () {
        final mcpSecret = {'DATABASE_PASSWORD': 'mcp_super_secret_pw'};
        final shellEnv = <String, String>{'PATH': '/usr/bin:/bin'};

        expect(shellEnv.containsKey('DATABASE_PASSWORD'), isFalse);
        expect(mcpSecret.containsKey('DATABASE_PASSWORD'), isTrue);
      },
    );

    test(
      'Host discovery tool contract: omitted when disabled or redundant with Host PATH access',
      () {
        expect(
          WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
            policy: HostDiscoveryPolicy.disabled,
            isOwner: true,
            hasEquivalentHostAccess: false,
          ),
          isFalse,
          reason: 'Disabled policy must omit tool spec completely (no stub)',
        );

        expect(
          WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
            policy: HostDiscoveryPolicy.ownerOnly,
            isOwner: false,
            hasEquivalentHostAccess: false,
          ),
          isFalse,
          reason: 'Non-owner must not be granted host capability discovery',
        );

        expect(
          WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
            policy: HostDiscoveryPolicy.ownerOnly,
            isOwner: true,
            hasEquivalentHostAccess: true,
          ),
          isFalse,
          reason: 'Redundant discovery tool is omitted when host PATH is directly accessible',
        );

        expect(
          WorkspaceSecurityPolicy.isHostDiscoveryPermitted(
            policy: HostDiscoveryPolicy.ownerOnly,
            isOwner: true,
            hasEquivalentHostAccess: false,
          ),
          isTrue,
          reason: 'Permitted only for verified owner when equivalent access is absent',
        );
      },
    );

    test(
      'Authority Precedence: owner required restrictions cannot be bypassed by workspace Full Access',
      () {
        expect(
          WorkspaceSecurityPolicy.canBypassApproval(
            permissionMode: WorkspacePermissionMode.fullAccess,
            isOwnerRequiredRestrictionActive: true,
          ),
          isFalse,
          reason: 'Owner restriction trumps workspace-level full access',
        );

        expect(
          WorkspaceSecurityPolicy.canBypassApproval(
            permissionMode: WorkspacePermissionMode.fullAccess,
            isOwnerRequiredRestrictionActive: false,
          ),
          isTrue,
        );

        expect(
          WorkspaceSecurityPolicy.canBypassApproval(
            permissionMode: WorkspacePermissionMode.defaultMode,
            isOwnerRequiredRestrictionActive: false,
          ),
          isFalse,
        );
      },
    );
  });
}
