import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

class FakePlatformRuntimeBridge extends PlatformRuntimeBridge {
  Map<String, dynamic> nextDecision = const {
    'allowed': true,
    'scope': 'workspace',
  };
  Map<String, dynamic>? lastPermissionPayload;
  int requestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requestCount++;
    lastPermissionPayload = payload;
    return nextDecision;
  }
}

class FakeCheckpointStore extends SuspendedCheckpointStore {
  final Map<String, SuspendedCheckpoint> byRequestId = {};

  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {
    byRequestId[checkpoint.requestId] = checkpoint;
  }

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async {
    return byRequestId[requestId];
  }

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {
    final current = byRequestId[requestId];
    if (current == null) return;
    byRequestId[requestId] = current.copyWith(
      status: status,
      updatedAt: DateTime.now(),
    );
  }
}

void main() {
  group('PermissionManager', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late WorkspacePolicyStore store;
    late FakePlatformRuntimeBridge bridge;
    late FakeCheckpointStore checkpointStore;
    late PermissionManager manager;
    late LocalToolSpec shellTool;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'permission-manager-test',
      );
      workspaceDir = Directory('${tempDir.path}/workspace')
        ..createSync(recursive: true);
      store = WorkspacePolicyStore(
        settingsStore: SanadSettingsStoreForTest(tempDir.path),
      );
      bridge = FakePlatformRuntimeBridge();
      checkpointStore = FakeCheckpointStore();
      manager = PermissionManager(
        policyStore: store,
        platformRuntimeBridge: bridge,
        checkpointStore: checkpointStore,
      );
      shellTool = const LocalToolSpec(
        name: 'shell_execute',
        displayName: 'Shell Execute',
        description: 'Run a shell command through the platform.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'},
          },
          'required': ['command'],
        },
        source: {'type': 'platform', 'owner': 'platform', 'id': 'local-ui'},
        category: 'system',
        workspaceRequired: true,
        approval: {
          'mode': 'default',
          'sensitive': true,
          'scope': 'workspace',
          'permission_class': 'shell',
        },
        execution: {'target': 'platform'},
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'persists workspace allow decisions and skips duplicate prompts',
      () async {
        final context = ToolContext(
          sessionId: 'thread-1',
          toolCallId: 'call-1',
          metadata: {
            'workspace': {
              'id': workspaceDir.path,
              'name': 'workspace',
              'path': workspaceDir.path,
            },
          },
        );

        await manager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'ls -la'},
          context: context,
        );

        final policy = await store.readPolicy(workspaceDir.path);
        expect(policy.permissions.allow, contains('shell_execute::ls -la'));
        expect(bridge.requestCount, equals(1));
        expect(checkpointStore.byRequestId.values, isNotEmpty);
        expect(
          checkpointStore.byRequestId.values.single.status,
          equals('approved'),
        );

        await manager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'ls -la'},
          context: context,
        );

        expect(bridge.requestCount, equals(1));
      },
    );

    test(
      'denial rejects only the current call and prompts again later',
      () async {
        bridge.nextDecision = const {'allowed': false, 'scope': 'workspace'};
        final context = ToolContext(
          sessionId: 'thread-2',
          toolCallId: 'call-2',
          metadata: {
            'workspace': {
              'id': workspaceDir.path,
              'name': 'workspace',
              'path': workspaceDir.path,
            },
          },
        );

        await expectLater(
          manager.ensureAuthorized(
            tool: shellTool,
            arguments: {'command': 'rm -rf build'},
            context: context,
          ),
          throwsA(isA<Exception>()),
        );

        final policy = await store.readPolicy(workspaceDir.path);
        expect(policy.permissions.deny, isEmpty);
        expect(bridge.requestCount, equals(1));
        expect(
          checkpointStore.byRequestId.values.single.status,
          equals('denied'),
        );

        bridge.nextDecision = const {'allowed': true, 'scope': 'once'};
        await manager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'rm -rf build'},
          context: context,
        );

        expect(bridge.requestCount, equals(2));
      },
    );

    test(
      'uses explicit approval keys with sanitized display arguments',
      () async {
        final context = ToolContext(
          sessionId: 'thread-external',
          toolCallId: 'call-external',
          metadata: {
            'workspace': {
              'id': workspaceDir.path,
              'name': 'workspace',
              'path': workspaceDir.path,
            },
          },
        );
        const approvalKey =
            'external_workspace_path::file_write::/external/file.txt';

        await manager.ensureAuthorized(
          tool: shellTool,
          arguments: {
            'path': '/external/file.txt',
            'content': 'private content',
          },
          context: context,
          approvalKeyOverride: approvalKey,
          permissionDisplayArguments: const {
            'action': 'file_write',
            'path': '/external/file.txt',
          },
        );

        final policy = await store.readPolicy(workspaceDir.path);
        expect(policy.permissions.allow, contains(approvalKey));
        expect(bridge.lastPermissionPayload?['approval_key'], approvalKey);
        expect(bridge.lastPermissionPayload?['tool_input'], const {
          'action': 'file_write',
          'path': '/external/file.txt',
        });
        expect(
          bridge.lastPermissionPayload.toString(),
          isNot(contains('private content')),
        );
        expect(
          checkpointStore.byRequestId.values.single.toolArguments['content'],
          'private content',
        );

        await manager.ensureAuthorized(
          tool: shellTool,
          arguments: {
            'path': '/external/file.txt',
            'content': 'updated private content',
          },
          context: context,
          approvalKeyOverride: approvalKey,
          permissionDisplayArguments: const {
            'action': 'file_write',
            'path': '/external/file.txt',
          },
        );
        expect(bridge.requestCount, equals(1));
      },
    );

    test('uses full_access workspace mode without prompting', () async {
      await store.savePolicy(
        workspaceDir.path,
        const WorkspacePolicy(
          permissionMode: WorkspacePermissionMode.fullAccess,
        ),
      );
      final context = ToolContext(
        sessionId: 'thread-3',
        toolCallId: 'call-3',
        metadata: {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        },
      );

      await manager.ensureAuthorized(
        tool: shellTool,
        arguments: {'command': 'pwd'},
        context: context,
      );

      expect(bridge.requestCount, equals(0));
    });

    test('applies resumed once-scope approvals as one-shot bypasses', () async {
      final context = ToolContext(
        sessionId: 'session-4',
        toolCallId: 'call-4',
        metadata: {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        },
      );

      await manager.applyResolvedDecision(
        permissionPayload: {
          'session_id': 'session-4',
          'workspace_id': workspaceDir.path,
          'workspace_name': 'workspace',
          'workspace_path': workspaceDir.path,
          'tool_input': {'command': 'pwd'},
          'tool': shellTool.toJson(),
        },
        decision: const {'allowed': true, 'scope': 'once'},
      );

      await manager.ensureAuthorized(
        tool: shellTool,
        arguments: {'command': 'pwd'},
        context: context,
      );
      expect(bridge.requestCount, equals(0));

      await manager.ensureAuthorized(
        tool: shellTool,
        arguments: {'command': 'pwd'},
        context: context,
      );
      expect(bridge.requestCount, equals(1));
    });
  });
}

class SanadSettingsStoreForTest extends SanadSettingsStore {
  const SanadSettingsStoreForTest(String homeDirectoryPath)
    : super(homeDirectoryPath: homeDirectoryPath);
}
