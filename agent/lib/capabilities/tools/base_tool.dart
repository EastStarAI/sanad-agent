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

  /// Authoritative provider-neutral result for one execution.
  ///
  /// Every production tool must implement this boundary explicitly. There is
  /// no fallback that infers a typed result from legacy text.
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) => throw UnsupportedError(
    'Tool implementations must provide typed executeResult output.',
  );

  /// Temporary text projection for direct legacy callers.
  ///
  /// The engine and coordinator must consume [executeResult], never this
  /// compatibility surface.
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
