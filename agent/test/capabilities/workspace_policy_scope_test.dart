import 'dart:io';

import 'package:sanad_agent/capabilities/execution/execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

import '../support/memory_workspace_policy_store.dart';

class _Bridge extends PlatformRuntimeBridge {
  int requests = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requests++;
    return const {'allowed': false};
  }
}

class _NoopCheckpoints extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}
}

class _Recording implements ExecutionBackend {
  _Recording(this.mode);

  @override
  final ExecutionMode mode;

  @override
  bool get runsCommands => true;

  @override
  Future<ToolExecutionResult> execute(ShellCommandRequest request) async =>
      ToolExecutionResult.text(mode.value);
}

const _shell = LocalToolSpec(
  name: 'shell_execute',
  displayName: 'Shell',
  description: 'shell',
  inputSchema: {'type': 'object'},
  source: {'type': 'builtin_local'},
  category: 'shell_execution',
  workspaceRequired: true,
  approval: {'sensitive': true},
  execution: {'target': 'local_runtime'},
);

class _FailingStore extends MemoryWorkspacePolicyStore {
  _FailingStore() : super.forTest();

  @override
  Future<EffectiveWorkspacePolicy?> resolveForRoot(String? root) async =>
      throw StateError('database is locked');
}

void main() {
  late Directory root;
  late String outer;
  late String inner;
  late String other;
  late MemoryWorkspacePolicyStore store;

  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-scope')
          .resolveSymbolicLinksSync(),
    );
    outer = (Directory('${root.path}/outer')..createSync()).path;
    inner = (Directory('$outer/inner')..createSync()).path;
    other = (Directory('${root.path}/other')..createSync()).path;
    store = MemoryWorkspacePolicyStore(
      paths: {'ws-outer': outer, 'ws-inner': inner, 'ws-other': other},
    );
  });

  tearDown(() {
    store.dispose();
    root.deleteSync(recursive: true);
  });

  Map<String, dynamic> metadata({
    String? workspaceId,
    String? workspacePath,
    String? executionRoot,
  }) => {
    if (workspaceId != null)
      'workspace': {
        'id': workspaceId,
        'path': workspacePath ?? '',
        'name': 'w',
      },
    'execution_root': ?executionRoot,
  };

  test(
    'a workspace map naming another workspace cannot replace the tool root policy',
    () async {
      await store.seed(
        'ws-other',
        const WorkspacePolicy(
          permissionMode: WorkspacePermissionMode.fullAccess,
        ),
      );
      await store.seed(
        'ws-inner',
        const WorkspacePolicy(
          permissions: WorkspaceToolPermissions(deny: ['shell_execute::ls']),
        ),
      );
      final bridge = _Bridge();
      final manager = PermissionManager(
        policyStore: store,
        platformRuntimeBridge: bridge,
        checkpointStore: _NoopCheckpoints(),
      );
      await expectLater(
        manager.ensureAuthorized(
          tool: _shell,
          arguments: {'command': 'ls'},
          context: ToolContext(
            sessionId: 's',
            metadata: metadata(
              workspaceId: 'ws-other',
              workspacePath: other,
              executionRoot: inner,
            ),
          ),
        ),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('denied by workspace policy'),
          ),
        ),
      );
    },
  );

  ExecutionBackendResolver resolver() => ExecutionBackendResolver(
    policyStore: store,
    directBackend: _Recording(ExecutionMode.direct),
    protectedBackend: _Recording(ExecutionMode.protected),
  );

  test(
    'a root inside a Protected workspace is Protected without a workspace id',
    () async {
      await store.seed(
        'ws-inner',
        const WorkspacePolicy(executionMode: ExecutionMode.protected),
      );
      final backend = await resolver().resolve(
        ToolContext(
          sessionId: 's',
          metadata: metadata(executionRoot: inner),
        ),
        root: inner,
      );
      expect(backend.mode, ExecutionMode.protected);
    },
  );

  test(
    'nested registered roots apply the most restrictive containing policy',
    () async {
      await store.seed(
        'ws-outer',
        const WorkspacePolicy(
          executionMode: ExecutionMode.protected,
          hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
          permissions: WorkspaceToolPermissions(deny: ['shell_execute::rm']),
        ),
      );
      await store.seed(
        'ws-inner',
        const WorkspacePolicy(
          permissionMode: WorkspacePermissionMode.fullAccess,
        ),
      );
      final effective = (await store.resolveForRoot(inner))!;
      expect(effective.key, 'ws-inner');
      expect(effective.policy.executionMode, ExecutionMode.protected);
      expect(
        effective.policy.hostDiscoveryPolicy,
        HostDiscoveryPolicy.disabled,
      );
      expect(
        effective.policy.permissionMode,
        WorkspacePermissionMode.defaultMode,
      );
      expect(effective.policy.permissions.deny, contains('shell_execute::rm'));
    },
  );

  test('an unregistered root resolves to its exec_root key', () async {
    final loose = (Directory('${root.path}/loose')..createSync()).path;
    final effective = (await store.resolveForRoot(loose))!;
    expect(effective.key, 'exec_root:$loose');
  });

  test('a relocated workspace keeps its restrictions', () async {
    await store.seed(
      'ws-other',
      const WorkspacePolicy(executionMode: ExecutionMode.protected),
    );
    final moved = (Directory('${root.path}/moved')..createSync()).path;
    store.bind('ws-other', moved);
    expect(
      (await store.readPolicy('ws-other')).executionMode,
      ExecutionMode.protected,
    );
    expect(
      (await store.resolveForRoot(moved))!.policy.executionMode,
      ExecutionMode.protected,
    );
  });

  test('Protected refuses before any prompt and records no grant', () async {
    await store.seed(
      'ws-inner',
      const WorkspacePolicy(executionMode: ExecutionMode.protected),
    );
    final bridge = _Bridge();
    final manager = PermissionManager(
      policyStore: store,
      platformRuntimeBridge: bridge,
      checkpointStore: _NoopCheckpoints(),
    );
    final tool = ShellExecuteTool(
      workspacePath: inner,
      permissionManager: manager,
      backendResolver: ExecutionBackendResolver(policyStore: store),
    );
    final result = await tool.executeResult(
      {'command': 'ls', 'description': 'list'},
      context: ToolContext(
        sessionId: 's',
        metadata: metadata(executionRoot: inner),
      ),
    );
    expect(result.isError, isTrue);
    expect(result.errorCode, ToolResultErrorCode.permissionDenied);
    expect(bridge.requests, 0);
    expect((await store.readPolicy('ws-inner')).permissions.allow, isEmpty);
  });

  test('a policy read failure is a typed refusal, never Direct', () async {
    final failing = _FailingStore();
    addTearDown(failing.dispose);
    final tool = ShellExecuteTool(
      workspacePath: inner,
      backendResolver: ExecutionBackendResolver(
        policyStore: failing,
        directBackend: _Recording(ExecutionMode.direct),
      ),
    );
    final result = await tool.executeResult(
      {'command': 'ls', 'description': 'list'},
      context: ToolContext(
        sessionId: 's',
        metadata: metadata(executionRoot: inner),
      ),
    );
    expect(result.isError, isTrue);
    expect(result.displayText, isNot(equals('direct')));
    expect(result.displayText, contains('policy_unavailable'));
    expect(result.displayText, isNot(contains('database is locked')));
  });

  test('two records for the same folder share grants and a stable owner', () async {
    store.bind('ws-z', other);
    store.bind('ws-a', '$other/');
    await store.seed(
      'ws-a',
      const WorkspacePolicy(
        permissions: WorkspaceToolPermissions(allow: ['shell_execute::ls']),
      ),
    );
    final effective = (await store.resolveForRoot(other))!;
    expect(effective.key, 'ws-a');
    expect(effective.policy.permissions.allow, contains('shell_execute::ls'));
  });

  test('a duplicate record without a stored policy cannot cancel Full Access', () async {
    store.bind('ws-dup', '$other/');
    await store.seed(
      'ws-other',
      const WorkspacePolicy(permissionMode: WorkspacePermissionMode.fullAccess),
    );
    final effective = (await store.resolveForRoot(other))!;
    expect(effective.policy.permissionMode, WorkspacePermissionMode.fullAccess);

    // An explicit restriction on either record still wins.
    await store.seed(
      'ws-dup',
      const WorkspacePolicy(executionMode: ExecutionMode.protected),
    );
    final restricted = (await store.resolveForRoot(other))!;
    expect(restricted.policy.executionMode, ExecutionMode.protected);
    expect(restricted.policy.permissionMode, WorkspacePermissionMode.defaultMode);
  });
}
