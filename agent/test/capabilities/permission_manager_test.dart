import 'dart:io';

import 'dart:async';

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

class BlockingPlatformRuntimeBridge extends PlatformRuntimeBridge {
  final List<Completer<Map<String, dynamic>>> _decisions = [];
  final StreamController<int> _requestCounts = StreamController<int>.broadcast(
    sync: true,
  );
  int requestCount = 0;
  int activeRequestCount = 0;
  int maxActiveRequestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final decision = Completer<Map<String, dynamic>>();
    _decisions.add(decision);
    requestCount++;
    activeRequestCount++;
    if (activeRequestCount > maxActiveRequestCount) {
      maxActiveRequestCount = activeRequestCount;
    }
    _requestCounts.add(requestCount);
    try {
      return await decision.future;
    } finally {
      activeRequestCount--;
    }
  }

  Future<void> waitForRequestCount(int expected) async {
    if (requestCount >= expected) return;
    await _requestCounts.stream
        .firstWhere((count) => count >= expected)
        .timeout(const Duration(seconds: 2));
  }

  void resolveRequest(int index, {bool allowed = true, String scope = 'once'}) {
    _decisions[index].complete({'allowed': allowed, 'scope': scope});
  }

  Future<void> close() => _requestCounts.close();
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

    test(
      'serializes concurrent permission requests within one session',
      () async {
        final blockingBridge = BlockingPlatformRuntimeBridge();
        final concurrentCheckpoints = FakeCheckpointStore();
        final concurrentManager = PermissionManager(
          policyStore: store,
          platformRuntimeBridge: blockingBridge,
          checkpointStore: concurrentCheckpoints,
        );
        final context = ToolContext(
          sessionId: 'thread-concurrent',
          metadata: {
            'workspace': {
              'id': workspaceDir.path,
              'name': 'workspace',
              'path': workspaceDir.path,
            },
          },
        );

        final authorizations = List<Future<void>>.generate(
          5,
          (index) => concurrentManager.ensureAuthorized(
            tool: shellTool,
            arguments: {'command': 'read-external-$index'},
            context: ToolContext(
              sessionId: context.sessionId,
              toolCallId: 'call-$index',
              metadata: context.metadata,
            ),
          ),
        );

        await blockingBridge.waitForRequestCount(1);
        expect(blockingBridge.requestCount, 1);
        expect(blockingBridge.maxActiveRequestCount, 1);
        expect(concurrentCheckpoints.byRequestId, hasLength(1));

        for (var index = 0; index < authorizations.length; index++) {
          blockingBridge.resolveRequest(index);
          if (index + 1 < authorizations.length) {
            await blockingBridge.waitForRequestCount(index + 2);
            expect(blockingBridge.activeRequestCount, 1);
            expect(blockingBridge.maxActiveRequestCount, 1);
          }
        }

        await Future.wait(authorizations);
        expect(blockingBridge.requestCount, 5);
        expect(
          concurrentCheckpoints.byRequestId.values.map(
            (checkpoint) => checkpoint.status,
          ),
          everyElement('approved'),
        );
        await blockingBridge.close();
      },
    );

    test('queued authorization re-evaluates a new session grant', () async {
      final blockingBridge = BlockingPlatformRuntimeBridge();
      final grantManager = PermissionManager(
        policyStore: store,
        platformRuntimeBridge: blockingBridge,
        checkpointStore: FakeCheckpointStore(),
      );
      final metadata = {
        'workspace': {
          'id': workspaceDir.path,
          'name': 'workspace',
          'path': workspaceDir.path,
        },
      };
      final authorizations = [
        grantManager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'shared-command'},
          context: ToolContext(
            sessionId: 'thread-shared-grant',
            toolCallId: 'call-first',
            metadata: metadata,
          ),
        ),
        grantManager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'shared-command'},
          context: ToolContext(
            sessionId: 'thread-shared-grant',
            toolCallId: 'call-second',
            metadata: metadata,
          ),
        ),
      ];

      await blockingBridge.waitForRequestCount(1);
      blockingBridge.resolveRequest(0, scope: 'session');
      await Future.wait(authorizations);

      expect(blockingBridge.requestCount, 1);
      expect(blockingBridge.maxActiveRequestCount, 1);
      await blockingBridge.close();
    });

    test(
      'denial releases the next permission request in the session',
      () async {
        final blockingBridge = BlockingPlatformRuntimeBridge();
        final denialManager = PermissionManager(
          policyStore: store,
          platformRuntimeBridge: blockingBridge,
          checkpointStore: FakeCheckpointStore(),
        );
        final metadata = {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        };
        final denied = denialManager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'first'},
          context: ToolContext(
            sessionId: 'thread-denial-queue',
            toolCallId: 'call-denied',
            metadata: metadata,
          ),
        );
        final deniedExpectation = expectLater(
          denied,
          throwsA(isA<Exception>()),
        );
        final allowed = denialManager.ensureAuthorized(
          tool: shellTool,
          arguments: {'command': 'second'},
          context: ToolContext(
            sessionId: 'thread-denial-queue',
            toolCallId: 'call-allowed',
            metadata: metadata,
          ),
        );

        await blockingBridge.waitForRequestCount(1);
        blockingBridge.resolveRequest(0, allowed: false);
        await deniedExpectation;
        await blockingBridge.waitForRequestCount(2);
        blockingBridge.resolveRequest(1);
        await allowed;

        expect(blockingBridge.maxActiveRequestCount, 1);
        await blockingBridge.close();
      },
    );

    test(
      'permission requests in different sessions remain concurrent',
      () async {
        final blockingBridge = BlockingPlatformRuntimeBridge();
        final independentManager = PermissionManager(
          policyStore: store,
          platformRuntimeBridge: blockingBridge,
          checkpointStore: FakeCheckpointStore(),
        );
        final metadata = {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        };
        final authorizations = [
          independentManager.ensureAuthorized(
            tool: shellTool,
            arguments: {'command': 'session-a'},
            context: ToolContext(
              sessionId: 'thread-a',
              toolCallId: 'call-a',
              metadata: metadata,
            ),
          ),
          independentManager.ensureAuthorized(
            tool: shellTool,
            arguments: {'command': 'session-b'},
            context: ToolContext(
              sessionId: 'thread-b',
              toolCallId: 'call-b',
              metadata: metadata,
            ),
          ),
        ];

        await blockingBridge.waitForRequestCount(2);
        expect(blockingBridge.activeRequestCount, 2);
        blockingBridge.resolveRequest(0);
        blockingBridge.resolveRequest(1);
        await Future.wait(authorizations);

        expect(blockingBridge.maxActiveRequestCount, 2);
        await blockingBridge.close();
      },
    );

    test('non-sensitive tools do not enter the permission queue', () async {
      final blockingBridge = BlockingPlatformRuntimeBridge();
      final safeManager = PermissionManager(
        policyStore: store,
        platformRuntimeBridge: blockingBridge,
        checkpointStore: FakeCheckpointStore(),
      );
      const safeTool = LocalToolSpec(
        name: 'safe_read',
        displayName: 'Safe Read',
        description: 'Reads an already authorized resource.',
        inputSchema: {'type': 'object'},
        source: {'type': 'builtin_local', 'id': 'sanad-agent'},
        category: 'core',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': false},
        execution: {'target': 'local_runtime'},
      );

      await Future.wait(
        List.generate(
          5,
          (index) => safeManager.ensureAuthorized(
            tool: safeTool,
            arguments: {'index': index},
            context: ToolContext(sessionId: 'thread-safe'),
          ),
        ),
      );

      expect(blockingBridge.requestCount, 0);
      await blockingBridge.close();
    });

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
