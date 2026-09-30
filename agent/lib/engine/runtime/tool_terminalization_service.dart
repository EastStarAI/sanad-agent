import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../core/secrets_redactor.dart';
import '../../evolution/db/persisted_runtime_state_repository.dart';
import '../agent_runner.dart';
import 'tool_terminal_record.dart';

/// Durable terminalization for tool calls interrupted by Stop.
class ToolTerminalizationService {
  final PersistedRuntimeStateRepository? repository;
  final SecretsRedactor secretsRedactor;

  const ToolTerminalizationService({
    required this.repository,
    this.secretsRedactor = const SecretsRedactor(),
  });

  List<ToolTerminalRecord> terminalizeExecutingTools({
    required String sessionId,
    required AgentRunner agentRunner,
    required String workItemId,
    required String runId,
    required int generation,
    String? modelStepId,
    String? cleanupOutcome,
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
    final toolStartedAt = Map<String, dynamic>.from(
      metadata['tool_started_at'] as Map? ?? const {},
    );
    final historyTerminalIds = agentRunner.history
        .where((message) => message.role == MessageRole.tool)
        .map((message) => message.toolCallId)
        .whereType<String>()
        .toSet();
    final executingIds =
        List<String>.from(
              metadata['currently_executing_tools'] as List? ?? const [],
            )
            .where(
              (id) =>
                  !completedResults.containsKey(id) &&
                  !historyTerminalIds.contains(id),
            )
            .toList(growable: false);

    if (executingIds.isEmpty) {
      return const [];
    }

    final toolCallsById = _toolCallsById(agentRunner.history);
    final terminalRecords = <ToolTerminalRecord>[];
    final additionalOutputs = <String, Map<String, dynamic>>{};

    for (final toolCallId in executingIds) {
      final existing = ToolTerminalRecord.fromCheckpointOutput(
        completedOutputs[toolCallId] is Map
            ? Map<String, dynamic>.from(completedOutputs[toolCallId] as Map)
            : null,
      );
      if (existing?.isTerminalCancelled == true) {
        terminalRecords.add(existing!);
        continue;
      }

      final toolCall = toolCallsById[toolCallId];
      final record = ToolTerminalRecord.cancelled(
        sessionId: sessionId,
        toolCallId: toolCallId,
        toolName: toolCall?.name ?? 'unknown_tool',
        runId: runId,
        modelStepId: modelStepId,
        generation: generation,
        cleanupOutcome: cleanupOutcome,
        startedAt: DateTime.tryParse(
          toolStartedAt[toolCallId]?.toString() ?? '',
        ),
      );
      terminalRecords.add(record);

      final payload = record.toCheckpointOutput(
        arguments: secretsRedactor.redactMap(toolCall?.arguments ?? const {}),
      );
      additionalOutputs[toolCallId] = payload;
    }

    final messagesByToolCallId = {
      for (final record in terminalRecords)
        record.toolCallId: Message(
          role: MessageRole.tool,
          content: record.message,
          toolCallId: record.toolCallId,
          metadata: record.toHistoryMetadata(modelStepId: modelStepId),
        ),
    };
    final commit = repo.executionState.commitToolTerminals(
      sessionId: sessionId,
      workItemId: workItemId,
      runId: runId,
      generation: generation,
      checkpointOutputs: additionalOutputs,
      historyMessages: messagesByToolCallId,
    );
    final committedIds = commit.committedToolCallIds.toSet();
    final committedRecords = terminalRecords
        .where((record) => committedIds.contains(record.toolCallId))
        .toList(growable: false);
    for (final record in committedRecords) {
      agentRunner.history.add(messagesByToolCallId[record.toolCallId]!);
    }
    return committedRecords;
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
}
