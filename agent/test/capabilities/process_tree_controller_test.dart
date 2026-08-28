import 'dart:io';

import 'package:sanad_agent/capabilities/tools/system/process_tree_controller.dart';
import 'package:sanad_agent/capabilities/tools/tool_execution_outcome.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessTreeController', () {
    test(
      'terminates a simple child process',
      () async {
        final process = await Process.start('sh', ['-c', 'sleep 30']);
        final tree = ProcessTreeController.attach(
          process,
          usesProcessGroup: false,
        );

        final report = await tree.terminate(
          gracePeriod: const Duration(milliseconds: 100),
        );

        expect(
          report.outcome,
          anyOf(
            ToolProcessCleanupOutcome.exited,
            ToolProcessCleanupOutcome.escalated,
          ),
        );
        expect(process.pid, greaterThan(0));
      },
      skip: Platform.isWindows,
    );

    test(
      'releases natural completion without forced kill',
      () async {
        final process = await Process.start('sh', ['-c', 'echo done']);
        final tree = ProcessTreeController.attach(
          process,
          usesProcessGroup: false,
        );
        await process.exitCode;
        tree.release();

        final report = await tree.terminate();
        expect(report.outcome, ToolProcessCleanupOutcome.exited);
        expect(report.diagnostics, 'already_released');
      },
      skip: Platform.isWindows,
    );

    test(
      'Linux process group kills background grandchild',
      () async {
        final workspace = await Directory.systemTemp.createTemp('tree-test');
        final childPidFile = File('${workspace.path}/child.pid');

        final process = await Process.start('setsid', [
          'sh',
          '-c',
          'sleep 30 & child=\$!; echo "\$child" > ${childPidFile.path}; wait',
        ]);
        final tree = ProcessTreeController.attach(
          process,
          usesProcessGroup: true,
        );

        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tree.terminate(gracePeriod: const Duration(milliseconds: 500));

        expect(childPidFile.existsSync(), isTrue);
        final childPid = childPidFile.readAsStringSync().trim();
        var childAlive = true;
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline)) {
          final probe = await Process.run('kill', ['-0', childPid]);
          if (probe.exitCode != 0) {
            childAlive = false;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }

        expect(childAlive, isFalse);
        await workspace.delete(recursive: true);
      },
      skip: !Platform.isLinux,
    );
  });
}
