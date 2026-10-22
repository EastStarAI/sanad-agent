import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:test/test.dart';

void main() {
  group('reset Home ownership', () {
    const userHome = '/users/developer';
    final worktreeHome = p.join(
      userHome,
      '.sanad',
      'dev',
      'homes',
      'feat-x-12345678',
    );

    sanad_dev.SanadDevResetHomeAssessment assess(
      String sanadHome, {
      bool isLinkedWorktree = true,
    }) => sanad_dev.assessSanadDevResetHome(
      runtime: runtime_context.SanadDevRuntime(
        workspaceRoot: '/repo/.agent/worktrees/lt-b2',
        repositoryRoot: '/repo',
        worktreeId: 'feat-x-12345678',
        isLinkedWorktree: isLinkedWorktree,
        usesPrimaryResources: !isLinkedWorktree,
        agentPort: 58092,
        vmServicePort: 51092,
        sanadHome: sanadHome,
        runtimeDirectory: '/runtime/feat-x-12345678',
        branch: 'feat/x',
      ),
      userHome: userHome,
    );

    test('accepts the worktree-scoped Test Home', () {
      final assessment = assess(worktreeHome);

      expect(assessment.allowed, isTrue);
      expect(
        assessment.classification,
        sanad_dev.SanadDevResetHomeClass.worktreeTestHome,
      );
    });

    test('accepts a nested path below the worktree Test Home', () {
      expect(assess(p.join(worktreeHome, 'nested')).allowed, isTrue);
    });

    test('refuses the primary user Home', () {
      final assessment = assess(p.join(userHome, '.sanad'));

      expect(assessment.allowed, isFalse);
      expect(
        assessment.classification,
        sanad_dev.SanadDevResetHomeClass.primaryUserHome,
      );
      expect(assessment.reason, contains('never reset'));
    });

    test('refuses another worktree Test Home and shared test homes', () {
      for (final home in [
        p.join(userHome, '.sanad', 'dev', 'homes', 'other-worktree-aabbccdd'),
        p.join(userHome, '.sanad-test-1'),
        p.join(userHome, 'tmp', 'home'),
      ]) {
        final assessment = assess(home);
        expect(assessment.allowed, isFalse, reason: home);
        expect(
          assessment.classification,
          isNot(sanad_dev.SanadDevResetHomeClass.worktreeTestHome),
        );
      }
    });

    test('refuses everything for a primary checkout with the default Home', () {
      final assessment = assess(
        p.join(userHome, '.sanad'),
        isLinkedWorktree: false,
      );

      expect(assessment.allowed, isFalse);
    });
  });

  group('reset flow', () {
    late Directory fixture;
    late Directory userHome;
    late Directory home;
    late Directory workspace;
    late runtime_context.SanadDevRuntime runtime;
    late List<String> events;
    // `exitCode` is process-global under package:test, so the handler reports
    // its status through an injected seam instead of the shared global.
    late List<int> exitCodes;

    Future<String> runReset({
      String? fixtureName,
      String? saveFixtureName,
      bool keepData = false,
      bool dryRun = false,
      bool stopFails = false,
      bool portsFree = true,
      bool startFails = false,
    }) async {
      final lines = <String>[];
      await sanad_dev.handleRuntimeReset(
        fixture: fixtureName,
        saveFixture: saveFixtureName,
        keepData: keepData,
        driverMode: true,
        dryRun: dryRun,
        device: 'macos',
        environment: {'HOME': userHome.path},
        runtimeProvider: ({sanadHomeOverride}) async => runtime,
        portsFreeProbe:
            (runtime, homePath, {agentPort}) async => portsFree,
        stopRuntime: (homePath) async {
          events.add('stop:$homePath');
          return !stopFails;
        },
        startRuntime:
            ({
              required runtime,
              required homePath,
              required driverMode,
              required device,
            }) async {
              events.add('start:${runtime.worktreeId}:$driverMode:$device');
              return !startFails;
            },
        printMessage: lines.add,
        printError: (message) => lines.add(message),
        setExitCode: exitCodes.add,
      );
      return lines.join('\n');
    }

    setUp(() async {
      fixture = await Directory.systemTemp.createTemp('sanad-reset-');
      userHome = Directory(p.join(fixture.path, 'user'))..createSync();
      workspace = Directory(p.join(fixture.path, 'lt-b2'))..createSync();
      home = Directory(
        p.join(userHome.path, '.sanad', 'dev', 'homes', 'feat-x-12345678'),
      )..createSync(recursive: true);
      // `reset` resolves the Home once and uses the canonical path for every
      // stop, restore, and launch step, so the fixture Home is canonical too.
      home = Directory(home.resolveSymbolicLinksSync());
      await File(p.join(home.path, 'state.db')).writeAsString('database');
      await File(p.join(home.path, 'config.yaml')).writeAsString('model: x');
      await File(p.join(home.path, '.local_token')).writeAsString('secret');
      runtime = runtime_context.SanadDevRuntime(
        workspaceRoot: workspace.path,
        repositoryRoot: p.join(fixture.path, 'repo'),
        worktreeId: 'feat-x-12345678',
        isLinkedWorktree: true,
        usesPrimaryResources: false,
        // Reserved but unbound so the port probe reports them free.
        agentPort: 58092,
        vmServicePort: 51092,
        sanadHome: home.path,
        runtimeDirectory: p.join(fixture.path, 'runtime'),
        branch: 'feat/x',
      );
      Directory(runtime.repositoryRoot).createSync(recursive: true);
      events = [];
      exitCodes = [];
      exitCode = 0;
    });

    tearDown(() async {
      if (fixture.existsSync()) await fixture.delete(recursive: true);
      exitCode = 0;
    });

    test('dry run prints the plan without touching anything', () async {
      final output = await runReset(dryRun: true);

      expect(output, contains('Test home: ${home.path}'));
      expect(output, contains('Data: keep existing data'));
      expect(output, contains('Mode: interactive-driver'));
      expect(events, isEmpty);
      expect(exitCodes, isEmpty);
    });

    test('keeps data by default and prints one summary line', () async {
      final output = await runReset();

      expect(events.first, 'stop:${home.path}');
      expect(events.last, 'start:feat-x-12345678:true:macos');
      expect(output, contains('Kept existing Home data'));
      final summary = output
          .split('\n')
          .singleWhere((line) => line.startsWith('reset: '));
      expect(summary, contains('agent=58092'));
      expect(summary, contains('vm=51092'));
      expect(summary, contains('state=stopped'));
      expect(summary, contains('fixture=kept'));
      expect(summary, contains(' sha='));
      expect(exitCodes, isEmpty);
    });

    test('saves a fixture before restoring the requested one', () async {
      await File(p.join(home.path, 'state.db')).writeAsString('database-v2');
      final output = await runReset(
        saveFixtureName: 'before',
        fixtureName: 'missing',
      );

      // The save happens before the restore, so the failure still leaves the
      // captured fixture behind.
      expect(
        File(
          p.join(
            workspace.path,
            '.sanad-dev',
            'fixtures',
            'before',
            'fixture.json',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(output, contains('Saved fixture "before"'));
      expect(events.first, startsWith('stop:'));
      expect(events, hasLength(1));
      expect(exitCodes, isNotEmpty);
      expect(exitCodes.last, isNot(0));
    });

    test('restores a saved fixture and reports the file counts', () async {
      await File(p.join(home.path, 'state.db')).writeAsString('database-v2');
      final save = await runReset(saveFixtureName: 'clean');
      expect(save, contains('Saved fixture "clean"'));
      await File(p.join(home.path, 'state.db')).writeAsString('database-v3');

      final output = await runReset(fixtureName: 'clean');

      expect(output, contains('Restored fixture "clean"'));
      expect(
        File(p.join(home.path, 'state.db')).readAsStringSync(),
        'database-v2',
      );
      expect(
        File(p.join(home.path, '.local_token')).readAsStringSync(),
        'secret',
        reason: 'the gateway credential is never part of a fixture',
      );
      expect(output, contains('fixture=clean'));
    });

    test('refuses an invalid fixture name before stopping', () async {
      final output = await runReset(fixtureName: 'Bad Name');

      expect(output, contains('Invalid fixture name'));
      expect(events, isEmpty);
      expect(exitCodes, [64]);
    });

    test('rejects --fixture with --keep-data', () async {
      final output = await runReset(fixtureName: 'clean', keepData: true);

      expect(output, contains('cannot be combined'));
      expect(events, isEmpty);
      expect(exitCodes, [64]);
    });

    test('refuses to continue when the stop fails', () async {
      await runReset(stopFails: true);

      expect(events, ['stop:${home.path}']);
      expect(exitCodes, isNotEmpty);
      expect(exitCodes.last, isNot(0));
    });

    test('stops before the port check and refuses when ports stay busy', () async {
      final output = await runReset(portsFree: false);

      expect(events, ['stop:${home.path}']);
      expect(output, contains('or a managed Client endpoint is still live'));
      expect(exitCodes, [1]);
    });

    test('reports a failed restart and keeps exit 1', () async {
      // An Agent that cannot start makes the restart fail; reset must report it
      // and return nonzero instead of claiming a running runtime.
      final output = await runReset(startFails: true);

      expect(events, ['stop:${home.path}', 'start:feat-x-12345678:true:macos']);
      expect(output, contains('Restarting this worktree runtime failed'));
      expect(output, contains('Rerun "sanad-dev run"'));
      expect(output, isNot(contains('reset: ')));
      expect(exitCodes, [1]);
    });

    test('refuses a Home this worktree does not own', () async {
      runtime = runtime_context.SanadDevRuntime(
        workspaceRoot: workspace.path,
        repositoryRoot: p.join(fixture.path, 'repo'),
        worktreeId: 'feat-x-12345678',
        isLinkedWorktree: true,
        usesPrimaryResources: false,
        agentPort: 58092,
        vmServicePort: 51092,
        sanadHome: p.join(userHome.path, '.sanad'),
        runtimeDirectory: p.join(fixture.path, 'runtime'),
        branch: 'feat/x',
      );

      final output = await runReset();

      expect(output, contains('Refusing to reset'));
      expect(output, contains('never reset'));
      expect(events, isEmpty);
      expect(exitCodes, [64]);
    });

    test('is wired into the CLI parser', () {
      final parsed = sanad_dev.parseSanadDevInvocation(const [
        'reset',
        '--fixture',
        'clean',
        '--save-fixture=before',
        '--keep-data',
        '--include-mcp-config',
      ]);

      expect(parsed!.command, 'reset');
      expect(parsed.fixtureName, 'clean');
      expect(parsed.saveFixtureName, 'before');
      expect(parsed.keepData, isTrue);
      expect(parsed.includeMcpConfig, isTrue);
    });
  });

}
