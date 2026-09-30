/// Canonical terminal status for one tool call.
enum ToolTerminalStatus {
  running,
  done,
  error,
  cancelled,
  timedOut,
  interrupted,
}

/// Shared payload for live tool events and durable checkpoint/history records.
class ToolTerminalRecord {
  final String sessionId;
  final String toolCallId;
  final String toolName;
  final String runId;
  final String? modelStepId;
  final int generation;
  final int revision;
  final ToolTerminalStatus status;
  final String reason;
  final String message;
  final bool isError;
  final DateTime startedAt;
  final DateTime terminalAt;
  final String? cleanupOutcome;

  const ToolTerminalRecord({
    required this.sessionId,
    required this.toolCallId,
    required this.toolName,
    required this.runId,
    this.modelStepId,
    required this.generation,
    required this.revision,
    required this.status,
    required this.reason,
    required this.message,
    required this.isError,
    required this.startedAt,
    required this.terminalAt,
    this.cleanupOutcome,
  });

  static const cancelledMessage = 'Command cancelled by user.';

  factory ToolTerminalRecord.cancelled({
    required String sessionId,
    required String toolCallId,
    required String toolName,
    required String runId,
    String? modelStepId,
    required int generation,
    int? revision,
    String reason = 'user_stop',
    String message = cancelledMessage,
    String? cleanupOutcome,
    DateTime? startedAt,
  }) {
    final terminalAt = DateTime.now().toUtc();
    return ToolTerminalRecord(
      sessionId: sessionId,
      toolCallId: toolCallId,
      toolName: toolName,
      runId: runId,
      modelStepId: modelStepId,
      generation: generation,
      revision: revision ?? DateTime.now().microsecondsSinceEpoch,
      status: ToolTerminalStatus.cancelled,
      reason: reason,
      message: message,
      isError: true,
      startedAt: startedAt?.toUtc() ?? terminalAt,
      terminalAt: terminalAt,
      cleanupOutcome: cleanupOutcome,
    );
  }

  factory ToolTerminalRecord.interrupted({
    required String sessionId,
    required String toolCallId,
    required String toolName,
    required String runId,
    String? modelStepId,
    required int generation,
    required String message,
    String reason = 'daemon_interrupted',
    String? cleanupOutcome,
    DateTime? startedAt,
  }) {
    final terminalAt = DateTime.now().toUtc();
    return ToolTerminalRecord(
      sessionId: sessionId,
      toolCallId: toolCallId,
      toolName: toolName,
      runId: runId,
      modelStepId: modelStepId,
      generation: generation,
      revision: terminalAt.microsecondsSinceEpoch,
      status: ToolTerminalStatus.interrupted,
      reason: reason,
      message: message,
      isError: true,
      startedAt: startedAt?.toUtc() ?? terminalAt,
      terminalAt: terminalAt,
      cleanupOutcome: cleanupOutcome,
    );
  }

  Map<String, dynamic> toCheckpointOutput({
    required Map<String, dynamic> arguments,
  }) {
    return {
      'session_id': sessionId,
      'tool_call_id': toolCallId,
      'tool_name': toolName,
      'arguments': arguments,
      'result': message,
      'is_error': isError,
      'sent_to_provider': false,
      'status': status.name,
      'reason': reason,
      'run_id': runId,
      if (modelStepId != null) 'model_step_id': modelStepId,
      'generation': generation,
      'revision': revision,
      'started_at': startedAt.toIso8601String(),
      'terminal_at': terminalAt.toIso8601String(),
      if (cleanupOutcome != null) 'cleanup_outcome': cleanupOutcome,
    };
  }

  Map<String, dynamic> toHistoryMetadata({String? modelStepId}) {
    return {
      'session_id': sessionId,
      'tool_call_id': toolCallId,
      'run_id': runId,
      'generation': generation,
      'revision': revision,
      'status': status.name,
      'reason': reason,
      'is_error': isError,
      'started_at': startedAt.toIso8601String(),
      'terminal_at': terminalAt.toIso8601String(),
      'model_step_id': ?(modelStepId ?? this.modelStepId),
      'cleanup_outcome': ?cleanupOutcome,
    };
  }

  static ToolTerminalRecord? fromCheckpointOutput(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final toolCallId = raw['tool_call_id']?.toString();
    if (toolCallId == null || toolCallId.isEmpty) return null;
    final statusName = raw['status']?.toString();
    final status = ToolTerminalStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => (raw['is_error'] == true)
          ? ToolTerminalStatus.error
          : ToolTerminalStatus.done,
    );
    return ToolTerminalRecord(
      sessionId: raw['session_id']?.toString() ?? '',
      toolCallId: toolCallId,
      toolName: raw['tool_name']?.toString() ?? 'unknown_tool',
      runId: raw['run_id']?.toString() ?? '',
      modelStepId: raw['model_step_id']?.toString(),
      generation: raw['generation'] is int
          ? raw['generation'] as int
          : int.tryParse(raw['generation']?.toString() ?? '') ?? 0,
      revision: raw['revision'] is int
          ? raw['revision'] as int
          : int.tryParse(raw['revision']?.toString() ?? '') ?? 0,
      status: status,
      reason: raw['reason']?.toString() ?? '',
      message: raw['result']?.toString() ?? '',
      isError: raw['is_error'] == true,
      startedAt:
          DateTime.tryParse(raw['started_at']?.toString() ?? '') ??
          DateTime.tryParse(raw['terminal_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      terminalAt:
          DateTime.tryParse(raw['terminal_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      cleanupOutcome: raw['cleanup_outcome']?.toString(),
    );
  }

  bool get isTerminalCancelled => status == ToolTerminalStatus.cancelled;
}
