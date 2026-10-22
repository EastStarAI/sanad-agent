import 'dart:async';
import 'dart:io';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:test/test.dart';

/// Minimal child-process stand-in for the wall-clock guard.

void main() {
  group('sanad-dev ui run plan', () {
    test('forwards driver arguments and strips launcher-owned flags', () {
      final plan = sanad_dev.planUiDriverRun([
        'tap',
        '--key',
        'send_message_btn',
        '--home',
        '/tmp/home',
        '--no-activate',
        '--wall-timeout',
        '45',
        '--json',
      ]);

      expect(plan.driverArguments, [
        'tap',
        '--key',
        'send_message_btn',
        '--json',
      ]);
      expect(plan.activateWindow, isFalse);
      expect(plan.wallTimeout, const Duration(seconds: 45));
      expect(plan.isHelpRequest, isFalse);
      expect(plan.hasExplicitVmUrl, isFalse);
    });

    test('defaults to a 30s action plus grace and activates the window', () {
      final plan = sanad_dev.planUiDriverRun(['snapshot', '--json']);
      expect(plan.wallTimeout, const Duration(seconds: 40));
      expect(plan.activateWindow, isTrue);
      // Read-only commands never take focus from the user.
      expect(plan.activatesUi, isFalse);
    });

    test('honours an explicit per-action timeout', () {
      final plan = sanad_dev.planUiDriverRun([
        'wait-for',
        '--text',
        'Ready',
        '--timeout',
        '90',
      ]);
      expect(plan.wallTimeout, const Duration(seconds: 100));
    });

    test('adds the verification window and post-delay to a tap deadline', () {
      final plan = sanad_dev.planUiDriverRun(['tap', '--key', 'send_button']);
      // 30 s action + 10 s grace + 300 ms post-delay + 2000 ms verification.
      expect(plan.wallTimeout, const Duration(milliseconds: 42300));
      expect(plan.activatesUi, isTrue);
    });

    test('honours explicit verification options in the tap deadline', () {
      final plan = sanad_dev.planUiDriverRun([
        'tap',
        '--key',
        'send_button',
        '--delay',
        '50',
        '--verify-timeout',
        '500',
        '--timeout',
        '5',
      ]);
      expect(plan.wallTimeout, const Duration(milliseconds: 15550));
    });

    test('scales the wall clock with each step timeout and wait', () {
      final plan = sanad_dev.planUiDriverRun(
        ['batch', '--file', 'recipe.json'],
        batchSteps: const [
          sanad_dev.UiDriverBatchStepBudget(
            action: 'tap',
            timeoutSeconds: 60,
          ),
          sanad_dev.UiDriverBatchStepBudget(action: 'sleep', sleepMs: 5000),
          sanad_dev.UiDriverBatchStepBudget(action: 'wait_for'),
        ],
      );
      // 60 + delay/verify 3 s + 5 s sleep + 30 s wait + 10 s grace.
      expect(plan.wallTimeout, const Duration(seconds: 108));
      expect(plan.isBatch, isTrue);
    });

    test('uses the explicit step budget for batch recipes', () {
      final plan = sanad_dev.planUiDriverRun(
        ['batch', '--json-steps', '[]', '--timeout', '5'],
        batchSteps: const [
          sanad_dev.UiDriverBatchStepBudget(action: 'scroll'),
          sanad_dev.UiDriverBatchStepBudget(action: 'wait_for'),
        ],
      );
      expect(plan.wallTimeout, const Duration(seconds: 20));
    });

    test('falls back to a bounded batch wall clock for stdin recipes', () {
      final plan = sanad_dev.planUiDriverRun(['batch']);
      expect(
        plan.wallTimeout,
        const Duration(seconds: sanad_dev.uiDriverBatchDefaultWallSeconds),
      );
    });

    test('parses batch budgets from the recipe without a live client', () {
      final steps = sanad_dev.readUiDriverBatchSteps([
        'batch',
        '--json-steps',
        '[{"action":"tap","timeout_seconds":45,"delay_ms":100},'
            '{"action":"sleep","sleep_ms":2500},'
            '{"action":"wait_for","timeout":12}]',
      ]);
      expect(steps, isNotNull);
      expect(steps!.length, 3);
      expect(steps.first.timeoutSeconds, 45);
      expect(steps.first.delayMs, 100);
      expect(steps[1].sleepMs, 2500);
      expect(steps[2].timeoutSeconds, 12);
      expect(
        sanad_dev.uiDriverBatchBudgetSeconds(steps),
        // 45 s tap + 1 s delay + 2 s verify, 3 s sleep, 12 s wait.
        63,
      );
    });

    test('detects explicit VM endpoints and help requests', () {
      expect(
        sanad_dev
            .planUiDriverRun(['tap', '--vm-url', 'http://127.0.0.1:5/t'])
            .hasExplicitVmUrl,
        isTrue,
      );
      expect(
        sanad_dev.planUiDriverRun(['tap', '-u=http://127.0.0.1:5/t'])
            .hasExplicitVmUrl,
        isTrue,
      );
      expect(sanad_dev.planUiDriverRun([]).isHelpRequest, isTrue);
      expect(sanad_dev.planUiDriverRun(['--help']).isHelpRequest, isTrue);
    });

    test('counts recipe steps without a live client', () {
      expect(
        sanad_dev.uiDriverBatchStepCount([
          'batch',
          '--json-steps',
          '[{"action":"tap"},{"action":"wait_for"}]',
        ]),
        2,
      );
      expect(
        sanad_dev.uiDriverBatchStepCount(['batch', '--json-steps', 'not-json']),
        isNull,
      );
    });

    test('never swallows a driver value that equals a launcher flag', () {
      final plan = sanad_dev.planUiDriverRun([
        'enter-text',
        '--key',
        'chat_input',
        '--text',
        '--home',
      ]);
      expect(plan.driverArguments, [
        'enter-text',
        '--key',
        'chat_input',
        '--text',
        '--home',
      ]);

      // A leading launcher flag block is still stripped, and a launcher flag
      // after the sub-command is honored because it is not a driver value.
      final leading = sanad_dev.planUiDriverRun([
        '--home',
        '/tmp/home',
        '--no-activate',
        'tap',
        '--key',
        'send_button',
        '--no-activate',
      ]);
      expect(leading.driverArguments, ['tap', '--key', 'send_button']);
      expect(leading.activateWindow, isFalse);
    });

    test('supports an explicit end of launcher flags', () {
      final plan = sanad_dev.planUiDriverRun([
        '--no-activate',
        '--',
        'enter-text',
        'abc',
        '--home',
      ]);
      expect(plan.driverArguments, ['enter-text', 'abc', '--home']);
      expect(plan.activateWindow, isFalse);
    });
  });

  group('sanad-dev ui driver artifact cache', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('sanad-dev-ui-artifact');
      Directory('${root.path}/scripts/flutter_driver_cli').createSync(
        recursive: true,
      );
      File('${root.path}/scripts/flutter_driver_cli.dart')
          .writeAsStringSync('void main() {}');
      File('${root.path}/scripts/flutter_driver_cli/cli_runner.dart')
          .writeAsStringSync('// runner');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('fingerprint follows content, not key order', () {
      final first = sanad_dev.uiDriverSourceFingerprint({
        'b.dart': 'bb',
        'a.dart': 'aa',
      });
      final reordered = sanad_dev.uiDriverSourceFingerprint({
        'a.dart': 'aa',
        'b.dart': 'bb',
      });
      final changed = sanad_dev.uiDriverSourceFingerprint({
        'a.dart': 'aa',
        'b.dart': 'bc',
      });

      expect(reordered, first);
      expect(changed, isNot(first));
    });

    test('artifact path carries the fingerprint and platform suffix', () {
      final posix = sanad_dev.uiDriverArtifactPath(
        repositoryRoot: '/repo',
        fingerprint: 'abc123',
        isWindows: false,
      );
      final windows = sanad_dev.uiDriverArtifactPath(
        repositoryRoot: '/repo',
        fingerprint: 'abc123',
        isWindows: true,
      );

      expect(
        posix,
        '/repo/.dart_tool/sanad-dev/flutter-driver-cli-abc123',
      );
      expect(windows, endsWith('.exe'));
    });

    test('compiles once and reuses the matching artifact', () async {
      var compileCount = 0;
      Future<bool> compile(String outputPath) async {
        compileCount++;
        File(outputPath).writeAsStringSync('artifact');
        return true;
      }

      final first = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
      );
      final second = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
      );

      expect(first, isNotNull);
      expect(second, first);
      expect(File(first!).existsSync(), isTrue);
      expect(compileCount, 1);
    });

    test('a source change produces a new artifact and prunes the stale one',
        () async {
      Future<bool> compile(String outputPath) async {
        File(outputPath).writeAsStringSync('artifact');
        return true;
      }

      final stale = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
      );
      File('${root.path}/scripts/flutter_driver_cli/cli_runner.dart')
          .writeAsStringSync('// runner changed');
      final fresh = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
      );

      expect(fresh, isNotNull);
      expect(fresh, isNot(stale));
      expect(File(stale!).existsSync(), isFalse);
      expect(File(fresh!).existsSync(), isTrue);
    });

    test('a failed compilation falls back without leaving a partial file',
        () async {
      final artifact = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: (outputPath) async {
          File(outputPath).writeAsStringSync('broken');
          return false;
        },
        isWindows: false,
      );

      expect(artifact, isNull);
      final leftovers = Directory('${root.path}/.dart_tool/sanad-dev')
          .existsSync()
          ? Directory('${root.path}/.dart_tool/sanad-dev')
                .listSync()
                .map((entity) => entity.path)
                .toList()
          : <String>[];
      expect(leftovers, isEmpty);
    });

    test('a dependency change rebuilds the artifact', () async {
      Directory('${root.path}/client/.dart_tool').createSync(recursive: true);
      File('${root.path}/client/.dart_tool/package_config.json')
          .writeAsStringSync('{"packages":[]}');
      File(
        '${root.path}/client/pubspec.lock',
      ).writeAsStringSync('flutter_driver: 0.1.0');
      File('${root.path}/.fvmrc').writeAsStringSync('{"flutter":"3.35.0"}');
      var compileCount = 0;
      Future<bool> compile(String outputPath) async {
        compileCount++;
        File(outputPath).writeAsStringSync('artifact');
        return true;
      }

      final first = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
        sdkVersion: '3.9.0',
      );
      // An unchanged dependency set reuses the artifact.
      final second = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
        sdkVersion: '3.9.0',
      );
      expect(second, first);
      expect(compileCount, 1);

      File('${root.path}/client/pubspec.lock')
          .writeAsStringSync('flutter_driver: 0.2.0');
      final afterDependency = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
        sdkVersion: '3.9.0',
      );
      expect(afterDependency, isNot(first));
      expect(compileCount, 2);

      final afterSdk = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
        sdkVersion: '3.10.0',
      );
      expect(afterSdk, isNot(afterDependency));
      expect(compileCount, 3);

      File(
        '${root.path}/client/.dart_tool/package_config.json',
      ).writeAsStringSync('{"packages":[{"name":"changed"}]}');
      final afterConfig = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: compile,
        isWindows: false,
        sdkVersion: '3.10.0',
      );
      expect(afterConfig, isNot(afterSdk));
      expect(compileCount, 4);
    });

    test('fingerprint covers the SDK and the resolved package configuration',
        () {
      final sources = sanad_dev.readUiDriverSources(root.path);
      expect(sources.keys, contains('dart-sdk'));

      Directory('${root.path}/client').createSync(recursive: true);
      File('${root.path}/client/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"packages":[]}');
      final withConfig = sanad_dev.readUiDriverSources(root.path);
      expect(
        withConfig.keys,
        contains('client/.dart_tool/package_config.json'),
      );
      expect(
        sanad_dev.uiDriverSourceFingerprint(withConfig),
        isNot(sanad_dev.uiDriverSourceFingerprint(sources)),
      );
    });

    test('prune keeps another live invocation staging file', () async {
      final artifact = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: (outputPath) async {
          File(outputPath).writeAsStringSync('artifact');
          return true;
        },
        isWindows: false,
      );
      final staging = File(
        '${File(artifact!).parent.path}/flutter-driver-cli-other.$pid.tmp',
      )..writeAsStringSync('in-flight');

      File('${root.path}/scripts/flutter_driver_cli/cli_runner.dart')
          .writeAsStringSync('// runner changed again');
      await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: (outputPath) async {
          File(outputPath).writeAsStringSync('artifact');
          return true;
        },
        isWindows: false,
      );

      expect(staging.existsSync(), isTrue);
    });

    test('uses the JIT path when the artifact vanished before the spawn', () {
      const artifact = '/repo/.dart_tool/sanad-dev/flutter-driver-cli-abc';
      final missing = sanad_dev.planUiDriverInvocation(
        artifactPath: artifact,
        artifactExists: false,
        packageConfig: '/repo/client/.dart_tool/package_config.json',
        toolScript: '/repo/scripts/flutter_driver_cli.dart',
        driverArguments: const ['tap', '--key', 'send_button'],
        extraArguments: const ['--vm-url', 'http://127.0.0.1:51000/t/'],
      );
      expect(missing.usesJit, isTrue);
      expect(missing.executable, 'fvm');
      expect(missing.arguments.take(3), [
        'dart',
        '--packages=/repo/client/.dart_tool/package_config.json',
        '/repo/scripts/flutter_driver_cli.dart',
      ]);

      final present = sanad_dev.planUiDriverInvocation(
        artifactPath: artifact,
        artifactExists: true,
        packageConfig: '/repo/client/.dart_tool/package_config.json',
        toolScript: '/repo/scripts/flutter_driver_cli.dart',
        driverArguments: const ['tap', '--key', 'send_button'],
        extraArguments: const [],
      );
      expect(present.usesJit, isFalse);
      expect(present.executable, artifact);
      expect(present.arguments, ['tap', '--key', 'send_button']);
    });

    test('help requests never compile an artifact', () async {
      var compiled = false;
      final artifact = await sanad_dev.ensureUiDriverArtifact(
        repositoryRoot: root.path,
        compile: (outputPath) async {
          compiled = true;
          return true;
        },
        isWindows: false,
        allowCompile: false,
      );

      expect(artifact, isNull);
      expect(compiled, isFalse);
    });
  });
}
