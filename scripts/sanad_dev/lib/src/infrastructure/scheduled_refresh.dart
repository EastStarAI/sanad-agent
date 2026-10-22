import 'dart:io';

import 'package:path/path.dart' as p;

/// Largest delay a single `refresh --at` may schedule.
///
/// A scheduled refresh mutates a live runtime and pulls source; an unbounded
/// delay would leave a task armed long after the branch it was scheduled on was
/// abandoned.
const sanadDevRefreshMaxDelay = Duration(hours: 12);

/// Smallest delay the Windows task scheduler can represent.
///
/// `schtasks /SC ONCE` takes `HH:MM`, so a sub-minute delay cannot be expressed
/// without landing in the past.
const sanadDevRefreshMinimumScheduledDelay = Duration(minutes: 1);

/// Why a parsed delay cannot be scheduled.
enum SanadDevRefreshDelayProblem { zero, tooLong, belowSchedulerResolution }

/// Parses `--at +<duration>` where duration is `Ns`, `Nm` or `Nh`.
///
/// Examples: `+30s`, `+2m`, `+1h`. A bare number is rejected so a mistyped
/// schedule can never fire immediately; a zero delay is parsed and then refused
/// by [sanadDevRefreshDelayProblem] with an explicit message.
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

/// Validates a parsed delay against the documented bounds.
SanadDevRefreshDelayProblem? sanadDevRefreshDelayProblem(
  Duration delay, {
  required SanadDevRefreshScheduler scheduler,
}) {
  if (delay <= Duration.zero) return SanadDevRefreshDelayProblem.zero;
  if (delay > sanadDevRefreshMaxDelay) {
    return SanadDevRefreshDelayProblem.tooLong;
  }
  if (scheduler == SanadDevRefreshScheduler.schtasks &&
      delay < sanadDevRefreshMinimumScheduledDelay) {
    return SanadDevRefreshDelayProblem.belowSchedulerResolution;
  }
  return null;
}

/// Human message for a refused delay.
String sanadDevRefreshDelayProblemMessage(
  SanadDevRefreshDelayProblem problem,
) => switch (problem) {
  SanadDevRefreshDelayProblem.zero =>
    '--at must be at least +1s: a zero delay would fire immediately.',
  SanadDevRefreshDelayProblem.tooLong =>
    '--at is limited to +${formatSanadDevRefreshDelay(sanadDevRefreshMaxDelay)}.',
  SanadDevRefreshDelayProblem.belowSchedulerResolution =>
    'Windows scheduling cannot represent less than '
        '+${formatSanadDevRefreshDelay(sanadDevRefreshMinimumScheduledDelay)}.',
};

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
    required this.homePath,
    required this.branch,
    required this.headCommit,
    required this.delay,
    required this.fireAt,
    required this.scriptPath,
    required this.logPath,
    required this.scheduler,
    required this.taskName,
    required this.scriptContents,
    required this.scriptArguments,
  });

  final String repositoryRoot;
  final String workspaceRoot;

  /// Home passed to the scheduled restarts, so the refresh keeps the Home the
  /// operator scheduled it against.
  final String homePath;

  /// Branch the worktree was on when the refresh was scheduled.
  final String branch;

  /// `HEAD` when the refresh was scheduled, recorded for verification only.
  final String headCommit;

  final Duration delay;
  final DateTime fireAt;
  final String scriptPath;
  final String logPath;
  final SanadDevRefreshScheduler scheduler;
  final String taskName;
  final String scriptContents;

  /// Positional arguments handed to the script: repository, log, Home, branch,
  /// scheduled `HEAD`, task name.
  ///
  /// Values travel as an argument vector, never spliced into the script text, so
  /// a path with a space, quote, `$`, or backtick cannot change the script.
  final List<String> scriptArguments;

  /// Argument vector that schedules (or directly runs) the refresh script.
  List<String> get launchArguments => switch (scheduler) {
    SanadDevRefreshScheduler.detachedShell => [
      '/bin/sh',
      scriptPath,
      ...scriptArguments,
    ],
    SanadDevRefreshScheduler.systemdRun => [
      'systemd-run',
      '--user',
      '--collect',
      '--unit=$taskName',
      '--on-active=${delay.inSeconds}',
      '/bin/sh',
      scriptPath,
      ...scriptArguments,
    ],
    SanadDevRefreshScheduler.schtasks => [
      'schtasks',
      '/Create',
      '/F',
      '/TN',
      taskName,
      '/SC',
      'ONCE',
      '/SD',
      schtasksDate(fireAt),
      '/ST',
      schtasksTime(fireAt),
      '/TR',
      schtasksCommandLine(scriptPath: scriptPath, arguments: scriptArguments),
    ],
  };
}

/// Absolute `HH:MM` schedule stamp for `schtasks`, rounded up so the scheduled
/// instant is always in the future.
///
/// `schtasks /SC ONCE` has minute resolution; a raw stamp computed from a delay
/// with seconds can land in the past and the task creation fails.
String schtasksTime(DateTime fireAt) {
  final local = fireAt.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// `MM/DD/YYYY` schedule date for `schtasks /SD`.
String schtasksDate(DateTime fireAt) {
  final local = fireAt.toLocal();
  return '${local.month.toString().padLeft(2, '0')}/'
      '${local.day.toString().padLeft(2, '0')}/${local.year}';
}

/// The minute-rounded instant handed to `schtasks`.
///
/// It is the first whole minute that is not before [fireAt], so the task is never
/// created in the past.
DateTime schtasksFireTime(DateTime fireAt) {
  final local = fireAt.toLocal();
  final minute = DateTime(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
  );
  return minute.isBefore(local) ? minute.add(const Duration(minutes: 1)) : minute;
}

/// Builds the `/TR` command line for `schtasks`, quoting every value.
String schtasksCommandLine({
  required String scriptPath,
  required List<String> arguments,
}) {
  final parts = [
    _windowsQuoted(scriptPath),
    ...arguments.map(_windowsQuoted),
  ];
  // `cmd /c` needs the whole command wrapped when the executable is quoted.
  return 'cmd /c "${parts.join(' ')}"';
}

String _windowsQuoted(String value) {
  if (value.contains('"') || value.contains('\n') || value.contains('\r')) {
    throw const FormatException(
      'A scheduled refresh path or argument contains a quote or line break.',
    );
  }
  return '"$value"';
}

/// Builds the pure refresh plan: fast-forward pull, rebuild the prepared
/// runtime CLI, then restart the agent and the client from the new source.
///
/// The plan performs no I/O; the caller creates the directory, writes the
/// script, and schedules it.
SanadDevRefreshPlan buildSanadDevRefreshPlan({
  required String repositoryRoot,
  required String workspaceRoot,
  required String homePath,
  required String branch,
  required String headCommit,
  required String runtimeDirectory,
  required Duration delay,
  required SanadDevRefreshScheduler scheduler,
  DateTime? now,
}) {
  final fireAt = (now ?? DateTime.now()).toUtc().add(delay);
  final scheduled = scheduler == SanadDevRefreshScheduler.schtasks
      ? schtasksFireTime(fireAt)
      : fireAt;
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
  final scriptArguments = <String>[
    repositoryRoot,
    logPath,
    homePath,
    branch,
    headCommit,
    taskName,
  ];
  return SanadDevRefreshPlan(
    repositoryRoot: repositoryRoot,
    workspaceRoot: workspaceRoot,
    homePath: homePath,
    branch: branch,
    headCommit: headCommit,
    delay: delay,
    fireAt: scheduled.toUtc(),
    scriptPath: scriptPath,
    logPath: logPath,
    scheduler: scheduler,
    taskName: taskName,
    scriptArguments: List.unmodifiable(scriptArguments),
    scriptContents: buildSanadDevRefreshScript(
      scheduler: scheduler,
      fireAt: fireAt,
      delay: delay,
    ),
  );
}

/// The scheduled script body.
///
/// Every value it needs arrives as a positional parameter (`$1`…`$6`), so the
/// script text contains no interpolated path, Home, branch, or commit.
String buildSanadDevRefreshScript({
  required SanadDevRefreshScheduler scheduler,
  required DateTime fireAt,
  required Duration delay,
}) {
  final stamp = fireAt.toIso8601String();
  if (scheduler == SanadDevRefreshScheduler.schtasks) {
    return [
      '@echo off',
      'setlocal EnableExtensions DisableDelayedExpansion',
      'rem sanad-dev refresh scheduled $stamp',
      'if "%~6"=="" exit 2',
      'set "REPO=%~1"',
      'set "LOG_FILE=%~2"',
      'set "SANAD_HOME=%~3"',
      'set "EXPECTED_BRANCH=%~4"',
      'set "EXPECTED_HEAD=%~5"',
      'set "TASK_NAME=%~6"',
      'call :run >>"%LOG_FILE%" 2>&1',
      'schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1',
      'del "%~f0"',
      'exit /b 0',
      ':run',
      'echo [refresh] start %DATE% %TIME% head=%EXPECTED_HEAD%',
      'if not exist "%REPO%\\scripts\\sanad-dev.ps1" '
          '(echo [refresh] skip: the worktree is gone & exit /b 0)',
      'set "CURRENT_BRANCH="',
      'for /f "usebackq delims=" %%b in (`git -C "%REPO%" rev-parse '
          '--abbrev-ref HEAD 2^>nul`) do set "CURRENT_BRANCH=%%b"',
      'if /i not "%CURRENT_BRANCH%"=="%EXPECTED_BRANCH%" '
          '(echo [refresh] skip: worktree is on %CURRENT_BRANCH%, scheduled for '
          '%EXPECTED_BRANCH% & exit /b 0)',
      'set "GIT_TERMINAL_PROMPT=0"',
      'set "GIT_SSH_COMMAND=ssh -o BatchMode=yes"',
      'git -C "%REPO%" pull --ff-only || (echo [refresh] pull failed & exit /b 1)',
      'powershell -NoProfile -ExecutionPolicy Bypass -File '
          '"%REPO%\\scripts\\sanad-dev.ps1" setup || '
          '(echo [refresh] setup failed & exit /b 1)',
      'powershell -NoProfile -ExecutionPolicy Bypass -File '
          '"%REPO%\\scripts\\sanad-dev.ps1" restart agent --home "%SANAD_HOME%" '
          '|| echo [refresh] agent restart failed',
      'powershell -NoProfile -ExecutionPolicy Bypass -File '
          '"%REPO%\\scripts\\sanad-dev.ps1" restart client --home '
          '"%SANAD_HOME%" || echo [refresh] client restart failed',
      'echo [refresh] done %DATE% %TIME%',
      'exit /b 0',
      '',
    ].join('\r\n');
  }
  return [
    '#!/bin/sh',
    '# sanad-dev refresh scheduled $stamp',
    'set -u',
    'if [ "\$#" -lt 6 ]; then exit 2; fi',
    'repo=\$1',
    'log_file=\$2',
    'sanad_home=\$3',
    'expected_branch=\$4',
    'expected_head=\$5',
    'task_name=\$6',
    'exec >>"\$log_file" 2>&1',
    "# The script deletes itself on every exit path, including failure.",
    "trap 'rm -f -- \"\$0\"' EXIT HUP INT TERM",
    if (scheduler == SanadDevRefreshScheduler.detachedShell)
      'sleep ${delay.inSeconds}',
    'echo "[refresh] start \$(date -u +%Y-%m-%dT%H:%M:%SZ) \$task_name '
        'head=\$expected_head"',
    'if [ ! -d "\$repo" ]; then '
        'echo "[refresh] skip: the worktree is gone"; exit 0; fi',
    'if [ ! -x "\$repo/scripts/sanad-dev" ]; then '
        'echo "[refresh] skip: the worktree is gone"; exit 0; fi',
    'current_branch=\$(git -C "\$repo" rev-parse --abbrev-ref HEAD 2>/dev/null '
        '|| true)',
    'if [ "\$current_branch" != "\$expected_branch" ]; then '
        'echo "[refresh] skip: worktree is on \'\$current_branch\', scheduled '
        'for \'\$expected_branch\'"; exit 0; fi',
    'GIT_TERMINAL_PROMPT=0',
    'GIT_SSH_COMMAND="ssh -o BatchMode=yes"',
    'export GIT_TERMINAL_PROMPT GIT_SSH_COMMAND',
    'git -C "\$repo" pull --ff-only || { echo "[refresh] pull failed"; exit 1; }',
    '"\$repo/scripts/sanad-dev" setup || '
        '{ echo "[refresh] setup failed"; exit 1; }',
    '"\$repo/scripts/sanad-dev" restart agent --home "\$sanad_home" || '
        'echo "[refresh] agent restart failed"',
    '"\$repo/scripts/sanad-dev" restart client --home "\$sanad_home" || '
        'echo "[refresh] client restart failed"',
    'echo "[refresh] done \$(date -u +%Y-%m-%dT%H:%M:%SZ) '
        'sha=\$(git -C "\$repo" rev-parse HEAD)"',
    '',
  ].join('\n');
}

/// Lines printed after scheduling so an operator can verify the refresh.
List<String> sanadDevRefreshVerificationLines(SanadDevRefreshPlan plan) => [
  'Scheduled ${plan.taskName} (${plan.scheduler.name}) to fire at '
      '${plan.fireAt.toIso8601String()} '
      '(${formatSanadDevRefreshDelay(plan.delay)}).',
  'Scheduled for branch ${plan.branch} at ${plan.headCommit.isEmpty ? '-' : plan.headCommit}; '
      'the refresh skips itself if the worktree moved or is gone.',
  'Home: ${plan.homePath}',
  'Refresh script: ${plan.scriptPath}',
  'Refresh log: ${plan.logPath}',
  'Verify with:',
  '  git -C ${plan.repositoryRoot} rev-parse HEAD',
  '  sanad-dev status',
  '  sanad-dev logs agent -n 20',
  '  sanad-dev logs client -n 20',
];
