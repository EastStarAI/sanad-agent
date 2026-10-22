part of '../../../sanad_dev_cli.dart';

/// Result of writing and scheduling the out-of-tree refresh script.
///
/// The launcher reports a failure instead of only printing it, because a
/// schedule that was never created must not be followed by a success summary.
class SanadDevRefreshLaunchOutcome {
  const SanadDevRefreshLaunchOutcome.scheduled() : error = null;

  const SanadDevRefreshLaunchOutcome.failed(this.error);

  /// Null when the schedule was created.
  final String? error;

  bool get isScheduled => error == null;
}

typedef SanadDevRefreshLauncher =
    Future<SanadDevRefreshLaunchOutcome> Function(
      SanadDevRefreshPlan plan, {
      required String homePath,
    });

/// `sanad-dev refresh --at +<duration>`.
///
/// Schedules an out-of-tree fast-forward pull followed by an Agent and Client
/// restart. The schedule is owned by a one-shot self-deleting OS mechanism so
/// it survives the tree it refreshes:
///
/// - macOS: a detached `sh` child (never launchd);
/// - Linux: `systemd-run --user --collect --on-active`;
/// - Windows: `schtasks /SC ONCE` that deletes itself.
///
/// The plan records the worktree branch and `HEAD` at scheduling time and passes
/// the target Home, so the fired script refuses to pull or restart when the
/// worktree is gone or has moved to another branch.
Future<void> handleRuntimeRefresh({
  required String at,
  String? sanadHomePath,
  SanadDevRefreshScheduler? scheduler,
  DateTime? now,
  Map<String, String>? environment,
  SanadDevResetRuntimeProvider? runtimeProvider,
  SanadDevRefreshLauncher? launcher,
  Future<String> Function(String repositoryRoot)? sourceCommit,
  Future<ProcessResult> Function(List<String> arguments)? runScheduler,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
  void Function(int code)? setExitCode,
}) async {
  final log = printMessage ?? print;
  final logError = printError ?? stderr.writeln;
  // The exit status is injected so tests can assert it without touching
  // `dart:io`'s process-global [exitCode], which parallel suites share.
  final fail = setExitCode ?? _assignRefreshProcessExitCode;
  final delay = parseSanadDevRefreshDelay(at);
  if (delay == null) {
    logError(
      'Invalid --at value "$at": use +<seconds>s, +<minutes>m or +<hours>h '
      '(for example --at +2m).',
    );
    fail(64);
    return;
  }
  final selectedScheduler = scheduler ?? sanadDevRefreshSchedulerFor();
  final problem = sanadDevRefreshDelayProblem(
    delay,
    scheduler: selectedScheduler,
  );
  if (problem != null) {
    logError(sanadDevRefreshDelayProblemMessage(problem));
    fail(64);
    return;
  }
  final runtime =
      await (runtimeProvider ??
          ({String? sanadHomeOverride}) => _currentRuntime(
            sanadHomePath: sanadHomeOverride,
          ))(sanadHomeOverride: sanadHomePath);
  if (runtime.branch.trim().isEmpty) {
    logError(
      'Refusing to schedule a refresh from a detached HEAD: check out a named '
      'branch so the scheduled run can verify the worktree.',
    );
    fail(64);
    return;
  }
  final homePath = runtime.sanadHome;
  final SanadDevRefreshPlan plan;
  try {
    plan = buildSanadDevRefreshPlan(
      repositoryRoot: runtime.repositoryRoot,
      workspaceRoot: runtime.workspaceRoot,
      homePath: homePath,
      branch: runtime.branch,
      headCommit: await (sourceCommit ?? readRuntimeSourceCommit)(
        runtime.repositoryRoot,
      ),
      runtimeDirectory: runtime.runtimeDirectory,
      delay: delay,
      scheduler: selectedScheduler,
      now: now,
    );
  } on Object catch (error) {
    logError('Could not prepare the refresh schedule: $error');
    fail(1);
    return;
  }
  final outcome =
      await (launcher ??
          (plan, {required homePath}) => _defaultRefreshLauncher(
            plan,
            homePath: homePath,
            runScheduler: runScheduler,
          ))(plan, homePath: homePath);
  if (!outcome.isScheduled) {
    logError(
      'Could not schedule the refresh: ${outcome.error}\n'
      'Nothing is scheduled; the refresh script ${plan.scriptPath} was removed.',
    );
    fail(1);
    return;
  }
  for (final line in sanadDevRefreshVerificationLines(plan)) {
    log(line);
  }
}

void _assignRefreshProcessExitCode(int code) => exitCode = code;

/// Writes the owner-only refresh script and hands it to the platform scheduler.
Future<SanadDevRefreshLaunchOutcome> _defaultRefreshLauncher(
  SanadDevRefreshPlan plan, {
  required String homePath,
  Future<ProcessResult> Function(List<String> arguments)? runScheduler,
}) async {
  final directory = Directory(p.dirname(plan.scriptPath));
  final script = File(plan.scriptPath);
  // Every failure path removes the script: a leftover script with no schedule
  // would look like a pending refresh to the next operator.
  Future<SanadDevRefreshLaunchOutcome> failed(String error) async {
    try {
      if (script.existsSync()) script.deleteSync();
    } on Object {
      // Best effort: the failure message already tells the operator what to do.
    }
    return SanadDevRefreshLaunchOutcome.failed(error);
  }

  try {
    await directory.create(recursive: true);
    await script.writeAsString(plan.scriptContents, flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['700', script.path]);
      if (chmod.exitCode != 0) {
        return await failed('the refresh script could not be made owner-only');
      }
    }
    // The planned Home is carried as a script argument so the scheduled restarts
    // keep targeting the Home this refresh was scheduled against.
    assert(plan.homePath == homePath, 'refresh plan Home must match the launcher');
    final launch = plan.launchArguments;
    switch (plan.scheduler) {
      case SanadDevRefreshScheduler.detachedShell:
        await Process.start(
          launch.first,
          launch.skip(1).toList(),
          mode: ProcessStartMode.detached,
        );
      case SanadDevRefreshScheduler.systemdRun:
      case SanadDevRefreshScheduler.schtasks:
        final result = runScheduler == null
            ? await Process.run(
                launch.first,
                launch.skip(1).toList(),
                runInShell: Platform.isWindows,
              )
            : await runScheduler(launch);
        if (result.exitCode != 0) {
          final detail = result.stderr.toString().trim();
          return await failed(
            '${launch.first} exited ${result.exitCode}'
            '${detail.isEmpty ? '' : ': $detail'}',
          );
        }
    }
    return const SanadDevRefreshLaunchOutcome.scheduled();
  } on Object catch (error) {
    return await failed('$error');
  }
}
