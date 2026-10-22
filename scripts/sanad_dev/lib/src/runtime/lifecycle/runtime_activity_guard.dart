part of '../../../sanad_dev_cli.dart';

typedef ForeignActivityDetector =
    Future<List<ForeignWorktreeActivity>> Function(String workspaceRoot);

/// B4 guard: refuse a restart while another build or test runs in this worktree.
///
/// Returns true when the caller must stop. A foreign build competes for the same
/// build outputs, so reporting it immediately is strictly better than waiting
/// for an unbounded rebuild and then producing a misleading result.
Future<bool> refuseRestartDuringForeignActivity({
  required SanadDevRuntime runtime,
  required bool force,
  ForeignActivityDetector? detectActivity,
  void Function(String message)? printError,
}) async {
  if (force) return false;
  final activities = await (detectActivity ?? detectForeignWorktreeActivity)(
    runtime.workspaceRoot,
  );
  if (activities.isEmpty) return false;
  (printError ?? stderr.writeln)(
    foreignWorktreeActivityMessage(
      worktreeId: runtime.worktreeId,
      activities: activities,
    ),
  );
  exitCode = 1;
  return true;
}
