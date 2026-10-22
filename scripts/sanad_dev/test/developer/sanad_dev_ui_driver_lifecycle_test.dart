import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:test/test.dart';

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

  group('sanad-dev ui process tree termination', () {
    test('resolves descendants deepest first', () {
      final tree = sanad_dev.parseUiDriverProcessTree('''
    1     0
  100     1
  101   100
  102   101
  200     1
''');
      expect(sanad_dev.uiDriverDescendantPids(tree, 100), [102, 101]);
      expect(sanad_dev.uiDriverDescendantPids(tree, 200), isEmpty);
    });

    test('kills a real grandchild so it cannot keep acting after a timeout',
        () async {
      // sh is the child (the `fvm` wrapper); sleep is its grandchild (the
      // `dart` process that would otherwise keep driving the UI).
      final process = await Process.start('sh', [
        '-c',
        'sleep 300 & echo \$!; wait',
      ]);
      final grandchildLine = await process.stdout
          .transform(const SystemEncoding().decoder)
          .firstWhere((line) => line.trim().isNotEmpty)
          .timeout(const Duration(seconds: 10));
      final grandchild = int.tryParse(grandchildLine.trim());
      expect(grandchild, isNotNull);

      sanad_dev.killUiDriverProcessTree(process.pid);

      final gone = await _waitUntil(() => !_isAlive(grandchild!));
      expect(gone, isTrue, reason: 'grandchild sleep survived the tree kill');
      expect(_isAlive(process.pid), isFalse);
    });

    test('aborts a compile that exceeds its deadline', () async {
      final stopwatch = Stopwatch()..start();
      final result = await sanad_dev.compileUiDriverArtifact(
        packageConfig: '/repo/client/.dart_tool/package_config.json',
        toolScript: '/repo/scripts/flutter_driver_cli.dart',
        workingDirectory: Directory.systemTemp.path,
        outputPath: '/repo/.dart_tool/sanad-dev/out',
        timeout: const Duration(milliseconds: 300),
        isWindows: false,
        spawn: (executable, arguments) =>
            Process.start('sh', ['-c', 'sleep 300 & echo \$! ; wait']),
      );

      expect(result.compiled, isFalse);
      expect(result.timedOut, isTrue);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
    });
  });

  group('sanad-dev ui partial batch evidence', () {
    test('reports the steps that completed before a kill', () {
      final directory = Directory.systemTemp.createTempSync('sanad-ui-partial');
      try {
        final report = File('${directory.path}/batch.json')
          ..writeAsStringSync(
            jsonEncode({
              'steps_total': 3,
              'completed': 2,
              'results': [
                {'success': true, 'action': 'tap'},
                {'success': true, 'action': 'wait_for'},
              ],
            }),
          );
        final partial = sanad_dev.uiDriverPartialBatchReport(report.path);
        expect(partial, isNotNull);
        final payload = jsonDecode(partial!) as Map<String, dynamic>;
        expect(payload['timed_out'], isTrue);
        expect(payload['partial'], isTrue);
        expect(payload['steps_total'], 3);
        expect(payload['total'], 2);
        expect(payload['passed'], 2);
        expect(payload['results'], hasLength(2));

        expect(
          sanad_dev.uiDriverPartialBatchReport('${directory.path}/missing.json'),
          isNull,
        );
        report.writeAsStringSync(jsonEncode({
          'steps_total': 1,
          'completed': 0,
          'results': [],
        }));
        expect(sanad_dev.uiDriverPartialBatchReport(report.path), isNull);
      } finally {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    });
  });

  group('sanad-dev ui owner window activation', () {
    const bundle =
        '/repo/client/build/macos/Build/Products/Debug/sanad_client.app';
    const executable = '$bundle/Contents/MacOS/sanad_client';

    test('derives the bundle root from the running executable', () {
      expect(sanad_dev.uiDriverBundlePath(executable), bundle);
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

    test('activates the single live instance of the owning bundle', () async {
      final opened = <List<String>>[];
      final activated = await sanad_dev.activateUiDriverOwnerWindow(
        pid: 42,
        isMacOS: true,
        readArguments: (pid) => [executable],
        bundleProcessIds: (path) async => [42],
        openApplication: (executable, arguments) async {
          opened.add(arguments);
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(activated, isTrue);
      expect(opened, [
        ['-a', bundle],
      ]);
    });

    test('skips activation when the discovered pid is dead', () async {
      var openCalls = 0;
      final activated = await sanad_dev.activateUiDriverOwnerWindow(
        pid: 42,
        isMacOS: true,
        // An empty argument vector is how a vanished pid is observed.
        readArguments: (pid) => const [],
        bundleProcessIds: (path) async => [42],
        openApplication: (executable, arguments) async {
          openCalls++;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(activated, isFalse);
      expect(openCalls, 0);
    });

    test('skips activation when several instances share the bundle', () async {
      var openCalls = 0;
      final activated = await sanad_dev.activateUiDriverOwnerWindow(
        pid: 42,
        isMacOS: true,
        readArguments: (pid) => [executable],
        bundleProcessIds: (path) async => [42, 43],
        openApplication: (executable, arguments) async {
          openCalls++;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(activated, isFalse);
      expect(openCalls, 0);
    });

    test('skips activation when the pid exited during the liveness scan',
        () async {
      var reads = 0;
      var openCalls = 0;
      final activated = await sanad_dev.activateUiDriverOwnerWindow(
        pid: 42,
        isMacOS: true,
        readArguments: (pid) {
          reads++;
          return reads == 1 ? [executable] : const [];
        },
        bundleProcessIds: (path) async => [42],
        openApplication: (executable, arguments) async {
          openCalls++;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(activated, isFalse);
      expect(openCalls, 0);
    });

    test('only UI-changing commands may take focus', () {
      for (final command in ['tap', 'enter-text', 'scroll', 'batch']) {
        expect(
          sanad_dev.planUiDriverRun([command, '--key', 'k']).activatesUi,
          isTrue,
          reason: '$command changes the UI',
        );
      }
      for (final command in ['snapshot', 'find', 'wait-for', 'screenshot']) {
        expect(
          sanad_dev.planUiDriverRun([command, '--key', 'k']).activatesUi,
          isFalse,
          reason: '$command is read-only',
        );
      }
      expect(
        sanad_dev
            .planUiDriverRun(['tap', '--key', 'k', '--no-activate'])
            .activatesUi,
        isFalse,
      );
    });
  });
}

/// True when [pid] is still visible in the host process table.
bool _isAlive(int pid) {
  try {
    final result = Process.runSync('ps', ['-p', '$pid', '-o', 'pid=']);
    return result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<bool> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return condition();
}
