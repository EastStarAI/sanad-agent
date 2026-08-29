/// Typed terminal reason for a tool execution attempt.
enum ToolExecutionTerminalReason {
  completed,
  cancelled,
  timedOut,
  failed,
}

/// Result of process-tree cleanup after Stop, timeout, or escalation.
enum ToolProcessCleanupOutcome {
  exited,
  escalated,
  ownershipLost,
  failed,
}

/// Report for one owned process-tree termination attempt.
class ToolProcessCleanupReport {
  final ToolProcessCleanupOutcome outcome;
  final int pid;
  final String? diagnostics;

  const ToolProcessCleanupReport({
    required this.outcome,
    required this.pid,
    this.diagnostics,
  });
}
