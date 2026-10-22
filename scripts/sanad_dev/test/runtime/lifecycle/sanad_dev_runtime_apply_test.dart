import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/foreign_worktree_activity.dart'
    as activity;
import 'package:test/test.dart';

import '../../support/sanad_dev_test_fixtures.dart';

void main() {
  group('apply decision table', () {
    List<sanad_dev.SanadDevApplyAction> actionsFor(List<String> paths) =>
        sanad_dev.decideSanadDevApply(changedPaths: paths).actions;

    test('Dart UI-only client changes reload the client', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: ['client/lib/features/composer/composer_view.dart'],
      );

      expect(decision.actions, [sanad_dev.SanadDevApplyAction.reloadClient]);
      expect(decision.actionLabel, 'reload client');
      expect(decision.reasons.single, contains('Dart UI-only Client change'));
      expect(
        decision.reasons.single,
        contains('client/lib/features/composer/composer_view.dart'),
      );
    });

    test('client startup and DI Dart restart the client', () {
      for (final path in const [
        'client/lib/main.dart',
        'client/lib/driver_main.dart',
        'client/lib/app/bootstrap/app_bootstrap.dart',
        'client/lib/core/startup/startup_gate.dart',
        'client/lib/core/di/service_locator.dart',
      ]) {
        expect(actionsFor([path]), [
          sanad_dev.SanadDevApplyAction.restartClient,
        ], reason: '$path must restart the client');
      }
    });

    test('pubspec, native, plugin and asset changes need stop + run', () {
      for (final path in const [
        'client/pubspec.yaml',
        'client/pubspec.lock',
        'client/macos/Runner/Info.plist',
        'client/macos/Flutter/GeneratedPluginRegistrant.swift',
        'client/windows/runner/main.cpp',
        'client/linux/CMakeLists.txt',
        'client/web/index.html',
        'client/assets/app-logo.png',
        'client/assets/fonts/inter.ttf',
        'client/assets/data/seed.json',
        'client/assets/README.md',
      ]) {
        expect(
          actionsFor([path]),
          [sanad_dev.SanadDevApplyAction.restartRuntime],
          reason:
              '$path is compiled into the desktop bundle, so a hot restart '
              'cannot apply it',
        );
      }
    });

    test('agent changes restart the agent only', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: ['agent/lib/cli/runner/commands/session_command.dart'],
      );

      expect(decision.actions, [sanad_dev.SanadDevApplyAction.restartAgent]);
      expect(decision.reasons.single, contains('Agent source changed'));
    });

    test('sanad-dev source changes stop and run the runtime', () {
      for (final path in const [
        'scripts/sanad_dev/lib/src/cli/cli.dart',
        'scripts/sanad-dev',
        'scripts/sanad-dev.ps1',
      ]) {
        expect(actionsFor([path]), [
          sanad_dev.SanadDevApplyAction.restartRuntime,
        ], reason: '$path must rebuild the prepared CLI and both components');
      }
    });

    test('a driver-mode change stops and runs even with no file changes', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: const [],
        driverModeChange: true,
      );

      expect(decision.actions, [sanad_dev.SanadDevApplyAction.restartRuntime]);
      expect(decision.reasons.single, contains('Driver-mode change'));
    });

    test('stop + run subsumes every lighter action', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: [
          'client/lib/main.dart',
          'agent/lib/daemon.dart',
          'scripts/sanad_dev/lib/src/cli/cli.dart',
        ],
      );

      expect(decision.actions, [sanad_dev.SanadDevApplyAction.restartRuntime]);
      expect(decision.reasons.length, 3);
    });

    test('mixed agent and client changes keep both restarts', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: [
          'agent/lib/daemon.dart',
          'client/lib/features/chat/chat_view.dart',
        ],
      );

      expect(decision.actions, [
        sanad_dev.SanadDevApplyAction.reloadClient,
        sanad_dev.SanadDevApplyAction.restartAgent,
      ]);
      expect(decision.actionLabel, 'reload client, restart agent');
    });

    test('shared packages restart both components', () {
      expect(actionsFor(['shared/auth_lock/lib/auth_lock.dart']), [
        sanad_dev.SanadDevApplyAction.restartClient,
        sanad_dev.SanadDevApplyAction.restartAgent,
      ]);
      expect(actionsFor(['release/contract/lib/release_contract.dart']), [
        sanad_dev.SanadDevApplyAction.restartClient,
        sanad_dev.SanadDevApplyAction.restartAgent,
      ]);
    });

    test('documentation, tests and CI need no runtime action', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: [
          'docs/technical/sanad_dev_runtime_ownership.md',
          'client/test/widget/composer_test.dart',
          'agent/test/daemon_test.dart',
          '.github/workflows/ci.yml',
          'README.md',
        ],
      );

      expect(decision.actions, isEmpty);
      expect(decision.actionLabel, 'none');
      expect(decision.reasons.single, contains('Documentation, tests or CI'));
    });

    test('an unclassified path restarts both components conservatively', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: ['tooling/unknown.txt'],
      );

      expect(decision.actions, [
        sanad_dev.SanadDevApplyAction.restartClient,
        sanad_dev.SanadDevApplyAction.restartAgent,
      ]);
      expect(decision.reasons.single, contains('Unclassified source change'));
    });

    test('normalizes separators and de-duplicates paths', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: [
          r'client\lib\features\chat\chat_view.dart',
          'client/lib/features/chat/chat_view.dart',
          '',
        ],
      );

      expect(decision.changedPaths, [
        'client/lib/features/chat/chat_view.dart',
      ]);
      expect(decision.actions, [sanad_dev.SanadDevApplyAction.reloadClient]);
    });

    test('prints at most three example paths per rule', () {
      final decision = sanad_dev.decideSanadDevApply(
        changedPaths: [
          for (var index = 0; index < 5; index++)
            'client/lib/features/w$index/view.dart',
        ],
      );

      expect(decision.reasons.single, contains('(+2 more)'));
    });
  });

  group('changed paths since the runtime started', () {
    late Directory fixture;
    late Directory repository;

    Future<void> git(List<String> arguments) async {
      final result = await Process.run('git', [
        '-C',
        repository.path,
        ...arguments,
      ]);
      if (result.exitCode != 0) {
        throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
      }
    }

    Future<String> head() async =>
        (await Process.run('git', [
          '-C',
          repository.path,
          'rev-parse',
          'HEAD',
        ])).stdout.toString().trim();

    setUp(() async {
      fixture = await Directory.systemTemp.createTemp('sanad-apply-diff-');
      repository = Directory(p.join(fixture.path, 'repo'))
        ..createSync(recursive: true);
      await git(['init', '-q']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'user.name', 'Test']);
      await File(p.join(repository.path, 'README.md')).writeAsString('one\n');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'first']);
    });

    tearDown(() async {
      if (fixture.existsSync()) await fixture.delete(recursive: true);
    });

    test('includes committed and uncommitted changes', () async {
      final start = await head();
      await File(p.join(repository.path, 'agent_change.dart')).writeAsString(
        '// committed\n',
      );
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'second']);
      await File(
        p.join(repository.path, 'client_change.dart'),
      ).writeAsString('// uncommitted\n');

      final changed = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
      );

      expect(changed.paths, contains('agent_change.dart'));
      expect(changed.paths, contains('client_change.dart'));
    });

    test('reports working-tree changes only without a start commit', () async {
      await File(p.join(repository.path, 'new_file.dart')).writeAsString('x');

      final changed = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: null,
      );

      expect(changed.paths, ['new_file.dart']);
    });

    test('unwraps porcelain rename entries', () async {
      await File(
        p.join(repository.path, 'old_name.dart'),
      ).writeAsString('content');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'add old']);
      await git(['mv', 'old_name.dart', 'new_name.dart']);

      final changed = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: 'HEAD',
      );

      expect(changed.paths, ['new_name.dart']);
    });

    test('an applied working-tree signature makes a repeat apply a no-op', () async {
      final start = await head();
      await File(
        p.join(repository.path, 'client_change.dart'),
      ).writeAsString('// uncommitted\n');
      final first = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
      );
      expect(first.paths, ['client_change.dart']);

      // This is exactly what `apply` records after a successful run.
      final repeated = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
        appliedWorktreeSignature: first.worktreeSignature,
      );

      expect(repeated.paths, isEmpty);
      expect(
        sanad_dev.decideSanadDevApply(changedPaths: repeated.paths).actions,
        isEmpty,
      );
    });

    test('a new edit after an applied baseline is reported again', () async {
      final start = await head();
      await File(
        p.join(repository.path, 'client_change.dart'),
      ).writeAsString('// first\n');
      final first = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
      );
      await File(
        p.join(repository.path, 'client_change.dart'),
      ).writeAsString('// second\n');

      final repeated = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
        appliedWorktreeSignature: first.worktreeSignature,
      );

      expect(repeated.paths, ['client_change.dart']);
    });
  });

  group('apply baseline record', () {
    test('round-trips and ignores an invalid record', () async {
      final directory = await Directory.systemTemp.createTemp('sanad-baseline-');
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'apply-baseline.json');

      expect(await sanad_dev.readSanadDevApplyBaseline(path), isNull);
      await sanad_dev.writeSanadDevApplyBaseline(
        path,
        const sanad_dev.SanadDevApplyBaseline(
          commit: 'abc1234',
          worktreeSignature: 'signature',
        ),
      );
      final restored = await sanad_dev.readSanadDevApplyBaseline(path);
      expect(restored!.commit, 'abc1234');
      expect(restored.worktreeSignature, 'signature');

      await File(path).writeAsString('not json');
      expect(await sanad_dev.readSanadDevApplyBaseline(path), isNull);

      await File(path).writeAsString(jsonEncode({'commit': '', 'worktree_signature': ''}));
      expect(await sanad_dev.readSanadDevApplyBaseline(path), isNull);
    });
  });

  group('restart build guard', () {
    test('the real default detector runs without throwing', () async {
      // This exercises the production seam: the guard must call
      // `detectForeignWorktreeActivity` with its named parameter. A positional
      // call raised NoSuchMethodError before the seam was typed.
      final directory = await Directory.systemTemp.createTemp('sanad-guard-');
      addTearDown(() => directory.delete(recursive: true));
      final messages = <String>[];
      final exitCodes = <int>[];

      final refused = await sanad_dev.refuseRestartDuringForeignActivity(
        runtime: createTestRuntime(workspaceRoot: directory.path),
        force: false,
        printError: messages.add,
        setExitCode: exitCodes.add,
      );

      expect(refused, isFalse, reason: messages.join('\n'));
      expect(messages, isEmpty);
      expect(exitCodes, isEmpty);
    });

    test('refuses a restart while a foreign build runs', () async {
      final messages = <String>[];
      final exitCodes = <int>[];
      final refused = await sanad_dev.refuseRestartDuringForeignActivity(
        runtime: createTestRuntime(platformNeutral: true),
        force: false,
        detectActivity: ({required workspaceRoot}) async => const [
          activity.ForeignWorktreeActivity(
            pid: 42,
            command: 'flutter build macos',
          ),
        ],
        printError: messages.add,
        setExitCode: exitCodes.add,
      );

      expect(refused, isTrue);
      expect(messages.single, contains('Refusing to restart'));
      expect(messages.single, contains('PID 42'));
      expect(exitCodes, [1]);
    });

    test('--force bypasses the guard', () async {
      var probed = false;
      final refused = await sanad_dev.refuseRestartDuringForeignActivity(
        runtime: createTestRuntime(platformNeutral: true),
        force: true,
        detectActivity: ({required workspaceRoot}) async {
          probed = true;
          return const [
            activity.ForeignWorktreeActivity(pid: 42, command: 'dart test'),
          ];
        },
      );

      expect(refused, isFalse);
      expect(probed, isFalse);
    });

    test('allows the restart when nothing foreign is running', () async {
      final refused = await sanad_dev.refuseRestartDuringForeignActivity(
        runtime: createTestRuntime(platformNeutral: true),
        force: false,
        detectActivity: ({required workspaceRoot}) async => const [],
      );

      expect(refused, isFalse);
    });
  });
}
