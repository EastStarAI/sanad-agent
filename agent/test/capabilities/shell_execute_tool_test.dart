import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

String get _readTestFileCommand =>
    Platform.isWindows ? 'type test.txt' : 'cat test.txt';
String get _longRunningCommand =>
    Platform.isWindows ? 'ping -n 6 127.0.0.1 > nul' : 'sleep 5';

class FakePlatformRuntimeBridge extends PlatformRuntimeBridge {
  Map<String, dynamic> nextDecision = const {
    'allowed': true,
    'scope': 'workspace',
  };
  int requestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requestCount++;
    return nextDecision;
  }
}

class SanadSettingsStoreForTest extends SanadSettingsStore {
  const SanadSettingsStoreForTest(String homeDirectoryPath)
    : super(homeDirectoryPath: homeDirectoryPath);
}

class NoopCheckpointStore extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async {
    return null;
  }

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}

  @override
  Future<void> deleteByRequestId(String requestId) async {}
}

void main() {
  group('ShellExecuteTool Tests', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late WorkspacePolicyStore store;
    late FakePlatformRuntimeBridge bridge;
    late PermissionManager permissionManager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'shell-execute-tool-test',
      );
      workspaceDir = Directory('${tempDir.path}/workspace')
        ..createSync(recursive: true);
      store = WorkspacePolicyStore(
        settingsStore: SanadSettingsStoreForTest(tempDir.path),
      );
      bridge = FakePlatformRuntimeBridge();
      permissionManager = PermissionManager(
        policyStore: store,
        platformRuntimeBridge: bridge,
        checkpointStore: NoopCheckpointStore(),
      );
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('Tool specs and schemas', () {
      final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
      expect(tool.schema.name, equals('shell_execute'));
      expect(tool.toolSpec.category, equals('shell_execution'));
      expect(tool.toolSpec.workspaceRequired, isTrue);
      expect(tool.toolSpec.approval['sensitive'], isTrue);
    });

    test('Execute basic echo command', () async {
      final tool = ShellExecuteTool(
        workspacePath: workspaceDir.path,
        permissionManager: permissionManager,
      );

      final context = ToolContext(
        sessionId: 'thread-1',
        metadata: {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        },
      );

      final resultString = await tool.execute({
        'command': 'echo hello from shell',
      }, context: context);

      final result = jsonDecode(resultString);
      expect(result['isError'], isFalse);
      expect(result['output']?.toString().trim(), equals('hello from shell'));
      expect(
        bridge.requestCount,
        equals(1),
      ); // Prompts because it is sensitive and not yet cached/pre-approved
    });

    test('malformed process output cannot crash shell execution', () async {
      final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
      final command = Platform.isWindows
          ? r'''powershell.exe -NoProfile -NonInteractive -Command "$bytes=[byte[]](0xFF,0xFE,0x41); [Console]::OpenStandardOutput().Write($bytes,0,$bytes.Length)"'''
          : r"printf '\377\376A'";

      final resultString = await tool.execute({'command': command});
      final result = jsonDecode(resultString) as Map<String, dynamic>;

      expect(result['isError'], isFalse);
      expect(result['output'], contains('\uFFFD'));
      expect(result['output'], contains('A'));
    });

    test(
      'Path traversal validation - blocks execution outside workspace',
      () async {
        final tool = ShellExecuteTool(
          workspacePath: workspaceDir.path,
          permissionManager: permissionManager,
        );

        final context = ToolContext(
          sessionId: 'thread-2',
          metadata: {
            'workspace': {
              'id': workspaceDir.path,
              'name': 'workspace',
              'path': workspaceDir.path,
            },
          },
        );

        // Attempting to cwd to path outside workspace should throw FileSystemException
        expectLater(
          tool.execute({
            'command': 'ls',
            'cwd': '../../', // points to tempDir or system path
          }, context: context),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('Cwd is validated and runs command in subdirectory', () async {
      final subDir = Directory('${workspaceDir.path}/subdir')
        ..createSync(recursive: true);
      File('${subDir.path}/test.txt').writeAsStringSync('subdir test');

      final tool = ShellExecuteTool(
        workspacePath: workspaceDir.path,
        permissionManager: permissionManager,
      );

      final context = ToolContext(
        sessionId: 'thread-3',
        metadata: {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        },
      );

      final resultString = await tool.execute({
        'command': _readTestFileCommand,
        'cwd': 'subdir',
      }, context: context);

      final result = jsonDecode(resultString);
      expect(result['isError'], isFalse);
      expect(result['output']?.toString().trim(), equals('subdir test'));
    });

    test(
      'Windows resolves extensionless batch commands and preserves backslash paths',
      () async {
        await File(
          '${workspaceDir.path}/local-fvm.bat',
        ).writeAsString('@echo off\r\necho batch command found:%*\r\n');
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);

        final resultString = await tool.execute({
          'command': r'local-fvm .\scripts\sanad_dev.dart status',
        });
        final result = jsonDecode(resultString);

        expect(result['isError'], isFalse);
        expect(
          result['output']?.toString().trim(),
          equals(r'batch command found:.\scripts\sanad_dev.dart status'),
        );
      },
      skip: !Platform.isWindows,
    );

    test(
      'bounds streaming output while preserving the beginning and end',
      () async {
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
        final resultString = await tool.execute({
          'command': "printf START; yes x | head -c 40000; printf END",
        });
        final result = jsonDecode(resultString) as Map<String, dynamic>;
        final output = result['output'] as String;

        expect(output, startsWith('START'));
        expect(output, contains('END'));
        expect(output, contains('OUTPUT TRUNCATED'));
        expect(output.length, lessThan(26000));
      },
      skip: Platform.isWindows,
    );

    test('Timeout works and terminates command execution', () async {
      final tool = ShellExecuteTool(
        workspacePath: workspaceDir.path,
        permissionManager: permissionManager,
      );

      final context = ToolContext(
        sessionId: 'thread-timeout',
        metadata: {
          'workspace': {
            'id': workspaceDir.path,
            'name': 'workspace',
            'path': workspaceDir.path,
          },
        },
      );

      final resultString = await tool.execute({
        'command': _longRunningCommand,
        'timeout_ms': 100,
      }, context: context);

      final result = jsonDecode(resultString);
      expect(result['isError'], isTrue);
      expect(result['output']?.toString(), contains('Command timed out'));
    });

    test(
      'interactive prompt (git-style) terminates quickly instead of hanging',
      () async {
        // Simulates a command that waits for keyboard input via stdin (e.g.
        // `git push` prompting "Username for ..."). Before the fix this would
        // block forever because the child inherited an interactive stdin and
        // /dev/tty access. Now the stdin is closed immediately and the command
        // should fail fast.
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);

        final resultString = await tool.execute({
          'command': 'read line; echo "got: \$line"',
          'timeout_ms': 5000,
        });

        final result = jsonDecode(resultString);
        // With stdin closed, `read` gets EOF immediately → exit code 0,
        // empty value. The key assertion is that it returns at all (no hang).
        expect(result['isError'], isFalse);
      },
      skip: Platform.isWindows,
    );

    test(
      'Linux timeout kills the background child without killing the agent',
      () async {
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
        final childPidFile = File('${workspaceDir.path}/child.pid');

        final resultString = await tool.execute({
          'command': 'sleep 30 & child=\$!; echo "\$child" > child.pid; wait',
          'timeout_ms': 200,
        });

        final result = jsonDecode(resultString);
        expect(result['isError'], isTrue);
        expect(result['output']?.toString(), contains('Command timed out'));
        expect(childPidFile.existsSync(), isTrue);

        final childPid = childPidFile.readAsStringSync().trim();
        var childAlive = true;
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (childAlive && DateTime.now().isBefore(deadline)) {
          final probe = await Process.run('sh', [
            '-c',
            'kill -0 $childPid 2>/dev/null',
          ]);
          childAlive = probe.exitCode == 0;
          if (childAlive) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        expect(
          childAlive,
          isFalse,
          reason: 'Timed-out background process $childPid survived cleanup.',
        );
      },
      skip: !Platform.isLinux,
    );
  });
}
