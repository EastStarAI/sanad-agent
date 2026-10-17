import 'dart:async';

import '../../core/di.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../evolution/db/persisted_runtime_state_repository.dart';
import 'continuation_checkpoint_coordinator.dart';
import 'run_cancellation_scope.dart';
import 'tool_execution_coordinator.dart';

/// Host interface providing state and callbacks to [RunnerResumeCoordinator].
abstract class RunnerResumeHost {
  String get sessionId;
  List<Message> get history;
  set history(List<Message> newHistory);
  void saveHistory();
  ContinuationCheckpointCoordinator get checkpointCoordinator;
  ToolExecutionCoordinator get toolExecutionCoordinator;
  ToolExecutionCallbacks get toolCallbacks;
  CheckpointContext get checkpointCtx;
  RunCancellationScope? get cancellationScope;
  bool shouldParallelizeToolBatch(List<ToolCall> toolCalls);
  int get currentTurnStartIndex;
  set currentTurnStartIndex(int value);
  String? get currentModelStepId;
  set currentModelStepId(String? value);
  bool consumeManualAmbiguousToolRecovery();
}

/// Coordinates checkpoint restoration upon resume, resolving ambiguous tool
/// interruptions, and replay of incomplete tool call batches.
class RunnerResumeCoordinator {
  final RunnerResumeHost host;

  RunnerResumeCoordinator(this.host);

  Future<void> restoreCheckpointForResume({String? requestId}) async {
    final manualAmbiguousToolRecovery =
        host.consumeManualAmbiguousToolRecovery();
    final activeItem = getIt.isRegistered<PersistedRuntimeStateRepository>()
        ? getIt<PersistedRuntimeStateRepository>().findActiveWorkItem(
            host.sessionId,
          )
        : null;
    // An interrupted automatic recovery may only continue past an ambiguous
    // non-idempotent tool when its owning work item asked for unknown-tool
    // neutralization; otherwise the interruption stays manual and explicit.
    final recoverInterruptedToolsAsUnknown =
        activeItem?.continuationMetadata[ContinuationCheckpointCoordinator
            .automaticUnknownToolRecoveryKey] ==
        true;
    final allowAmbiguousToolInterruption =
        manualAmbiguousToolRecovery || recoverInterruptedToolsAsUnknown;
    final expectedRequestId = requestId ?? activeItem?.requestId;
    final expectedMessage = activeItem?.payload['message']?.toString();
    final hasOwnedUserMessage = host.history.any((message) {
      if (message.role != MessageRole.user) return false;
      final messageRequestId = message.metadata?['request_id']?.toString();
      if (expectedRequestId != null && expectedRequestId.isNotEmpty) {
        return messageRequestId == expectedRequestId;
      }
      return expectedMessage != null && message.content == expectedMessage;
    });
    host.checkpointCoordinator.repairMissingPreProviderCheckpoint(
      ctx: host.checkpointCtx,
      resumeHistoryLength: host.history.length,
      requestId: expectedRequestId,
      hasOwnedUserMessage: hasOwnedUserMessage,
    );
    final result = host.checkpointCoordinator.restoreCheckpointForResume(
      currentHistoryLength: host.history.length,
      allowAmbiguousToolInterruption: allowAmbiguousToolInterruption,
      neutralizeAllInterruptedTools: recoverInterruptedToolsAsUnknown,
    );
    if (result.resumeHistoryLength < 0) return;

    final recoveryToolCallIds = <String>{
      ...result.ambiguousToolCallIds,
      ...result.deferredToolCallIds,
      ...result.restartTerminalizedToolCallIds,
    }.toList();
    final recoveryBatch = recoveryToolCallIds.isEmpty
        ? null
        : findAssistantToolBatch(recoveryToolCallIds);
    if (recoveryToolCallIds.isNotEmpty && recoveryBatch == null) {
      throw StateError(
        'Cannot continue session ${host.sessionId}: the durable assistant tool-call '
        'batch for the recovering tools is missing from conversation history.',
      );
    }

    if (host.history.length > result.resumeHistoryLength) {
      host.history = host.history
          .take(result.resumeHistoryLength)
          .toList(growable: true);
      if (recoveryBatch != null &&
          !containsAssistantToolBatch(recoveryBatch.toolCalls!)) {
        host.history.add(recoveryBatch);
      }
      host.saveHistory();
    }

    if (result.savedTurnStartIndex != null) {
      host.currentTurnStartIndex = result.savedTurnStartIndex!;
    }

    if (result.savedModelStepId != null) {
      host.currentModelStepId = result.savedModelStepId;
    }

    if (recoveryBatch != null) {
      final toolCalls = recoveryBatch.toolCalls!;
      if (result.ambiguousToolCallIds.isNotEmpty) {
        recordAmbiguousToolInterruptions(
          result.ambiguousToolCallIds,
          toolCalls,
        );
      }
      await host.toolExecutionCoordinator.executeToolCalls(
        toolCalls,
        parallel: host.shouldParallelizeToolBatch(toolCalls),
        callbacks: host.toolCallbacks,
        ctx: host.checkpointCtx,
        cancellationScope: host.cancellationScope,
      );
    }
    if (recoverInterruptedToolsAsUnknown) {
      host.checkpointCoordinator.clearAutomaticUnknownToolRecoveryIntent();
    }
  }

  Message? findAssistantToolBatch(List<String> requiredToolCallIds) {
    final requiredIds = requiredToolCallIds.toSet();
    for (final message in host.history.reversed) {
      final calls = message.toolCalls;
      if (message.role != MessageRole.assistant || calls == null) continue;
      final batchIds = calls.map((call) => call.id).toSet();
      if (batchIds.containsAll(requiredIds)) return message;
    }
    return null;
  }

  bool containsAssistantToolBatch(List<ToolCall> expectedCalls) {
    final expectedIds = expectedCalls.map((call) => call.id).toList();
    return host.history.any((message) {
      if (message.role != MessageRole.assistant) return false;
      final actualIds = message.toolCalls?.map((call) => call.id).toList();
      if (actualIds == null || actualIds.length != expectedIds.length) {
        return false;
      }
      for (var index = 0; index < expectedIds.length; index++) {
        if (actualIds[index] != expectedIds[index]) return false;
      }
      return true;
    });
  }

  void recordAmbiguousToolInterruptions(
    List<String> toolCallIds,
    List<ToolCall> durableBatch,
  ) {
    const interruptionResult =
        'Error: Tool execution was interrupted before completion could be '
        'confirmed. The outcome is unknown, and the tool was not executed '
        'again to avoid duplicating side effects.';
    final completedResults = <String, String>{};
    final completedOutputs = <String, Map<String, dynamic>>{};
    final callsById = {for (final call in durableBatch) call.id: call};

    for (final toolCallId in toolCallIds) {
      final matchedCall = callsById[toolCallId];
      if (matchedCall == null) {
        throw StateError(
          'Cannot continue session ${host.sessionId}: interrupted tool $toolCallId '
          'is missing from its durable assistant tool-call batch.',
        );
      }
      completedResults[toolCallId] = interruptionResult;
      completedOutputs[toolCallId] = host.checkpointCoordinator.toolOutputRecord(
        matchedCall,
        interruptionResult,
        isError: true,
        sentToProvider: false,
      );
    }

    host.checkpointCoordinator.saveCheckpoint(
      ctx: host.checkpointCtx,
      additionalToolResults: completedResults,
      additionalToolOutputs: completedOutputs,
      currentlyExecutingToolCallIds: const [],
    );
  }
}
