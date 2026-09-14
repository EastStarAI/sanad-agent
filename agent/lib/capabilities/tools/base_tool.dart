import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';

import '../models/tool_schema.dart';
import 'tool_execution_outcome.dart';

abstract class BaseTool {
  ToolSchema get schema;

  /// Whether this tool may be safely re-executed after a daemon crash/restart
  /// when the runtime cannot prove whether the previous execution completed.
  ///
  /// Defaults to false. Tools must opt in explicitly from their own contract;
  /// the runtime must not maintain ad-hoc allow-lists for replay safety.
  bool get restartReplaySafe => false;

  /// Whether the tool participates in run-scoped cooperative cancellation.
  ///
  /// Defaults to false. Tools that spawn side effects must opt in explicitly.
  bool get isCooperativelyCancellable => false;

  /// Transitional typed boundary while text tools migrate in Tasks 77a2–77a4.
  ///
  /// Unported tools retain byte-for-byte text behavior through this wrapper.
  /// Task 77a5 removes the bridge when every implementation is typed.
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => ToolExecutionResult.text(await execute(args, context: context));

  Future<String> execute(Map<String, dynamic> args, {ToolContext? context});
}

class ToolContext {
  final String sessionId;
  final Map<String, dynamic> metadata;
  final String? toolCallId;
  final String? runId;
  final int? generation;
  final RunCancellationScope? cancellationScope;
  final void Function(Map<String, dynamic> progress)? onExecutionProgress;

  ToolContext({
    required this.sessionId,
    this.metadata = const {},
    this.toolCallId,
    this.runId,
    this.generation,
    this.cancellationScope,
    this.onExecutionProgress,
  });

  bool get isCancellationRequested =>
      cancellationScope != null && !cancellationScope!.isPublicationOpen;

  ToolExecutionTerminalReason? terminalReasonForCancellation() {
    final scope = cancellationScope;
    if (scope == null || scope.isPublicationOpen) {
      return null;
    }
    return switch (scope.reason) {
      RunCancellationReason.timeout => ToolExecutionTerminalReason.timedOut,
      _ => ToolExecutionTerminalReason.cancelled,
    };
  }
}
