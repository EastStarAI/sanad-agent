import 'package:path/path.dart' as p;
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
    }) => buildSanadDevRefreshPlan(
      repositoryRoot: '/repo',
      workspaceRoot: '/repo',
      runtimeDirectory: '/runtime/feat-x-1234',
      delay: delay,
      scheduler: scheduler,
      now: DateTime.utc(2026, 10, 22, 12, 0, 0),
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
      'detached shell script sleeps, pulls, refreshes and deletes itself',
      () {
        final plan = planFor(
          SanadDevRefreshScheduler.detachedShell,
          delay: const Duration(minutes: 5),
        );

        expect(plan.launchArguments, ['/bin/sh']);
        expect(plan.scriptContents, contains('sleep 300'));
        expect(plan.scriptContents, contains('git -C "/repo" pull --ff-only'));
        expect(
          plan.scriptContents,
          contains('"/repo/scripts/sanad-dev" setup'),
        );
        expect(
          plan.scriptContents,
          contains('"/repo/scripts/sanad-dev" restart agent'),
        );
        expect(
          plan.scriptContents,
          contains('"/repo/scripts/sanad-dev" restart client'),
        );
        expect(plan.scriptContents, contains(r'rm -f -- "$0"'));
        expect(plan.scriptContents, isNot(contains('launchctl')));
        expect(plan.scriptContents, isNot(contains('launchd')));
      },
    );

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
      expect(plan.launchArguments.last, plan.scriptPath);
      expect(
        plan.scriptContents,
        isNot(contains('sleep')),
        reason: 'systemd owns the delay, not the script',
      );
    });

    test('windows uses a self-deleting scheduled task', () {
      final plan = planFor(
        SanadDevRefreshScheduler.schtasks,
        delay: const Duration(minutes: 30),
      );
      final wrapper = p.join('/repo', 'scripts', 'sanad-dev');

      expect(plan.scriptPath, endsWith('.cmd'));
      expect(plan.launchArguments.first, 'schtasks');
      expect(plan.launchArguments, contains('/Create'));
      expect(plan.launchArguments, contains('ONCE'));
      expect(plan.launchArguments, contains(plan.taskName));
      expect(plan.scriptContents, contains('schtasks /Delete /TN'));
      expect(plan.scriptContents, contains('del "%~f0"'));
      expect(plan.scriptContents, contains('call "$wrapper"'));
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
