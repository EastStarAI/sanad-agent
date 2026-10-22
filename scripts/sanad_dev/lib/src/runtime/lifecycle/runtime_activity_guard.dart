part of '../../../sanad_dev_cli.dart';

/// Detection seam for the B4 build guard.
///
/// It is declared with the same shape as [detectForeignWorktreeActivity] so the
/// production detector can be used directly as the default. An untyped
/// `Function(String)` seam accepted a positional call that the named-parameter
/// production function could not answer, which turned every unforced restart
/// into a runtime `NoSuchMethodError`.
typedef ForeignActivityDetector =
    Future<List<ForeignWorktreeActivity>> Function({required String workspaceRoot});

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
  void Function(int code)? setExitCode,
}) async {
  if (force) return false;
  final detect = detectActivity ?? detectForeignWorktreeActivity;
  final activities = await detect(workspaceRoot: runtime.workspaceRoot);
  if (activities.isEmpty) return false;
  (printError ?? stderr.writeln)(
    foreignWorktreeActivityMessage(
      worktreeId: runtime.worktreeId,
      activities: activities,
    ),
  );
  // The exit status is injected so tests can assert the guard's contract,
  // because `dart:io`'s [exitCode] is process-global and parallel suites would
  // otherwise read each other's value.
  (setExitCode ?? _assignGuardProcessExitCode)(1);
  return true;
}

void _assignGuardProcessExitCode(int code) => exitCode = code;
