import 'dart:convert';
import 'package:logging/logging.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../capabilities/registry/tools_registry.dart';
import '../../capabilities/tools/base_tool.dart';
import '../../core/di.dart';
import '../../evolution/db/persisted_runtime_state_repository.dart';
import '../../evolution/session_manager.dart';
import '../../plugins/plugin_manager.dart';
import 'continuation_checkpoint_coordinator.dart';
import 'deferred_tool_result.dart';
import 'run_cancellation_scope.dart';
import 'tool_output_guard.dart';
import 'tool_terminal_record.dart';

/// Executes tool-call batches (sequential or parallel), persists per-tool
/// completion checkpoints, and replays completed/interrupted tools safely on
/// resume — all without owning the conversation history.
///
/// **Ownership boundaries (Gate C refactor):**
/// - The coordinator owns tool *execution* and *checkpoint writing* during a
///   batch. It is the only writer to `currently_executing_tools` /
///   `completed_tool_results` / `completed_tool_outputs` inside a batch.
/// - It does **not** own `history`. All history appends go through the
///   [ToolExecutionCallbacks] so the runner remains the single source of
///   truth. The coordinator never holds a `List<Message>` reference.
/// - It delegates checkpoint persistence to
///   [ContinuationCheckpointCoordinator] (no duplicate DB writes).
class ToolExecutionCoordinator {
  static final Logger _logger = Logger('ToolExecutionCoordinator');

  final String sessionId;
  final ToolsRegistry registry;
  final SessionManager sessionManager;
  final PluginManager pluginManager;
  final ContinuationCheckpointCoordinator checkpointCoordinator;
  final DeferredToolResultResolver deferredToolResultResolver;

  ToolExecutionCoordinator({
    required this.sessionId,
    required this.registry,
    required this.sessionManager,
    required this.pluginManager,
    required this.checkpointCoordinator,
    DeferredToolResultResolver? deferredToolResultResolver,
  }) : deferredToolResultResolver =
           deferredToolResultResolver ?? const DeferredToolResultResolver();

  /// Executes a batch of tool calls sequentially or in parallel.
  ///
  /// [callbacks] bridge history mutations and history-save back to the runner
  /// so this coordinator never owns `history`. [ctx] supplies the live
  /// turn/run ids for checkpoint writes.
  Future<void> executeToolCalls(
    List<ToolCall> toolCalls, {
    required bool parallel,
    required ToolExecutionCallbacks callbacks,
    required CheckpointContext ctx,
    RunCancellationScope? cancellationScope,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
  }) async {
    if (!_canPublishToolEvents(cancellationScope)) return;
    final repo = getIt.isRegistered<PersistedRuntimeStateRepository>()
        ? getIt<PersistedRuntimeStateRepository>()
        : null;
    final activeItem = repo?.findActiveWorkItem(sessionId);
    final checkpointMeta = activeItem?.continuationMetadata ?? const {};
    final completedResults = Map<String, String>.from(
      checkpointMeta['completed_tool_results'] as Map? ?? const {},
    );
    final currentlyExecuting = List<String>.from(
      checkpointMeta['currently_executing_tools'] as List? ?? const [],
    );
    final deferredResults = Map<String, dynamic>.from(
      checkpointMeta['deferred_tool_results'] as Map? ?? const {},
    );

    final finalResults = <String, String>{};
    final toolCallsToRun = <ToolCall>[];
    final interruptedTools = <String, String>{};
    final toolReplaySafety = <String, bool>{
      for (final toolCall in toolCalls)
        toolCall.id: registry.isRestartReplaySafe(toolCall.name),
    };

    checkpointCoordinator.saveCheckpoint(
      ctx: ctx,
      toolReplaySafety: toolReplaySafety,
    );

    for (final toolCall in toolCalls) {
      final deferred = DeferredToolResultDescriptor.tryParseMetadata(
        deferredResults[toolCall.id],
      );
      if (deferred != null &&
          deferred.requesterSessionId == sessionId &&
          deferred.requesterToolCallId == toolCall.id) {
        final resolution = await deferredToolResultResolver.resolve(deferred);
        completedResults[toolCall.id] = resolution.output;
        checkpointCoordinator.saveCheckpoint(
          ctx: ctx,
          additionalToolResults: {toolCall.id: resolution.output},
          additionalToolOutputs: {
            toolCall.id: checkpointCoordinator.toolOutputRecord(
              toolCall,
              resolution.output,
              isError: resolution.isError,
              sentToProvider: false,
            ),
          },
          removeDeferredToolCallIds: [toolCall.id],
          currentlyExecutingToolCallIds: currentlyExecuting
              .where((id) => id != toolCall.id)
              .toList(),
        );
      }
      if (completedResults.containsKey(toolCall.id)) {
        finalResults[toolCall.id] = completedResults[toolCall.id]!;
        _logger.info(
          '🔄 [Agent] Resuming tool call ${toolCall.name} from checkpoint.',
        );
      } else if (currentlyExecuting.contains(toolCall.id) &&
          toolReplaySafety[toolCall.id] != true) {
        final errMsg =
            'Error: Tool execution was interrupted by a daemon crash/restart. Non-idempotent tool cannot be safely re-run.';
        finalResults[toolCall.id] = errMsg;
        interruptedTools[toolCall.id] = errMsg;
        _logger.warning(
          '⚠️ [Agent] Tool call ${toolCall.name} was interrupted in a non-idempotent state. Skipping re-execution for safety.',
        );
      } else {
        toolCallsToRun.add(toolCall);
      }
    }

    if (interruptedTools.isNotEmpty) {
      checkpointCoordinator.saveCheckpoint(
        ctx: ctx,
        additionalToolResults: interruptedTools,
        additionalToolOutputs: {
          for (final entry in interruptedTools.entries)
            entry.key: checkpointCoordinator.toolOutputRecord(
              toolCalls.firstWhere((tc) => tc.id == entry.key),
              entry.value,
              isError: true,
              sentToProvider: false,
            ),
        },
      );
    }

    if (toolCallsToRun.isNotEmpty) {
      final executedResults = parallel
          ? await _executeParallel(
              toolCallsToRun,
              callbacks: callbacks,
              ctx: ctx,
              cancellationScope: cancellationScope,
              onToolEvent: onToolEvent,
            )
          : await _executeSequential(
              toolCallsToRun,
              callbacks: callbacks,
              ctx: ctx,
              cancellationScope: cancellationScope,
              onToolEvent: onToolEvent,
            );
      finalResults.addAll(executedResults);
    }

    // Stop owns terminalization once publication closes. Late tool futures are
    // allowed to settle internally, but must not mutate checkpoints or history.
    if (!_canPublishToolEvents(cancellationScope)) return;

    // After execution, collect results from checkpoint to build finalResults
    // in original order for the history-merge step.
    final updatedMeta =
        (repo?.findActiveWorkItem(sessionId)?.continuationMetadata) ?? const {};
    final allCompleted = Map<String, dynamic>.from(
      updatedMeta['completed_tool_results'] as Map? ?? const {},
    );
    final allOutputs = Map<String, dynamic>.from(
      updatedMeta['completed_tool_outputs'] as Map? ?? const {},
    );
    for (final toolCall in toolCalls) {
      finalResults[toolCall.id] = ToolOutputGuard.guardResult(
        allCompleted[toolCall.id]?.toString() ??
            finalResults[toolCall.id] ??
            'Error: No result for tool call',
      );
    }
    final batchGuardedResults = ToolOutputGuard.guardBatch(finalResults);
    finalResults
      ..clear()
      ..addAll(batchGuardedResults);

    // Add all guarded results to history in the original tool-call order.
    // Presence checks preserve idempotency for resumed single-tool paths.
    for (final toolCall in toolCalls) {
      if (!_canPublishToolEvents(cancellationScope)) return;
      final result = finalResults[toolCall.id]!;
      final alreadyAdded = callbacks.isToolMessagePresent(toolCall.id);
      if (!alreadyAdded) {
        final outputRecord = allOutputs[toolCall.id];
        final isError =
            _lockedCancelledResult(toolCall.id) != null ||
            (outputRecord is Map && outputRecord['is_error'] == true) ||
            result.startsWith('Error');
        await callbacks.addToolMessage(toolCall, result, isError: isError);
      }
    }
    if (!_canPublishToolEvents(cancellationScope)) return;
    callbacks.saveHistory();
    checkpointCoordinator.saveCheckpoint(
      ctx: ctx,
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindAfterToolResult,
      resumeHistoryLength: callbacks.currentHistoryLength(),
      removeRestartTerminalizedToolCallIds: toolCalls.map((call) => call.id),
    );
    callbacks.applyPendingSteerToToolResults(toolCalls.length);
  }

  ToolContext _toolContextFor(
    ToolCall toolCall, {
    RunCancellationScope? cancellationScope,
  }) {
    return ToolContext(
      sessionId: sessionId,
      metadata: sessionManager.getSessionMetadata(sessionId) ?? const {},
      toolCallId: toolCall.id,
      runId: cancellationScope?.runId,
      generation: cancellationScope?.generation,
      cancellationScope: cancellationScope,
      onExecutionProgress: (progress) => checkpointCoordinator
          .saveExecutingToolProgress(toolCall.id, progress),
    );
  }

  bool _canPublishToolEvents(RunCancellationScope? cancellationScope) =>
      cancellationScope?.isPublicationOpen ?? true;

  String? _lockedCancelledResult(String toolCallId) {
    final repo = getIt.isRegistered<PersistedRuntimeStateRepository>()
        ? getIt<PersistedRuntimeStateRepository>()
        : null;
    final meta = repo?.findActiveWorkItem(sessionId)?.continuationMetadata;
    if (meta == null) return null;
    final outputs = meta['completed_tool_outputs'];
    if (outputs is! Map) return null;
    final raw = outputs[toolCallId];
    if (raw is! Map) return null;
    final record = ToolTerminalRecord.fromCheckpointOutput(
      Map<String, dynamic>.from(raw),
    );
    return record?.isTerminalCancelled == true ? record!.message : null;
  }

  String _applyLateResultIsolation(String toolCallId, String result) {
    return _lockedCancelledResult(toolCallId) ?? result;
  }

  Future<void> _maybeEmitToolEvent(
    RunCancellationScope? cancellationScope, {
    required Future<void> Function()? emit,
  }) async {
    if (emit == null || !_canPublishToolEvents(cancellationScope)) {
      return;
    }
    await emit();
  }

  Future<Map<String, String>> _executeSequential(
    List<ToolCall> toolCallsToRun, {
    required ToolExecutionCallbacks callbacks,
    required CheckpointContext ctx,
    RunCancellationScope? cancellationScope,
    required Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
  }) async {
    final results = <String, String>{};
    for (final toolCall in toolCallsToRun) {
      if (!_canPublishToolEvents(cancellationScope)) return results;
      final argumentsString = jsonEncode(toolCall.arguments);
      _logger.info(
        '🛠️ [Agent] Requesting tool call: ${toolCall.name} (arguments: $argumentsString)',
      );
      if (onToolEvent != null) {
        await _maybeEmitToolEvent(
          cancellationScope,
          emit: () => onToolEvent(
            toolName: toolCall.name,
            input: argumentsString,
            isError: false,
            isStart: true,
            toolRunId: toolCall.id,
          ),
        );
      }
      if (!_canPublishToolEvents(cancellationScope)) return results;

      // Mark as currently executing
      checkpointCoordinator.saveCheckpoint(
        ctx: ctx,
        currentlyExecutingToolCallIds: [toolCall.id],
      );

      var result = await _executeSingleToolCall(
        toolCall,
        callbacks: callbacks,
        cancellationScope: cancellationScope,
        onToolEvent: onToolEvent,
        emitStartEvent: false,
        appendToHistory: false,
      );
      if (!_canPublishToolEvents(cancellationScope)) return results;
      final deferred = DeferredToolResultDescriptor.tryParseToolResult(
        result,
        sessionId: sessionId,
        toolCallId: toolCall.id,
      );
      var isError = result.startsWith('Error');
      if (deferred != null) {
        checkpointCoordinator.saveCheckpoint(
          ctx: ctx,
          additionalDeferredToolResults: {toolCall.id: deferred.toJson()},
          currentlyExecutingToolCallIds: [toolCall.id],
        );
        final resolution = await deferredToolResultResolver.resolve(deferred);
        if (!_canPublishToolEvents(cancellationScope)) return results;
        result = resolution.output;
        isError = resolution.isError;
        if (onToolEvent != null) {
          await _maybeEmitToolEvent(
            cancellationScope,
            emit: () => onToolEvent(
              toolName: toolCall.name,
              output: result,
              isError: isError,
              isStart: false,
              toolRunId: toolCall.id,
            ),
          );
        }
      }
      results[toolCall.id] = result;

      // Save result and clear executing
      checkpointCoordinator.saveCheckpoint(
        ctx: ctx,
        additionalToolResults: {toolCall.id: result},
        additionalToolOutputs: {
          toolCall.id: checkpointCoordinator.toolOutputRecord(
            toolCall,
            result,
            isError: isError,
            sentToProvider: false,
          ),
        },
        removeDeferredToolCallIds: [toolCall.id],
        currentlyExecutingToolCallIds: const [],
      );
    }
    return results;
  }

  Future<Map<String, String>> _executeParallel(
    List<ToolCall> toolCallsToRun, {
    required ToolExecutionCallbacks callbacks,
    required CheckpointContext ctx,
    RunCancellationScope? cancellationScope,
    required Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
  }) async {
    _logger.info(
      '⚡ Executing ${toolCallsToRun.length} tool calls concurrently: ${toolCallsToRun.map((tc) => tc.name).join(', ')}',
    );

    if (onToolEvent != null) {
      await Future.wait(
        toolCallsToRun.map((toolCall) {
          return _maybeEmitToolEvent(
            cancellationScope,
            emit: () => onToolEvent(
              toolName: toolCall.name,
              input: jsonEncode(toolCall.arguments),
              isError: false,
              isStart: true,
              toolRunId: toolCall.id,
            ),
          );
        }),
      );
    }
    if (!_canPublishToolEvents(cancellationScope)) return const {};

    // Mark all as currently executing
    final idsToRun = toolCallsToRun.map((tc) => tc.id).toList();
    checkpointCoordinator.saveCheckpoint(
      ctx: ctx,
      currentlyExecutingToolCallIds: idsToRun,
    );

    final remainingExecuting = {...idsToRun};
    final executionResults = <String, String>{};
    await Future.wait(
      toolCallsToRun.map((toolCall) async {
        _logger.info(
          '🛠️ [Agent] Concurrent request: ${toolCall.name} (arguments: ${toolCall.arguments})',
        );
        final tool = registry.getTool(toolCall.name);
        if (tool == null) {
          final result = 'Error: Tool ${toolCall.name} not found';
          executionResults[toolCall.id] = result;
          remainingExecuting.remove(toolCall.id);
          checkpointCoordinator.saveCheckpoint(
            ctx: ctx,
            additionalToolResults: {toolCall.id: result},
            additionalToolOutputs: {
              toolCall.id: checkpointCoordinator.toolOutputRecord(
                toolCall,
                result,
                isError: true,
                sentToProvider: false,
              ),
            },
            currentlyExecutingToolCallIds: remainingExecuting.toList(),
          );
          return;
        }
        try {
          final rawResult = await tool.execute(
            toolCall.arguments,
            context: _toolContextFor(
              toolCall,
              cancellationScope: cancellationScope,
            ),
          );
          final result = ToolOutputGuard.guardResult(
            _applyLateResultIsolation(toolCall.id, rawResult),
          );
          if (!_canPublishToolEvents(cancellationScope)) return;
          executionResults[toolCall.id] = result;
          remainingExecuting.remove(toolCall.id);
          checkpointCoordinator.saveCheckpoint(
            ctx: ctx,
            additionalToolResults: {toolCall.id: result},
            additionalToolOutputs: {
              toolCall.id: checkpointCoordinator.toolOutputRecord(
                toolCall,
                result,
                isError: false,
                sentToProvider: false,
              ),
            },
            currentlyExecutingToolCallIds: remainingExecuting.toList(),
          );
        } catch (e) {
          if (!_canPublishToolEvents(cancellationScope)) return;
          final result = 'Error executing tool: $e';
          executionResults[toolCall.id] = result;
          remainingExecuting.remove(toolCall.id);
          checkpointCoordinator.saveCheckpoint(
            ctx: ctx,
            additionalToolResults: {toolCall.id: result},
            additionalToolOutputs: {
              toolCall.id: checkpointCoordinator.toolOutputRecord(
                toolCall,
                result,
                isError: true,
                sentToProvider: false,
              ),
            },
            currentlyExecutingToolCallIds: remainingExecuting.toList(),
          );
        }
      }),
    );
    if (!_canPublishToolEvents(cancellationScope)) return executionResults;

    // Emit completion events in order.
    final repoMeta = getIt.isRegistered<PersistedRuntimeStateRepository>()
        ? getIt<PersistedRuntimeStateRepository>()
        : null;
    final updatedMeta =
        repoMeta?.findActiveWorkItem(sessionId)?.continuationMetadata ??
        const {};
    final allResults = Map<String, dynamic>.from(
      updatedMeta['completed_tool_results'] as Map? ?? const {},
    );
    for (final toolCall in toolCallsToRun) {
      final result =
          allResults[toolCall.id]?.toString() ??
          executionResults[toolCall.id] ??
          '';
      final isError = result.startsWith('Error');
      if (onToolEvent != null) {
        await _maybeEmitToolEvent(
          cancellationScope,
          emit: () => onToolEvent(
            toolName: toolCall.name,
            output: result,
            isError: isError,
            isStart: false,
            toolRunId: toolCall.id,
          ),
        );
      }
      if (isError) {
        _logger.warning('❌ [Agent] Tool call ${toolCall.name} failed: $result');
      } else {
        _logger.info(
          '✅ [Agent] Tool call ${toolCall.name} executed successfully.',
        );
      }
    }
    return executionResults;
  }

  /// Executes a single tool call: emits start event, runs the tool, emits
  /// completion event, appends the tool result message to history via
  /// callbacks, and notifies plugins.
  ///
  /// Used for both sequential batch execution and single-tool resume paths.
  Future<String> executeSingleToolCall(
    ToolCall toolCall, {
    required ToolExecutionCallbacks callbacks,
    RunCancellationScope? cancellationScope,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    bool emitStartEvent = true,
    String? forcedOutput,
    bool forcedIsError = false,
  }) {
    return _executeSingleToolCall(
      toolCall,
      callbacks: callbacks,
      cancellationScope: cancellationScope,
      onToolEvent: onToolEvent,
      emitStartEvent: emitStartEvent,
      forcedOutput: forcedOutput,
      forcedIsError: forcedIsError,
      appendToHistory: true,
    );
  }

  Future<String> _executeSingleToolCall(
    ToolCall toolCall, {
    required ToolExecutionCallbacks callbacks,
    RunCancellationScope? cancellationScope,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    bool emitStartEvent = true,
    String? forcedOutput,
    bool forcedIsError = false,
    required bool appendToHistory,
  }) async {
    final argumentsString = jsonEncode(toolCall.arguments);
    if (emitStartEvent && onToolEvent != null) {
      await _maybeEmitToolEvent(
        cancellationScope,
        emit: () => onToolEvent(
          toolName: toolCall.name,
          input: argumentsString,
          isError: false,
          isStart: true,
          toolRunId: toolCall.id,
        ),
      );
    }
    if (!_canPublishToolEvents(cancellationScope)) {
      return 'Error: Tool execution cancelled.';
    }

    String result;
    bool isError = forcedIsError;
    if (forcedOutput != null) {
      result = forcedOutput;
    } else {
      final tool = registry.getTool(toolCall.name);
      if (tool == null) {
        result = 'Error: Tool ${toolCall.name} not found';
        isError = true;
      } else {
        try {
          result = _applyLateResultIsolation(
            toolCall.id,
            await tool.execute(
              toolCall.arguments,
              context: _toolContextFor(
                toolCall,
                cancellationScope: cancellationScope,
              ),
            ),
          );
          if (_lockedCancelledResult(toolCall.id) != null) {
            isError = true;
          }
        } catch (e) {
          result = 'Error executing tool: $e';
          isError = true;
        }
      }
    }
    result = ToolOutputGuard.guardResult(result);
    if (!_canPublishToolEvents(cancellationScope)) return result;

    final isDeferredResult =
        DeferredToolResultDescriptor.tryParseToolResult(
          result,
          sessionId: sessionId,
          toolCallId: toolCall.id,
        ) !=
        null;
    if (onToolEvent != null && !isDeferredResult) {
      await _maybeEmitToolEvent(
        cancellationScope,
        emit: () => onToolEvent(
          toolName: toolCall.name,
          output: result,
          isError: isError,
          isStart: false,
          toolRunId: toolCall.id,
        ),
      );
    }

    if (appendToHistory) {
      await callbacks.addToolMessage(toolCall, result, isError: isError);
    }
    return result;
  }
}

/// Bridges history mutations from the coordinator back to the runner so the
/// coordinator never owns a history list.
abstract class ToolExecutionCallbacks {
  /// Appends a tool-result [Message] for [toolCall] with [result], notifies
  /// plugins, saves history, and deletes the suspended checkpoint for the
  /// tool call id.
  Future<void> addToolMessage(
    ToolCall toolCall,
    String result, {
    required bool isError,
  });

  /// Returns true if a tool message with [toolCallId] already exists in
  /// history (used to avoid duplicate appends after sequential execution).
  bool isToolMessagePresent(String toolCallId);

  /// Persists the current history to the session manager.
  void saveHistory();

  /// Returns the current history length.
  int currentHistoryLength();

  /// Delivers pending steer messages into the last tool-result messages after
  /// a tool batch completes.
  void applyPendingSteerToToolResults(int numToolCalls);
}
