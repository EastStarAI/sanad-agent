import 'package:sanad_dev/src/infrastructure/scheduled_refresh.dart';
import 'package:test/test.dart';

void main() {
  group('refresh delay parsing', () {
    test('accepts seconds, minutes and hours', () {
      expect(parseSanadDevRefreshDelay('+30s'), const Duration(seconds: 30));
      expect(parseSanadDevRefreshDelay('+2m'), const Duration(minutes: 2));
      expect(parseSanadDevRefreshDelay(' +1h '), const Duration(hours: 1));
    });

    test('rejects an unqualified or malformed delay', () {
      for (final value in const ['', '30', '2m', '-2m', '+2d', '+m', 'now']) {
        expect(
          parseSanadDevRefreshDelay(value),
          isNull,
          reason: '$value must not schedule a refresh',
        );
      }
    });

    test('rejects a zero delay and an unbounded delay', () {
      for (final value in const ['+0s', '+0m', '+0h']) {
        expect(
          sanadDevRefreshDelayProblem(
            parseSanadDevRefreshDelay(value)!,
            scheduler: SanadDevRefreshScheduler.detachedShell,
          ),
          SanadDevRefreshDelayProblem.zero,
          reason: '$value must never fire immediately',
        );
      }
      expect(
        sanadDevRefreshDelayProblem(
          const Duration(hours: 13),
          scheduler: SanadDevRefreshScheduler.detachedShell,
        ),
        SanadDevRefreshDelayProblem.tooLong,
      );
      expect(
        sanadDevRefreshDelayProblem(
          sanadDevRefreshMaxDelay,
          scheduler: SanadDevRefreshScheduler.detachedShell,
        ),
        isNull,
        reason: 'the documented maximum itself stays schedulable',
      );
      expect(
        sanadDevRefreshDelayProblem(
          const Duration(seconds: 30),
          scheduler: SanadDevRefreshScheduler.schtasks,
        ),
        SanadDevRefreshDelayProblem.belowSchedulerResolution,
        reason: 'the Windows scheduler cannot represent a sub-minute delay',
      );
    });

    test('formats a delay back to its canonical flag', () {
      expect(formatSanadDevRefreshDelay(const Duration(seconds: 90)), '+90s');
      expect(formatSanadDevRefreshDelay(const Duration(minutes: 2)), '+2m');
      expect(formatSanadDevRefreshDelay(const Duration(hours: 3)), '+3h');
    });
  });

  group('refresh scheduling', () {
    SanadDevRefreshPlan planFor(
      SanadDevRefreshScheduler scheduler, {
      Duration delay = const Duration(minutes: 2),
      String repositoryRoot = '/repo',
      String homePath = '/home/test-home',
      DateTime? now,
    }) => buildSanadDevRefreshPlan(
      repositoryRoot: repositoryRoot,
      workspaceRoot: repositoryRoot,
      homePath: homePath,
      branch: 'feat/runtime-reset',
      headCommit: 'abc1234',
      runtimeDirectory: '/runtime/feat-x-1234',
      delay: delay,
      scheduler: scheduler,
      now: now ?? DateTime.utc(2026, 10, 22, 12, 0, 0),
    );

    test('selects a non-launchd scheduler per platform', () {
      expect(
        sanadDevRefreshSchedulerFor(isWindows: true),
        SanadDevRefreshScheduler.schtasks,
      );
      expect(
        sanadDevRefreshSchedulerFor(isLinux: true),
        SanadDevRefreshScheduler.systemdRun,
      );
      expect(
        sanadDevRefreshSchedulerFor(isMacOS: true),
        SanadDevRefreshScheduler.detachedShell,
      );
    });

    test('keeps the refresh script out of the source tree', () {
      final plan = planFor(SanadDevRefreshScheduler.detachedShell);

      expect(plan.scriptPath, startsWith('/runtime/feat-x-1234/refresh/'));
      expect(plan.logPath, startsWith('/runtime/feat-x-1234/refresh/'));
      expect(plan.fireAt, DateTime.utc(2026, 10, 22, 12, 2, 0));
      expect(plan.taskName, startsWith('sanad-refresh-'));
      expect(plan.scriptPath, endsWith('.sh'));
    });

    test(
      'detached shell script pulls, refreshes the scheduled Home and deletes '
      'itself',
      () {
        final plan = planFor(
          SanadDevRefreshScheduler.detachedShell,
          delay: const Duration(minutes: 5),
        );

        expect(plan.launchArguments.take(2), ['/bin/sh', plan.scriptPath]);
        expect(plan.launchArguments.skip(2), plan.scriptArguments);
        expect(plan.scriptContents, contains('sleep 300'));
        expect(
          plan.scriptContents,
          contains('git -C "\$repo" pull --ff-only'),
        );
        expect(plan.scriptContents, contains('"\$repo/scripts/sanad-dev" setup'));
        expect(
          plan.scriptContents,
          contains('restart agent --home "\$sanad_home"'),
        );
        expect(
          plan.scriptContents,
          contains('restart client --home "\$sanad_home"'),
        );
        expect(
          plan.scriptContents,
          contains(r'''trap 'rm -f -- "$0"' EXIT HUP INT TERM'''),
        );
        expect(plan.scriptContents, isNot(contains('launchctl')));
        expect(plan.scriptContents, isNot(contains('launchd')));
      },
    );

    test('the scheduled Home, branch and commit travel as arguments', () {
      final plan = planFor(
        SanadDevRefreshScheduler.detachedShell,
        repositoryRoot: '/repo with space',
        homePath: '/home/test home',
      );

      expect(plan.scriptArguments, [
        '/repo with space',
        plan.logPath,
        '/home/test home',
        'feat/runtime-reset',
        'abc1234',
        plan.taskName,
      ]);
      // Nothing the operator supplied is spliced into the script text.
      expect(plan.scriptContents, isNot(contains('/repo with space')));
      expect(plan.scriptContents, isNot(contains('/home/test home')));
      expect(plan.scriptContents, isNot(contains(plan.logPath)));
      expect(plan.scriptContents, isNot(contains(plan.taskName)));
      expect(plan.scriptContents, isNot(contains('feat/runtime-reset')));
    });

    test('the script refuses a moved worktree and never prompts for git', () {
      final plan = planFor(SanadDevRefreshScheduler.detachedShell);

      expect(
        plan.scriptContents,
        contains('if [ "\$current_branch" != "\$expected_branch" ]'),
      );
      expect(plan.scriptContents, contains('the worktree is gone'));
      expect(plan.scriptContents, contains('GIT_TERMINAL_PROMPT=0'));
      expect(plan.scriptContents, contains('ssh -o BatchMode=yes'));
      expect(
        plan.scriptContents,
        contains('export GIT_TERMINAL_PROMPT GIT_SSH_COMMAND'),
      );
    });

    test('linux uses a transient self-collecting systemd unit', () {
      final plan = planFor(
        SanadDevRefreshScheduler.systemdRun,
        delay: const Duration(seconds: 90),
      );

      expect(plan.launchArguments.take(4), [
        'systemd-run',
        '--user',
        '--collect',
        '--unit=${plan.taskName}',
      ]);
      expect(plan.launchArguments, contains('--on-active=90'));
      expect(plan.launchArguments, contains(plan.scriptPath));
      expect(plan.launchArguments, containsAll(plan.scriptArguments));
      expect(
        plan.scriptContents,
        isNot(contains('sleep')),
        reason: 'systemd owns the delay, not the script',
      );
    });

    test('windows schedules a dated, minute-safe, self-deleting task', () {
      final plan = planFor(
        SanadDevRefreshScheduler.schtasks,
        delay: const Duration(minutes: 30),
        now: DateTime.utc(2026, 10, 22, 12, 0, 30),
      );

      expect(plan.scriptPath, endsWith('.cmd'));
      expect(plan.launchArguments.first, 'schtasks');
      expect(plan.launchArguments, contains('/Create'));
      expect(plan.launchArguments, contains('ONCE'));
      expect(plan.launchArguments, contains(plan.taskName));
      expect(plan.launchArguments, contains('/SD'));
      expect(plan.launchArguments, contains('/ST'));
      final command = plan.launchArguments.last;
      expect(command, startsWith('cmd /c ""'));
      expect(command, contains(plan.scriptPath));
      expect(command, contains(plan.homePath));
      expect(plan.scriptContents, contains('schtasks /Delete /TN'));
      expect(plan.scriptContents, contains('del "%~f0"'));
      expect(plan.scriptContents, contains('--home "%SANAD_HOME%"'));
    });

    test('a Windows schedule is never created in the past', () {
      final fireAt = DateTime(2026, 10, 22, 12, 2, 45);

      final rounded = schtasksFireTime(fireAt);

      expect(rounded.isAfter(fireAt), isTrue);
      expect(rounded, DateTime(2026, 10, 22, 12, 3));
      expect(schtasksTime(fireAt), '12:02');
      expect(schtasksDate(fireAt), '10/22/2026');
      final exact = schtasksFireTime(DateTime(2026, 10, 22, 12, 3));
      expect(exact, DateTime(2026, 10, 22, 12, 3));
    });

    test('windows quoting rejects a value it cannot represent', () {
      expect(
        () => schtasksCommandLine(
          scriptPath: '/tmp/a "b".cmd',
          arguments: const [],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('the plan records the branch and commit it was scheduled on', () {
      final plan = planFor(SanadDevRefreshScheduler.detachedShell);

      expect(plan.branch, 'feat/runtime-reset');
      expect(plan.headCommit, 'abc1234');
      final lines = sanadDevRefreshVerificationLines(plan);
      expect(
        lines.any(
          (line) =>
              line.contains('feat/runtime-reset') && line.contains('abc1234'),
        ),
        isTrue,
      );
      expect(lines, contains('Home: ${plan.homePath}'));
    });

    test('prints how to verify the refresh', () {
      final plan = planFor(SanadDevRefreshScheduler.detachedShell);
      final lines = sanadDevRefreshVerificationLines(plan);

      expect(lines.first, contains('2026-10-22T12:02:00.000Z'));
      expect(lines, contains('Refresh log: ${plan.logPath}'));
      expect(lines.any((line) => line.contains('sanad-dev status')), isTrue);
      expect(
        lines.any((line) => line.contains('git -C /repo rev-parse HEAD')),
        isTrue,
      );
    });
  });
}
