import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:test/test.dart';

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

    test(
      'client startup, DI, pubspec, assets and native restart the client',
      () {
        for (final path in const [
          'client/lib/main.dart',
          'client/lib/driver_main.dart',
          'client/lib/app/bootstrap/app_bootstrap.dart',
          'client/lib/core/startup/startup_gate.dart',
          'client/lib/core/di/service_locator.dart',
          'client/pubspec.yaml',
          'client/pubspec.lock',
          'client/assets/app-logo.png',
          'client/macos/Runner/Info.plist',
          'client/windows/runner/main.cpp',
          'client/linux/CMakeLists.txt',
          'client/web/index.html',
        ]) {
          expect(actionsFor([path]), [
            sanad_dev.SanadDevApplyAction.restartClient,
          ], reason: '$path must restart the client');
        }
      },
    );

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
          'client/lib/main.dart',
          'client/lib/features/chat/chat_view.dart',
        ],
      );

      expect(decision.actions, [
        sanad_dev.SanadDevApplyAction.restartClient,
        sanad_dev.SanadDevApplyAction.restartAgent,
      ]);
      expect(decision.actionLabel, 'restart client, restart agent');
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
      final start = (await Process.run('git', [
        '-C',
        repository.path,
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim();
      final committed = File(p.join(repository.path, 'agent_change.dart'));
      await committed.writeAsString('// committed\n');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'second']);
      await File(
        p.join(repository.path, 'client_change.dart'),
      ).writeAsString('// uncommitted\n');

      final paths = await sanad_dev.changedPathsSince(
        repositoryRoot: repository.path,
        startCommit: start,
      );

      expect(paths, contains('agent_change.dart'));
      expect(paths, contains('client_change.dart'));
    });

    test('reports working-tree changes only without a start commit', () async {
      await File(p.join(repository.path, 'new_file.dart')).writeAsString('x');

      final paths = await sanad_dev.changedPathsSince(
        repositoryRoot: repository.path,
        startCommit: null,
      );

      expect(paths, ['new_file.dart']);
    });

    test('unwraps porcelain rename entries', () async {
      await File(
        p.join(repository.path, 'old_name.dart'),
      ).writeAsString('content');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'add old']);
      await git(['mv', 'old_name.dart', 'new_name.dart']);

      final paths = await sanad_dev.changedPathsSince(
        repositoryRoot: repository.path,
        startCommit: 'HEAD',
      );

      expect(paths, ['new_name.dart']);
    });
  });
}
