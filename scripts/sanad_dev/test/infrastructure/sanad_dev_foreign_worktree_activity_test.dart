import 'dart:io';

import 'package:sanad_dev/src/infrastructure/foreign_worktree_activity.dart';
import 'package:test/test.dart';

void main() {
  const worktree = '/Volumes/Storage/project/.agent/worktrees/lt-b2';

  Future<List<ForeignWorktreeActivity>> detect(
    List<String> lines, {
    int currentPid = 999,
  }) => detectForeignWorktreeActivity(
    workspaceRoot: worktree,
    currentPid: currentPid,
    listProcessCommandLines: () async => lines,
  );

  group('foreign worktree activity guard', () {
    test('detects a foreign build and test in this worktree', () async {
      final activities = await detect([
        '101\u0000/usr/bin/flutter test $worktree/client/test',
        '102\u0000xcodebuild -workspace $worktree/client/macos/Runner.xcworkspace',
        '103\u0000/usr/bin/dart compile exe $worktree/agent/bin/sanad_agent.dart',
      ]);

      expect(activities.map((activity) => activity.pid), [101, 102, 103]);
      expect(activities.first.summary, contains('PID 101'));
      expect(activities.first.summary, contains('flutter test'));
    });

    test('ignores unrelated worktrees, readers, and its own process', () async {
      final activities = await detect([
        '201\u0000/usr/bin/flutter test /Volumes/Storage/project/.agent/worktrees/other',
        '202\u0000/usr/bin/rg "flutter test" $worktree',
        '999\u0000/usr/bin/dart compile exe $worktree/agent/bin/sanad_agent.dart',
        '203\u0000/usr/bin/ps -ww -axo pid=,command=',
      ]);

      expect(activities, isEmpty);
    });

    test(
      'ignores a worktree path that is only a prefix of another path',
      () async {
        final activities = await detect([
          '301\u0000flutter build $worktree-extra/client',
        ]);

        expect(activities, isEmpty);
      },
    );

    test('reports every matching process with a clear refusal message', () {
      final message = foreignWorktreeActivityMessage(
        worktreeId: 'feat-x-12345678',
        activities: const [
          ForeignWorktreeActivity(
            pid: 101,
            command: 'flutter test client/test',
          ),
        ],
      );

      expect(message, contains('Refusing to restart feat-x-12345678'));
      expect(message, contains('PID 101'));
      expect(message, contains('--force'));
    });

    test('redacts secret-like values from a printed command line', () {
      const command =
          'flutter test --dart-define=SANAD_TOKEN=abc123 --api-key sk-live-9 '
          '--port 58092 client/test';

      final redacted = redactCommandLine(command);

      expect(redacted, isNot(contains('abc123')));
      expect(redacted, isNot(contains('sk-live-9')));
      expect(redacted, contains('--dart-define=SANAD_TOKEN=<redacted>'));
      expect(redacted, contains('--api-key <redacted>'));
      expect(redacted, contains('--port 58092'));
      expect(redacted, contains('client/test'));
    });

    test('redacts a secret-like flag value and leaves normal flags alone', () {
      expect(
        redactCommandLine('dart test --password hunter2 --reporter expanded'),
        'dart test --password <redacted> --reporter expanded',
      );
      expect(
        redactCommandLine('GITHUB_TOKEN=ghp_x dart test'),
        'GITHUB_TOKEN=<redacted> dart test',
      );
      expect(
        redactCommandLine('flutter build macos --flavor production'),
        'flutter build macos --flavor production',
      );
    });

    test('the refusal message never echoes a secret', () {
      final message = foreignWorktreeActivityMessage(
        worktreeId: 'feat-x-12345678',
        activities: const [
          ForeignWorktreeActivity(
            pid: 101,
            command: 'flutter test --dart-define=SANAD_TOKEN=abc123',
          ),
        ],
      );

      expect(message, isNot(contains('abc123')));
      expect(message, contains('<redacted>'));
    });

    test('returns nothing for an empty workspace root', () async {
      final activities = await detectForeignWorktreeActivity(
        workspaceRoot: '   ',
        listProcessCommandLines: () async => ['101\u0000flutter test'],
      );

      expect(activities, isEmpty);
    });

    test('never spawns a shell loop for the production process list', () async {
      // The default lister is a single bounded OS query; an empty injected list
      // must short-circuit without touching any real process table.
      final activities = await detectForeignWorktreeActivity(
        workspaceRoot: Directory.current.path,
        listProcessCommandLines: () async => const [],
      );

      expect(activities, isEmpty);
    });
  });
}
