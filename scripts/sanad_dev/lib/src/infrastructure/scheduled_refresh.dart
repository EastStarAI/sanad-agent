import 'dart:io';

import 'package:path/path.dart' as p;

/// Parses `--at +<duration>` where duration is `Ns`, `Nm` or `Nh`.
///
/// Examples: `+30s`, `+2m`, `+1h`. A bare number is rejected so a mistyped
/// schedule can never fire immediately.
Duration? parseSanadDevRefreshDelay(String value) {
  final match = RegExp(r'^\+\s*(\d+)\s*([smh])$').firstMatch(value.trim());
  if (match == null) return null;
  final amount = int.tryParse(match.group(1)!);
  if (amount == null) return null;
  return switch (match.group(2)) {
    's' => Duration(seconds: amount),
    'm' => Duration(minutes: amount),
    'h' => Duration(hours: amount),
    _ => null,
  };
}

String formatSanadDevRefreshDelay(Duration delay) {
  if (delay.inSeconds % 3600 == 0 && delay.inSeconds >= 3600) {
    return '+${delay.inHours}h';
  }
  if (delay.inSeconds % 60 == 0 && delay.inSeconds >= 60) {
    return '+${delay.inMinutes}m';
  }
  return '+${delay.inSeconds}s';
}

/// One-shot self-deleting scheduler used for the out-of-tree refresh.
///
/// macOS uses a detached `sh` child that survives the parent. A transient
/// launchd job is deliberately not used: a launchd wrapper around a Sanad
/// binary inside the owned tree is the incident that reopened a Keychain
/// prompt and forced a cancelled live round. Linux uses a transient
/// `systemd-run --user` unit, and Windows a `schtasks /SC ONCE` task that
/// deletes itself.
enum SanadDevRefreshScheduler { detachedShell, systemdRun, schtasks }

SanadDevRefreshScheduler sanadDevRefreshSchedulerFor({
  bool? isMacOS,
  bool? isWindows,
  bool? isLinux,
}) {
  if (isWindows ?? Platform.isWindows) {
    return SanadDevRefreshScheduler.schtasks;
  }
  if (isLinux ?? Platform.isLinux) {
    return SanadDevRefreshScheduler.systemdRun;
  }
  if (isMacOS ?? Platform.isMacOS) {
    return SanadDevRefreshScheduler.detachedShell;
  }
  return SanadDevRefreshScheduler.detachedShell;
}

class SanadDevRefreshPlan {
  const SanadDevRefreshPlan({
    required this.repositoryRoot,
    required this.workspaceRoot,
    required this.delay,
    required this.fireAt,
    required this.scriptPath,
    required this.logPath,
    required this.scheduler,
    required this.taskName,
    required this.scriptContents,
  });

  final String repositoryRoot;
  final String workspaceRoot;
  final Duration delay;
  final DateTime fireAt;
  final String scriptPath;
  final String logPath;
  final SanadDevRefreshScheduler scheduler;
  final String taskName;
  final String scriptContents;

  /// Argument vector that schedules (or directly runs) the refresh script.
  List<String> get launchArguments => switch (scheduler) {
    SanadDevRefreshScheduler.detachedShell => const ['/bin/sh'],
    SanadDevRefreshScheduler.systemdRun => [
      'systemd-run',
      '--user',
      '--collect',
      '--unit=$taskName',
      '--on-active=${delay.inSeconds}',
      '/bin/sh',
      scriptPath,
    ],
    SanadDevRefreshScheduler.schtasks => [
      'schtasks',
      '/Create',
      '/F',
      '/TN',
      taskName,
      '/SC',
      'ONCE',
      '/ST',
      schtasksTime(fireAt),
      '/TR',
      'cmd /c "$scriptPath"',
    ],
  };
}

/// Absolute `HH:MM` schedule stamp for `schtasks`.
String schtasksTime(DateTime fireAt) {
  final local = fireAt.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Builds the pure refresh plan: fast-forward pull, rebuild the prepared
/// runtime CLI, then restart the agent and the client from the new source.
///
/// The plan performs no I/O; the caller creates the directory, writes the
/// script, and schedules it.
SanadDevRefreshPlan buildSanadDevRefreshPlan({
  required String repositoryRoot,
  required String workspaceRoot,
  required String runtimeDirectory,
  required Duration delay,
  required SanadDevRefreshScheduler scheduler,
  DateTime? now,
}) {
  final fireAt = (now ?? DateTime.now()).toUtc().add(delay);
  final taskName =
      'sanad-refresh-${fireAt.millisecondsSinceEpoch.toRadixString(16)}';
  final directory = p.join(runtimeDirectory, 'refresh');
  final logPath = p.join(directory, '$taskName.log');
  final scriptPath = p.join(
    directory,
    scheduler == SanadDevRefreshScheduler.schtasks
        ? '$taskName.cmd'
        : '$taskName.sh',
  );
  return SanadDevRefreshPlan(
    repositoryRoot: repositoryRoot,
    workspaceRoot: workspaceRoot,
    delay: delay,
    fireAt: fireAt,
    scriptPath: scriptPath,
    logPath: logPath,
    scheduler: scheduler,
    taskName: taskName,
    scriptContents: buildSanadDevRefreshScript(
      repositoryRoot: repositoryRoot,
      logPath: logPath,
      scheduler: scheduler,
      taskName: taskName,
      fireAt: fireAt,
      delay: delay,
    ),
  );
}

String buildSanadDevRefreshScript({
  required String repositoryRoot,
  required String logPath,
  required SanadDevRefreshScheduler scheduler,
  required String taskName,
  required DateTime fireAt,
  required Duration delay,
}) {
  final wrapper = p.join(repositoryRoot, 'scripts', 'sanad-dev');
  if (scheduler == SanadDevRefreshScheduler.schtasks) {
    return [
      '@echo off',
      'rem sanad-dev refresh $taskName (scheduled ${fireAt.toIso8601String()})',
      'set LOG=$logPath',
      'call :run >> "%LOG%" 2>&1',
      'schtasks /Delete /TN "$taskName" /F >> "%LOG%" 2>&1',
      'del "%~f0"',
      'exit /b 0',
      ':run',
      'echo [refresh] start %DATE% %TIME%',
      'git -C "$repositoryRoot" pull --ff-only || exit /b 1',
      'call "$wrapper" setup || exit /b 1',
      'call "$wrapper" restart agent || exit /b 1',
      'call "$wrapper" restart client || exit /b 1',
      'echo [refresh] done %DATE% %TIME%',
      'exit /b 0',
      '',
    ].join('\r\n');
  }
  return [
    '#!/bin/sh',
    '# sanad-dev refresh $taskName (scheduled ${fireAt.toIso8601String()})',
    'set -u',
    'exec >>"$logPath" 2>&1',
    if (scheduler == SanadDevRefreshScheduler.detachedShell)
      'sleep ${delay.inSeconds}',
    'echo "[refresh] start \$(date -u +%Y-%m-%dT%H:%M:%SZ)"',
    'git -C "$repositoryRoot" pull --ff-only || '
        '{ echo "[refresh] pull failed"; exit 1; }',
    '"$wrapper" setup || { echo "[refresh] setup failed"; exit 1; }',
    '"$wrapper" restart agent || echo "[refresh] agent restart failed"',
    '"$wrapper" restart client || echo "[refresh] client restart failed"',
    'echo "[refresh] done \$(date -u +%Y-%m-%dT%H:%M:%SZ) '
        'sha=\$(git -C "$repositoryRoot" rev-parse HEAD)"',
    'rm -f -- "\$0"',
    '',
  ].join('\n');
}

/// Lines printed after scheduling so an operator can verify the refresh.
List<String> sanadDevRefreshVerificationLines(SanadDevRefreshPlan plan) => [
  'Scheduled ${plan.taskName} (${plan.scheduler.name}) to fire at '
      '${plan.fireAt.toIso8601String()} '
      '(${formatSanadDevRefreshDelay(plan.delay)}).',
  'Refresh script: ${plan.scriptPath}',
  'Refresh log: ${plan.logPath}',
  'Verify with:',
  '  git -C ${plan.repositoryRoot} rev-parse HEAD',
  '  sanad-dev status',
  '  sanad-dev logs agent -n 20',
  '  sanad-dev logs client -n 20',
];
