import 'dart:async';
import 'dart:io';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:test/test.dart';

/// Minimal child-process stand-in for the wall-clock guard.
class _FakeChild implements sanad_dev.UiDriverChildProcess {
  _FakeChild({required this.completesImmediately, this.exitStatus = 0});

  final bool completesImmediately;
  final int exitStatus;
  final Completer<int> _exit = Completer<int>();
  int killCount = 0;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill() {
    killCount++;
    if (!_exit.isCompleted) _exit.complete(-9);
  }

  void complete(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

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

    test('scales the wall clock with the batch step count', () {
      final plan = sanad_dev.planUiDriverRun(
        ['batch', '--file', 'recipe.json'],
        batchStepCount: 3,
      );
      expect(plan.wallTimeout, const Duration(seconds: 100));
    });

    test('uses the explicit step budget for batch recipes', () {
      final plan = sanad_dev.planUiDriverRun(
        ['batch', '--json-steps', '[]', '--timeout', '5'],
        batchStepCount: 2,
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

  group('sanad-dev ui child wall clock', () {
    test('returns the child exit status when it finishes in time', () async {
      final child = _FakeChild(completesImmediately: true, exitStatus: 3);
      scheduleMicrotask(() => child.complete(3));

      expect(
        await sanad_dev.awaitUiDriverChild(
          child,
          wallTimeout: const Duration(seconds: 5),
        ),
        3,
      );
      expect(child.killCount, 0);
    });

    test('kills the child and reports the timeout status', () async {
      final child = _FakeChild(completesImmediately: false);

      final code = await sanad_dev.awaitUiDriverChild(
        child,
        wallTimeout: const Duration(milliseconds: 30),
      );

      expect(code, sanad_dev.uiDriverTimeoutExitCode);
      expect(child.killCount, 1);
    });
  });

  group('sanad-dev ui owner window activation', () {
    test('derives the bundle root from the running executable', () {
      expect(
        sanad_dev.uiDriverBundlePath(
          '/repo/client/build/macos/Build/Products/Debug/sanad_client.app'
          '/Contents/MacOS/sanad_client',
        ),
        '/repo/client/build/macos/Build/Products/Debug/sanad_client.app',
      );
      expect(sanad_dev.uiDriverBundlePath('/usr/local/bin/tool'), isNull);
      expect(sanad_dev.uiDriverBundlePath(null), isNull);
    });

    test('does nothing without a macOS pid', () async {
      expect(
        await sanad_dev.activateUiDriverOwnerWindow(pid: null, isMacOS: true),
        isFalse,
      );
      expect(
        await sanad_dev.activateUiDriverOwnerWindow(pid: 42, isMacOS: false),
        isFalse,
      );
    });
  });
}
