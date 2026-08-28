import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../evolution/db/persisted_runtime_state_repository.dart';
import '../../evolution/session_manager.dart';
import '../agent_runner.dart';
import 'continuation_checkpoint_coordinator.dart';
import 'tool_terminal_record.dart';

/// Durable terminalization for tool calls interrupted by Stop.
class ToolTerminalizationService {
  final PersistedRuntimeStateRepository? repository;
  final SessionManager sessionManager;

  const ToolTerminalizationService({
    required this.repository,
    required this.sessionManager,
  });

  List<ToolTerminalRecord> terminalizeExecutingTools({
    required String sessionId,
    required AgentRunner agentRunner,
    required String runId,
    required int generation,
    String? modelStepId,
  }) {
    final repo = repository;
    if (repo == null) return const [];

    final activeItem = repo.findActiveWorkItem(sessionId);
    if (activeItem == null) return const [];

    final metadata = Map<String, dynamic>.from(activeItem.continuationMetadata);
    final completedResults = Map<String, dynamic>.from(
      metadata['completed_tool_results'] as Map? ?? const {},
    );
    final completedOutputs = Map<String, dynamic>.from(
      metadata['completed_tool_outputs'] as Map? ?? const {},
    );
    final executingIds = List<String>.from(
      metadata['currently_executing_tools'] as List? ?? const [],
    ).where((id) => !completedResults.containsKey(id)).toList(growable: false);

    if (executingIds.isEmpty) {
      return const [];
    }

    final toolCallsById = _toolCallsById(agentRunner.history);
    final terminalRecords = <ToolTerminalRecord>[];
    final additionalResults = <String, String>{};
    final additionalOutputs = <String, Map<String, dynamic>>{};

    for (final toolCallId in executingIds) {
      final existing = ToolTerminalRecord.fromCheckpointOutput(
        completedOutputs[toolCallId] is Map
            ? Map<String, dynamic>.from(
                completedOutputs[toolCallId] as Map,
              )
            : null,
      );
      if (existing?.isTerminalCancelled == true) {
        terminalRecords.add(existing!);
        continue;
      }

      final toolCall = toolCallsById[toolCallId];
      final record = ToolTerminalRecord.cancelled(
        toolCallId: toolCallId,
        toolName: toolCall?.name ?? 'unknown_tool',
        runId: runId,
        generation: generation,
      );
      terminalRecords.add(record);

      final payload = record.toCheckpointOutput(
        arguments: toolCall?.arguments ?? const {},
      );
      additionalResults[toolCallId] = record.message;
      additionalOutputs[toolCallId] = payload;

      _persistHistoryToolResult(
        sessionId: sessionId,
        agentRunner: agentRunner,
        toolCall: toolCall,
        record: record,
        modelStepId: modelStepId,
      );
    }

    final checkpointCoordinator = ContinuationCheckpointCoordinator(
      sessionId: sessionId,
    );
    checkpointCoordinator.saveCheckpoint(
      ctx: (
        currentTurnStartIndex: agentRunner.history.length,
        currentModelStepId: modelStepId,
      ),
      additionalToolResults: additionalResults,
      additionalToolOutputs: additionalOutputs,
      currentlyExecutingToolCallIds: const [],
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindAfterToolResult,
      resumeHistoryLength: agentRunner.history.length,
    );

    return terminalRecords;
  }

  Map<String, ToolCall> _toolCallsById(List<Message> history) {
    final result = <String, ToolCall>{};
    for (final message in history.reversed) {
      final calls = message.toolCalls;
      if (message.role != MessageRole.assistant || calls == null) continue;
      for (final call in calls) {
        result.putIfAbsent(call.id, () => call);
      }
    }
    return result;
  }

  void _persistHistoryToolResult({
    required String sessionId,
    required AgentRunner agentRunner,
    required ToolCall? toolCall,
    required ToolTerminalRecord record,
    required String? modelStepId,
  }) {
    final alreadyPresent = agentRunner.history.any(
      (message) =>
          message.role == MessageRole.tool &&
          message.toolCallId == record.toolCallId,
    );
    if (alreadyPresent) {
      return;
    }

    final toolMessage = Message(
      role: MessageRole.tool,
      content: record.message,
      toolCallId: record.toolCallId,
      metadata: record.toHistoryMetadata(modelStepId: modelStepId),
    );
    agentRunner.history.add(toolMessage);
    sessionManager.saveSessionHistory(sessionId, agentRunner.history);
    sessionManager.deleteSuspendedCheckpointByToolCallId(record.toolCallId);
  }
}
