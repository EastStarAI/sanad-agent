import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';

/// A validated shell command ready for a backend.
///
/// The caller has already enforced the workspace boundary and permission
/// policy; a backend never grants, widens or re-checks approval.
class ShellCommandRequest {
  const ShellCommandRequest({
    required this.command,
    required this.workingDirectory,
    required this.timeoutMs,
    required this.stopwatch,
    this.context,
    this.secretEnvironment = const {},
  });

  final String command;
  final String workingDirectory;
  final int timeoutMs;
  final Stopwatch stopwatch;
  final ToolContext? context;

  /// User secrets explicitly requested for this call (Plan 84), keyed by
  /// environment name. A backend that runs the command injects exactly these
  /// and redacts their values from every output it reports.
  final Map<String, String> secretEnvironment;
}

/// Where a shell command runs. Direct and Protected share one typed result
/// contract so callers never branch on placement.
abstract interface class ExecutionBackend {
  ExecutionMode get mode;

  /// Whether this backend actually runs commands. A refusing backend is
  /// consulted before approval so no prompt or durable grant is created for
  /// a command that will never run.
  bool get runsCommands;

  Future<ToolExecutionResult> execute(ShellCommandRequest request);
}
