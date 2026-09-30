import 'dart:io';

import 'package:sanad_agent/capabilities/tools/system/process_tree_controller.dart';
import 'package:sanad_agent/capabilities/tools/tool_execution_outcome.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessTreeController', () {
    test('terminates a simple child process', () async {
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
    }, skip: Platform.isWindows);

    test('releases natural completion without forced kill', () async {
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
    }, skip: Platform.isWindows);

    test('Linux process group kills background grandchild', () async {
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
    }, skip: !Platform.isLinux);

    test('fingerprint mismatch refuses to signal a live process', () async {
      final process = await Process.start('sh', ['-c', 'sleep 30']);
      var reads = 0;
      final tree = ProcessTreeController.attach(
        process,
        usesProcessGroup: false,
        identityReader: (_) => reads++ == 0 ? 'spawn-identity' : 'reused',
      );

      final report = await tree.terminate(
        gracePeriod: const Duration(milliseconds: 50),
      );

      expect(report.outcome, ToolProcessCleanupOutcome.ownershipLost);
      expect(report.diagnostics, 'fingerprint_mismatch');
      expect(
        await Process.run('kill', ['-0', '${process.pid}']),
        isA<ProcessResult>().having((result) => result.exitCode, 'exit', 0),
      );

      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }, skip: Platform.isWindows);

    test('persisted fingerprint reclaims an orphaned process group', () async {
      final process = await Process.start('setsid', ['sh', '-c', 'sleep 30']);
      final tree = ProcessTreeController.attach(
        process,
        usesProcessGroup: true,
      );
      final restored = ProcessFingerprint.tryParse(tree.fingerprint.toJson());

      final report = await ProcessTreeController.terminatePersisted(
        restored!,
        gracePeriod: const Duration(milliseconds: 100),
      );

      expect(
        report.outcome,
        anyOf(
          ToolProcessCleanupOutcome.exited,
          ToolProcessCleanupOutcome.escalated,
        ),
      );
      await process.exitCode;
    }, skip: !Platform.isLinux);

    test(
      'natural wrapper exit still kills a TERM-resistant descendant',
      () async {
        final workspace = await Directory.systemTemp.createTemp('tree-natural');
        final childPidFile = File('${workspace.path}/child.pid');
        final process = await Process.start('setsid', [
          'sh',
          '-c',
          "trap '' TERM; sleep 30 & echo \"\$!\" > ${childPidFile.path}; exit 0",
        ]);
        final tree = ProcessTreeController.attach(
          process,
          usesProcessGroup: true,
        );
        await process.exitCode;

        final report = await tree.completeNaturally(
          gracePeriod: const Duration(milliseconds: 50),
        );

        expect(report.outcome, ToolProcessCleanupOutcome.escalated);
        final childPid = childPidFile.readAsStringSync().trim();
        expect(
          (await Process.run('kill', ['-0', childPid])).exitCode,
          isNot(0),
        );
        await workspace.delete(recursive: true);
      },
      skip: !Platform.isLinux,
    );
  });
}
