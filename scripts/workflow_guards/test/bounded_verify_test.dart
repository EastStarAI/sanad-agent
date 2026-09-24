import 'dart:io';

import 'package:sanad_workflow_guards/bounded_verify.dart';
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late String childDir;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('wf-guards-verify-');
    childDir = sandbox.path;
  });

  tearDown(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeChild(String name, String body) {
    final file = File('$childDir${Platform.pathSeparator}$name');
    file.writeAsStringSync(body);
    return file.path;
  }

  String passChild() => writeChild('pass_child.dart', '''
void main() {
  for (var i = 0; i < 300; i++) {
    print('pass line \$i');
  }
}
''');

  String failChild() => writeChild('fail_child.dart', '''
import 'dart:io';
void main() {
  for (var i = 0; i < 300; i++) {
    stderr.writeln('fail line \$i');
  }
  exit(7);
}
''');

  String mixedChild() => writeChild('mixed_child.dart', '''
import 'dart:io';
void main() {
  print('stdout before failure');
  stderr.writeln('stderr explaining failure');
  exit(3);
}
''');

  group('bounded runner core', () {
    test('preserves exit 0 and logs the complete large stdout', () async {
      final result = await runBounded(
        Platform.resolvedExecutable,
        [passChild()],
        options: VerifyOptions(tail: 5, tempRoot: childDir),
      );
      expect(result.error, isNull);
      expect(result.exitCode, 0);
      expect(result.elapsedMs, greaterThanOrEqualTo(0));
      expect(result.stdoutTail, hasLength(5));
      expect(result.stdoutTail.last, 'pass line 299');

      final log = File(result.logPath).readAsStringSync();
      expect(log, contains('pass line 0'));
      expect(log, contains('pass line 299'));
      // The full log is captured even though the console only shows the tail.
      expect('pass line '.allMatches(log).length, 300);
    });

    test('preserves an intentional nonzero exit and bounds the stderr error section', () async {
      final result = await runBounded(
        Platform.resolvedExecutable,
        [failChild()],
        options: VerifyOptions(tail: 5, tempRoot: childDir),
      );
      expect(result.exitCode, 7);
      expect(result.stderrTail, hasLength(5));
      expect(result.stderrTail.last, 'fail line 299');

      final log = File(result.logPath).readAsStringSync();
      expect('fail line '.allMatches(log).length, 300);
      expect(log, contains('fail line 0'));
    });

    test('bounded tails never exceed the requested window', () async {
      final result = await runBounded(
        Platform.resolvedExecutable,
        [mixedChild()],
        options: VerifyOptions(tail: 1, tempRoot: childDir),
      );
      expect(result.exitCode, 3);
      expect(result.stdoutTail, ['stdout before failure']);
      expect(result.stderrTail, ['stderr explaining failure']);
      expect(result.elapsedMs, greaterThanOrEqualTo(0));
    });

    if (Platform.isWindows) {
      test('windows .cmd test target runs fail-closed with its own exit code', () async {
        final cmd = File('$childDir${Platform.pathSeparator}runner.cmd')
          ..writeAsStringSync(
            '@echo off\r\n'
            'echo cmd line 1\r\n'
            'echo cmd line 2\r\n'
            'echo cmd line 3\r\n'
            'exit /b 9\r\n',
          );
        final result = await runBounded(
          cmd.path,
          const [],
          options: VerifyOptions(tail: 2, tempRoot: childDir),
        );
        expect(result.exitCode, 9);
        expect(result.stdoutTail, ['cmd line 2', 'cmd line 3']);
        final log = File(result.logPath).readAsStringSync();
        expect(log, contains('cmd line 1'));
      });
    }

    test('rejects shell metacharacters without executing them', () async {
      final result = await runBounded(
        'echo & dir',
        const [],
        options: VerifyOptions(tail: 5, tempRoot: childDir),
      );
      expect(result.error, contains('refusing'));
      expect(result.exitCode, 2);
    });

    if (Platform.isWindows) {
      test('rejects shell metacharacters in batch arguments', () async {
        final cmd = File('$childDir${Platform.pathSeparator}arg_runner.cmd')
          ..writeAsStringSync('@echo off\r\n');
        final result = await runBounded(
          cmd.path,
          const ['a & b'],
          options: VerifyOptions(tail: 5, tempRoot: childDir),
        );
        expect(result.error, contains('refusing shell-executed argument'));
        expect(result.exitCode, 2);
      });
    }

    test('missing child reports a closed tool error', () async {
      final missing = '$childDir${Platform.pathSeparator}no-such-child'
          '${Platform.isWindows ? '.exe' : ''}';
      final result = await runBounded(
        missing,
        const [],
        options: VerifyOptions(tail: 5, tempRoot: childDir),
      );
      expect(result.error, contains('could not be started'));
      expect(result.exitCode, 2);
    });
  });

  group('verify CLI end-to-end (exact supported invocation)', () {
    final bin = File('${Directory.current.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}verify.dart');

    late Directory cliChildren;
    late String passCli;
    late String failCli;

    setUp(() {
      cliChildren = Directory.systemTemp.createTempSync('wf-guards-verify-cli-');
      final passFile = File('${cliChildren.path}${Platform.pathSeparator}pass_cli.dart')
        ..writeAsStringSync('''
void main() { for (var i = 0; i < 120; i++) { print('cli pass line \$i'); } }
''');
      passCli = passFile.path;
      final failFile = File('${cliChildren.path}${Platform.pathSeparator}fail_cli.dart')
        ..writeAsStringSync('''
import 'dart:io';
void main() { for (var i = 0; i < 120; i++) { stderr.writeln('cli fail line \$i'); } exit(11); }
''');
      failCli = failFile.path;
    });

    tearDown(() {
      try {
        cliChildren.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('real passing test: exit 0, bounded console, complete log', () async {
      final run = await Process.run(
        Platform.resolvedExecutable,
        [bin.path, '--tail', '5', '--', Platform.resolvedExecutable, passCli],
        workingDirectory: Directory.current.path,
      );
      expect(run.exitCode, 0);
      final stdoutText = run.stdout as String;
      final consoleLines =
          stdoutText.split('\n').where((l) => l.isNotEmpty).toList();
      // Bounded console: the 5-line tail plus a single summary line.
      expect(consoleLines.length, lessThanOrEqualTo(6));
      expect(stdoutText, contains('cli pass line 119'));

      final summary = consoleLines.lastWhere((l) => l.startsWith('verify:'));
      final logPath = summary.split('log ').last.trim();
      final log = File(logPath).readAsStringSync();
      expect('cli pass line '.allMatches(log).length, 120);
      expect(summary, contains('elapsed '));
      expect(summary, contains('| exit 0 |'));
    });

    test('real intentionally failing test: exact exit code propagates', () async {
      final run = await Process.run(
        Platform.resolvedExecutable,
        [bin.path, '--tail', '5', '--', Platform.resolvedExecutable, failCli],
        workingDirectory: Directory.current.path,
      );
      // The intentional child failure code must propagate exactly.
      expect(run.exitCode, 11);
      final stdoutText = run.stdout as String;
      final stderrText = run.stderr as String;
      expect(stdoutText, contains('| exit 11 |'));
      expect(stderrText, contains('cli fail line 119'));
      final summaryLine =
          stdoutText.split('\n').firstWhere((l) => l.startsWith('verify:'));
      final logPath = summaryLine.split('log ').last.trim();
expect(
        'cli fail line '.allMatches(File(logPath).readAsStringSync()).length,
        120,
      );
    });
  });
}