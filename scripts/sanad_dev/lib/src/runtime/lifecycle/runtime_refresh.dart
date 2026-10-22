part of '../../../sanad_dev_cli.dart';

typedef SanadDevRefreshLauncher =
    Future<void> Function(SanadDevRefreshPlan plan, {required String homePath});

/// `sanad-dev refresh --at +<duration>`.
///
/// Schedules an out-of-tree fast-forward pull followed by an Agent and Client
/// restart. The schedule is owned by a one-shot self-deleting OS mechanism so
/// it survives the tree it refreshes:
///
/// - macOS: a detached `sh` child (never launchd);
/// - Linux: `systemd-run --user --collect --on-active`;
/// - Windows: `schtasks /SC ONCE` that deletes itself.
Future<void> handleRuntimeRefresh({
  required String at,
  String? sanadHomePath,
  SanadDevRefreshScheduler? scheduler,
  DateTime? now,
  Map<String, String>? environment,
  SanadDevResetRuntimeProvider? runtimeProvider,
  SanadDevRefreshLauncher? launcher,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
}) async {
  final log = printMessage ?? print;
  final logError = printError ?? stderr.writeln;
  final delay = parseSanadDevRefreshDelay(at);
  if (delay == null) {
    logError(
      'Invalid --at value "$at": use +<seconds>s, +<minutes>m or +<hours>h '
      '(for example --at +2m).',
    );
    exitCode = 64;
    return;
  }
  final runtime =
      await (runtimeProvider ??
          ({String? sanadHomeOverride}) => _currentRuntime(
            sanadHomePath: sanadHomeOverride,
          ))(sanadHomeOverride: sanadHomePath);
  final plan = buildSanadDevRefreshPlan(
    repositoryRoot: runtime.repositoryRoot,
    workspaceRoot: runtime.workspaceRoot,
    runtimeDirectory: runtime.runtimeDirectory,
    delay: delay,
    scheduler: scheduler ?? sanadDevRefreshSchedulerFor(),
    now: now,
  );
  await (launcher ?? _defaultRefreshLauncher)(
    plan,
    homePath: runtime.sanadHome,
  );
  for (final line in sanadDevRefreshVerificationLines(plan)) {
    log(line);
  }
}

/// Writes the owner-only refresh script and hands it to the platform scheduler.
Future<void> _defaultRefreshLauncher(
  SanadDevRefreshPlan plan, {
  required String homePath,
}) async {
  final directory = Directory(p.dirname(plan.scriptPath));
  await directory.create(recursive: true);
  final script = File(plan.scriptPath);
  await script.writeAsString(plan.scriptContents, flush: true);
  if (!Platform.isWindows) await _restrictRefreshScript(script);
  switch (plan.scheduler) {
    case SanadDevRefreshScheduler.detachedShell:
      await Process.start('/bin/sh', [
        plan.scriptPath,
      ], mode: ProcessStartMode.detached);
    case SanadDevRefreshScheduler.systemdRun:
    case SanadDevRefreshScheduler.schtasks:
      final result = await Process.run(
        plan.launchArguments.first,
        plan.launchArguments.skip(1).toList(),
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) {
        stderr.writeln(
          'Failed to schedule the refresh with '
          '${plan.launchArguments.first}: ${result.stderr.toString().trim()}',
        );
        exitCode = 1;
      }
  }
}

Future<void> _restrictRefreshScript(File script) async {
  final result = await Process.run('chmod', ['700', script.path]);
  if (result.exitCode != 0) {
    stderr.writeln('Could not restrict the refresh script permissions.');
    exitCode = 1;
  }
}
