import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:sanad_dev/src/infrastructure/scheduled_refresh.dart';
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late runtime_context.SanadDevRuntime runtime;
  late List<String> lines;
  late List<String> errors;
  late List<int> exitCodes;

  Future<void> invoke(
    String at, {
    SanadDevRefreshScheduler scheduler = SanadDevRefreshScheduler.systemdRun,
    sanad_dev.SanadDevRefreshLauncher? launcher,
    Future<ProcessResult> Function(List<String> arguments)? runScheduler,
  }) async {
    await sanad_dev.handleRuntimeRefresh(
      at: at,
      scheduler: scheduler,
      runtimeProvider: ({sanadHomeOverride}) async => runtime,
      sourceCommit: (repositoryRoot) async => 'abc1234',
      launcher: launcher,
      runScheduler: runScheduler,
      printMessage: lines.add,
      printError: errors.add,
      setExitCode: exitCodes.add,
    );
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-refresh-');
    runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: fixture.path,
      repositoryRoot: p.join(fixture.path, 'repo'),
      worktreeId: 'feat-x-12345678',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58092,
      vmServicePort: 51092,
      sanadHome: p.join(fixture.path, 'home'),
      runtimeDirectory: p.join(fixture.path, 'runtime'),
      branch: 'feat/runtime-reset',
    );
    Directory(runtime.repositoryRoot).createSync(recursive: true);
    lines = [];
    errors = [];
    exitCodes = [];
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  group('scheduled refresh', () {
    test('a scheduler failure is reported, returns non-zero, and is cleaned up',
        () async {
      // The real launcher writes the script, chmods it, then hands it to the
      // scheduler. A `systemd-run`/`schtasks` failure must not print a success
      // summary or leave a script that looks like a pending refresh.
      await invoke(
        '+2m',
        scheduler: SanadDevRefreshScheduler.systemdRun,
        runScheduler: (arguments) async =>
            ProcessResult(1, 127, '', 'systemd-run: command not found'),
      );

      expect(exitCodes, [1]);
      expect(errors.single, contains('Could not schedule the refresh'));
      expect(errors.single, contains('systemd-run: command not found'));
      expect(
        lines.where((line) => line.startsWith('Scheduled ')),
        isEmpty,
        reason: 'a failed schedule must never print the success summary',
      );
      final refreshDirectory = Directory(
        p.join(runtime.runtimeDirectory, 'refresh'),
      );
      expect(
        refreshDirectory.existsSync()
            ? refreshDirectory
                .listSync()
                .whereType<File>()
                .where((file) => file.path.endsWith('.sh'))
                .toList()
            : const <File>[],
        isEmpty,
        reason: 'the refresh script is deleted when the schedule fails',
      );
    });

    test('a failed scheduler keeps the script for no replay', () async {
      await invoke(
        '+2m',
        scheduler: SanadDevRefreshScheduler.schtasks,
        runScheduler: (arguments) async =>
            ProcessResult(1, 1, '', 'ERROR: The specified time is invalid.'),
      );

      expect(exitCodes, [1]);
      expect(
        errors.single,
        contains('ERROR: The specified time is invalid.'),
      );
      expect(
        Directory(
          p.join(runtime.runtimeDirectory, 'refresh'),
        ).listSync().isEmpty,
        isTrue,
      );
    });

    test('a scheduled refresh prints the verification lines', () async {
      await invoke(
        '+2m',
        launcher: (plan, {required homePath}) async =>
            const sanad_dev.SanadDevRefreshLaunchOutcome.scheduled(),
      );

      expect(exitCodes, isEmpty);
      expect(errors, isEmpty);
      expect(lines.first, startsWith('Scheduled '));
      expect(lines, contains('Home: ${runtime.sanadHome}'));
      expect(lines.any((line) => line.contains('sanad-dev status')), isTrue);
    });

    test('an invalid delay is a usage error and schedules nothing', () async {
      await invoke('2m');

      expect(exitCodes, [64]);
      expect(errors.single, contains('Invalid --at value'));
      expect(lines, isEmpty);
    });
  });
}
