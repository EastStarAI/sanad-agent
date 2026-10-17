import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/execution/direct_execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/execution/protected_execution_backend.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:test/test.dart';

void main() {
  group('Task 83g: Direct and Protected Execution Backends', () {
    late Directory tempDir;

    setUp(() async {
      WorkspacePolicyStore.clearMemoryCache();
      tempDir = await Directory.systemTemp.createTemp('sanad_backend_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('DirectExecutionBackend executes host command directly', () async {
      final backend = DirectExecutionBackend();
      expect(backend.mode, ExecutionMode.direct);
      expect(backend.isAvailable, isTrue);

      final stopwatch = Stopwatch()..start();
      final resultJson = await backend.executeCommand(
        command: 'echo hello_direct_backend',
        workingDir: tempDir.path,
        timeoutMs: 5000,
        stopwatch: stopwatch,
      );

      final result = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(result['isError'], isNull);
      expect(result['output'], contains('hello_direct_backend'));
      expect(result['backend'], equals('direct'));
    });

    test('ProtectedExecutionBackend fails closed when unavailable (No silent host fallback)', () async {
      final backend = ProtectedExecutionBackend(isAvailable: false);
      expect(backend.mode, ExecutionMode.protected);
      expect(backend.isAvailable, isFalse);

      final stopwatch = Stopwatch()..start();
      final resultJson = await backend.executeCommand(
        command: 'echo attempt_sandbox',
        workingDir: tempDir.path,
        timeoutMs: 5000,
        stopwatch: stopwatch,
      );

      final result = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      expect(result['status'], equals('unavailable'));
      expect(result['backend'], equals('protected'));
      expect(
        result['error'],
        contains('Protected execution backend is not available on this host'),
      );
      expect(
        result['error'],
        contains('Host fallback is prohibited'),
      );
    });

    test('ProtectedExecutionBackend executes safely inside sandbox when available', () async {
      final backend = ProtectedExecutionBackend(
        isAvailable: true,
        sandboxRunner: ({
          required String command,
          required String workingDir,
          required int timeoutMs,
          required Stopwatch stopwatch,
          ToolContext? context,
        }) async {
          return jsonEncode({
            'output': 'sandbox_output: $command',
            'duration_ms': stopwatch.elapsedMilliseconds,
            'backend': 'protected',
          });
        },
      );

      final stopwatch = Stopwatch()..start();
      final resultJson = await backend.executeCommand(
        command: 'flutter build',
        workingDir: tempDir.path,
        timeoutMs: 5000,
        stopwatch: stopwatch,
      );

      final result = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(result['output'], equals('sandbox_output: flutter build'));
      expect(result['backend'], equals('protected'));
    });

    test('ExecutionBackendResolver dynamically switches backends in same session (Gate G3)', () async {
      const store = WorkspacePolicyStore();
      final resolver = ExecutionBackendResolver(policyStore: store);

      // 1. Initial workspace policy is direct developer
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-switch-1',
          canonicalPath: tempDir.path,
          executionMode: ExecutionMode.direct,
        ),
      );

      var backend = await resolver.resolveBackend(
        workspaceId: 'ws-switch-1',
        canonicalPath: tempDir.path,
      );
      expect(backend.mode, equals(ExecutionMode.direct));

      // 2. Owner switches workspace policy to protected
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-switch-1',
          canonicalPath: tempDir.path,
          executionMode: ExecutionMode.protected,
        ),
      );

      // 3. Next execution in the same session immediately adopts protected backend
      backend = await resolver.resolveBackend(
        workspaceId: 'ws-switch-1',
        canonicalPath: tempDir.path,
      );
      expect(backend.mode, equals(ExecutionMode.protected));

      // 4. Owner switches back to direct
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-switch-1',
          canonicalPath: tempDir.path,
          executionMode: ExecutionMode.direct,
        ),
      );

      backend = await resolver.resolveBackend(
        workspaceId: 'ws-switch-1',
        canonicalPath: tempDir.path,
      );
      expect(backend.mode, equals(ExecutionMode.direct));
    });

    test('ShellExecuteTool enforces fail-closed protected execution via backend resolver', () async {
      const store = WorkspacePolicyStore();
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-tool-test',
          canonicalPath: tempDir.path,
          executionMode: ExecutionMode.protected,
        ),
      );

      final tool = ShellExecuteTool(
        workspacePath: tempDir.path,
        backendResolver: ExecutionBackendResolver(
          policyStore: store,
          protectedBackend: ProtectedExecutionBackend(isAvailable: false),
        ),
      );

      final responseJson = await tool.execute(
        {
          'command': 'ls -la',
          'description': 'List directory contents',
        },
        context: ToolContext(
          sessionId: 'session-123',
          metadata: {'workspace_id': 'ws-tool-test'},
        ),
      );

      final response = jsonDecode(responseJson) as Map<String, dynamic>;
      expect(response['isError'], isTrue);
      expect(response['backend'], equals('protected'));
      expect(response['status'], equals('unavailable'));
      expect(response['error'], contains('Host fallback is prohibited'));
    });
  });
}
