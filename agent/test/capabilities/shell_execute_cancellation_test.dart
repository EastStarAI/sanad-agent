import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:test/test.dart';

void main() {
  group('ShellExecuteTool cancellation', () {
    late Directory workspaceDir;

    setUp(() async {
      workspaceDir = await Directory.systemTemp.createTemp('shell-cancel-test');
    });

    tearDown(() async {
      if (workspaceDir.existsSync()) {
        await workspaceDir.delete(recursive: true);
      }
    });

    test(
      'user cancellation terminates command and returns cancel message',
      () async {
        final scope = RunCancellationScope(
          sessionId: 'session-cancel',
          runId: 'run-cancel',
          workItemId: 'work-cancel',
          generation: 1,
        );
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
        final command = Platform.isWindows
            ? 'ping -n 60 127.0.0.1 > nul'
            : 'tail -f /dev/null';

        final executeFuture = tool.execute(
          {'command': command, 'timeout_ms': 60000},
          context: ToolContext(
            sessionId: 'session-cancel',
            cancellationScope: scope,
            runId: scope.runId,
            generation: scope.generation,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 500));
        await scope.cancel();

        final resultString = await executeFuture;
        final result = jsonDecode(resultString) as Map<String, dynamic>;

        expect(result['isError'], isTrue);
        expect(result['output'], contains('Command cancelled by user.'));
      },
      skip: Platform.isWindows,
    );

    test(
      'timeout and user cancellation do not publish duplicate terminals',
      () async {
        final scope = RunCancellationScope(
          sessionId: 'session-race',
          runId: 'run-race',
          workItemId: 'work-race',
          generation: 1,
        );
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);

        final executeFuture = tool.execute(
          {'command': 'sleep 30', 'timeout_ms': 50},
          context: ToolContext(
            sessionId: 'session-race',
            cancellationScope: scope,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        scope.invalidate(reason: RunCancellationReason.userStop);

        final resultString = await executeFuture;
        final result = jsonDecode(resultString) as Map<String, dynamic>;

        expect(result['isError'], isTrue);
        final output = result['output'] as String;
        expect(
          output.contains('Command cancelled by user.') ||
              output.contains('Command timed out'),
          isTrue,
        );
        expect(
          !(output.contains('Command cancelled by user.') &&
              output.contains('Command timed out')),
          isTrue,
        );
      },
      skip: Platform.isWindows,
    );

    test(
      'shutdown interruption is not reported as user cancellation',
      () async {
        final scope = RunCancellationScope(
          sessionId: 'session-shutdown',
          runId: 'run-shutdown',
          workItemId: 'work-shutdown',
          generation: 1,
        );
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
        final executeFuture = tool.execute(
          {
            'command': 'printf "before-shutdown\\n"; sleep 30',
            'timeout_ms': 60000,
          },
          context: ToolContext(
            sessionId: scope.sessionId,
            cancellationScope: scope,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));
        await scope.cancel(reason: RunCancellationReason.shutdown);
        final result = jsonDecode(await executeFuture) as Map<String, dynamic>;

        expect(result['output'], contains('before-shutdown'));
        expect(result['output'], contains('agent stopped'));
        expect(result['output'], isNot(contains('cancelled by user')));
        expect(result['terminal_reason'], 'agent_interrupted');
      },
      skip: Platform.isWindows,
    );

    test(
      'natural wrapper exit drains output and removes live descendants',
      () async {
        final childPidFile = File('${workspaceDir.path}/child.pid');
        final tool = ShellExecuteTool(workspacePath: workspaceDir.path);
        final command =
            "(trap '' TERM; while :; do echo late-output; sleep 0.02; done) & "
            'echo "\$!" > "${childPidFile.path}"; exit 0';

        final resultString = await tool
            .execute({'command': command, 'timeout_ms': 5000})
            .timeout(const Duration(seconds: 5));
        final result = jsonDecode(resultString) as Map<String, dynamic>;

        expect(result['isError'], isFalse);
        final childPid = childPidFile.readAsStringSync().trim();
        expect(
          (await Process.run('kill', ['-0', childPid])).exitCode,
          isNot(0),
        );
      },
      skip: Platform.isWindows,
    );

    test('tool timeout releases its run cancellation registration', () async {
      final scope = RunCancellationScope(
        sessionId: 'session-timeout-release',
        runId: 'run-timeout-release',
        workItemId: 'work-timeout-release',
        generation: 1,
      );
      final tool = ShellExecuteTool(workspacePath: workspaceDir.path);

      await tool.execute(
        {'command': 'sleep 30', 'timeout_ms': 20},
        context: ToolContext(
          sessionId: scope.sessionId,
          cancellationScope: scope,
        ),
      );
      final report = await scope.cancel();

      expect(report.resources, isEmpty);
    }, skip: Platform.isWindows);
  });
}
