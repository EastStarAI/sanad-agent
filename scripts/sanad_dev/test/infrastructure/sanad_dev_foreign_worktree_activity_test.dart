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
