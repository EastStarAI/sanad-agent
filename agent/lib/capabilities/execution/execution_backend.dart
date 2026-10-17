import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';

/// Contract for execution backends (Direct Developer vs. Protected Sandbox).
///
/// Under Plan 83 (Task 83g):
/// 1. Direct Developer executes on the host with developer parity and secret isolation.
/// 2. Protected Execution executes in an isolated sandbox backend (e.g. container).
/// 3. If Protected Execution is requested but the sandbox backend is unavailable,
///    execution fails closed. Silent fallback to host execution is strictly prohibited.
abstract class ExecutionBackend {
  /// The execution mode supported by this backend.
  ExecutionMode get mode;

  /// Whether this execution backend is available and ready on the current host.
  bool get isAvailable;

  /// Executes [command] in [workingDir] within this backend's execution posture.
  Future<String> executeCommand({
    required String command,
    required String workingDir,
    required int timeoutMs,
    required Stopwatch stopwatch,
    ToolContext? context,
  });
}
