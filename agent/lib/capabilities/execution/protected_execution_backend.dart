import 'dart:convert';

import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';

import 'execution_backend.dart';

/// Protected execution.
///
/// This release ships no isolated sandbox backend, so Protected always fails
/// closed: the command is not run and the host is never used as a fallback.
/// A future backend must enforce workspace-only mounts, deny Sanad Home,
/// credential roots and the container socket, and drop privileges before it
/// may replace this refusal.
class ProtectedExecutionBackend implements ExecutionBackend {
  const ProtectedExecutionBackend();

  static const unavailableMessage =
      'Protected execution is selected for this workspace, but no isolated '
      'execution backend is available on this host. The command was not run.';

  @override
  ExecutionMode get mode => ExecutionMode.protected;

  /// No isolated backend ships yet; Protected always refuses.
  @override
  bool get runsCommands => false;

  @override
  Future<ToolExecutionResult> execute(ShellCommandRequest request) async {
    return ToolExecutionResult.text(
      const JsonEncoder.withIndent('  ').convert({
        'isError': true,
        'output': unavailableMessage,
        'duration_ms': request.stopwatch.elapsedMilliseconds,
        'terminal_reason': 'protected_backend_unavailable',
      }),
      isError: true,
      errorCode: ToolResultErrorCode.permissionDenied,
    );
  }
}

/// Returned when the workspace policy cannot be read. Fails closed: the
/// command is not run and the host is not used as a fallback.
class PolicyUnavailableBackend implements ExecutionBackend {
  const PolicyUnavailableBackend();

  static const message =
      'The workspace security policy could not be read, so the command was '
      'not run. Try again.';

  @override
  ExecutionMode get mode => ExecutionMode.protected;

  @override
  bool get runsCommands => false;

  @override
  Future<ToolExecutionResult> execute(ShellCommandRequest request) async {
    return ToolExecutionResult.text(
      const JsonEncoder.withIndent('  ').convert({
        'isError': true,
        'output': message,
        'duration_ms': request.stopwatch.elapsedMilliseconds,
        'terminal_reason': 'policy_unavailable',
      }),
      isError: true,
      errorCode: ToolResultErrorCode.executionFailed,
    );
  }
}
