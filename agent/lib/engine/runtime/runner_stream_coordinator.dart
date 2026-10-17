import 'dart:async';

import 'package:logging/logging.dart';

import '../../capabilities/registry/tools_registry.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/llm_provider_state.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../core/utils/scrubber.dart';
import '../../evolution/memory/file_memory_store.dart';
import '../../plugins/plugin_manager.dart';
import '../adapters/llm_adapter.dart';
import '../adapters/llm_request_options.dart';
import '../adapters/rate_limited_llm_adapter.dart';
import '../llm_request_dumper.dart';
import 'continuation_checkpoint_coordinator.dart';
import 'llm_route_snapshot.dart';
import 'response_continuation_coordinator.dart';
import 'run_cancellation_scope.dart';
import 'runner_admission_gate.dart';
import 'runner_recovery_coordinator.dart';
import 'runner_resume_coordinator.dart';
import 'steer_coordinator.dart' as steer_lib;
import 'tool_execution_coordinator.dart';
import 'turn_route_state.dart';

/// Host interface providing state and callbacks to [RunnerStreamCoordinator].
abstract class RunnerStreamHost {
  String get sessionId;
  List<Message> get history;
  void saveHistory();
  RunnerAdmissionGate get admissionGate;
  RunnerRecoveryCoordinator get recoveryCoordinator;
  RunnerResumeCoordinator get resumeCoordinator;
  TurnRouteState get turnRoute;
  ToolsRegistry get registry;
  FileMemoryStore get memoryStore;
  PluginManager get pluginManager;
  ContinuationCheckpointCoordinator get checkpointCoordinator;
  CheckpointContext get checkpointCtx;
  ToolExecutionCoordinator get toolExecutionCoordinator;
  steer_lib.SteerCoordinator get steerCoordinator;
  steer_lib.SteerCallbacks get steerCallbacks;
  ToolExecutionCallbacks get toolCallbacks;
  RunCancellationScope? get cancellationScope;
  bool shouldParallelizeToolBatch(List<ToolCall> toolCalls);

  /// Admits and freezes the turn route capability profile before the provider
  /// request is built, so later configuration changes cannot affect this turn.
  Future<void> admitTurnCapabilityProfile();

  /// Prunes image payloads whose turn has already been committed.
  void pruneProcessedHistoryImages();
  Future<Message> commitUserMessage(
    String? userContent, {
    String? requestId,
    DateTime? receivedAt,
  });
  FutureOr<void> Function(Message)? get onRootMessageCommitted;
  void beginModelStep();
  String? get currentModelStepId;
  String? get authoritativeRunId;
  void updateMetrics(AgentResponse response);
  void resetMetricsTracker(DateTime? receivedAt);
  void setActiveRoute(String? provider, String? model);
  void setLastSuccessfulLlmRoute(LLMRouteSnapshot snapshot);
  Future<void> stageInputUsageBaseline({
    required List<Message> requestMessages,
    required List<Map<String, dynamic>> toolSchemas,
    required String? providerId,
    required String? modelId,
  });
  Future<List<Message>> prepareProviderHistory({String? runtimeSystemPrompt});
  LLMRequestOptions requestOptionsForTurn(String? providerId);
}

/// Coordinates streaming responses, token chunk decoding, in-stream tool
/// call execution and looping, thought/reasoning deltas, and live steering.
class RunnerStreamCoordinator {
  static final Logger _logger = Logger('RunnerStreamCoordinator');

  final RunnerStreamHost host;

  RunnerStreamCoordinator(this.host);

  static LLMAdapter providerAdapterForBackground(LLMAdapter turnAdapter) {
    return switch (turnAdapter) {
      RateLimitedLLMAdapter() => turnAdapter.providerAdapter,
      _ => turnAdapter,
    };
  }

  static bool hasPersistableAssistantState(Message message) {
    return (message.content?.isNotEmpty ?? false) ||
        (message.toolCalls?.isNotEmpty ?? false) ||
        (message.thought?.isNotEmpty ?? false) ||
        (message.reasoning?.isNotEmpty ?? false) ||
        message.providerState != null ||
        message.finishReason != LLMFinishReason.unknown;
  }

  Stream<String> streamMessage(
    String? userContent, {
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    DateTime? receivedAt,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    if (host.admissionGate.stopRequested) return;
    host.admissionGate.resetStopRequested();
    host.memoryStore.resetConsolidationFailures();
    host.resetMetricsTracker(receivedAt);
    final effectiveRequestId = requestId ?? host.turnRoute.turnRequestId;
    host.turnRoute.configureTurn(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: effectiveRequestId,
    );
    await host.admitTurnCapabilityProfile();
    host.turnRoute.applyTurnSwitchIfNeeded();
    final durableRoot = await host.commitUserMessage(
      userContent,
      requestId: effectiveRequestId,
      receivedAt: receivedAt,
    );
    final onRootMessageCommitted = host.onRootMessageCommitted;
    if (onRootMessageCommitted != null) {
      await onRootMessageCommitted(durableRoot);
    }
    host.beginModelStep();
    host.checkpointCoordinator.saveCheckpoint(
      ctx: host.checkpointCtx,
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest,
      resumeHistoryLength: host.history.length,
    );

    final scrubber = StreamingScrubber();
    try {
      await for (final chunk in streamNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        onToolEvent: onToolEvent,
        onSteerContinuation: onSteerContinuation,
        onThoughtDelta: onThoughtDelta,
        onReasoningDelta: onReasoningDelta,
        preserveModelStepId: true,
      )) {
        final cleanChunk = scrubber.feed(chunk);
        if (cleanChunk.isNotEmpty) {
          yield cleanChunk;
        }
      }
    } finally {
      host.turnRoute.setTurnRequestId(null);
    }
  }

  Stream<String> resumeStream({
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    try {
      await host.resumeCoordinator.restoreCheckpointForResume(requestId: requestId);
    } catch (e) {
      host.checkpointCoordinator.blockWorkItemOnResumeFailure(e);
      rethrow;
    }
    final effectiveRequestId = requestId ?? host.turnRoute.turnRequestId;
    host.turnRoute.configureTurn(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: effectiveRequestId,
    );
    await host.admitTurnCapabilityProfile();
    host.turnRoute.applyTurnSwitchIfNeeded();

    final scrubber = StreamingScrubber();
    try {
      await for (final chunk in streamNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        onToolEvent: onToolEvent,
        onSteerContinuation: onSteerContinuation,
        onThoughtDelta: onThoughtDelta,
        onReasoningDelta: onReasoningDelta,
        preserveModelStepId: true,
      )) {
        final cleanChunk = scrubber.feed(chunk);
        if (cleanChunk.isNotEmpty) {
          yield cleanChunk;
        }
      }
    } finally {
      host.turnRoute.setTurnRequestId(null);
    }
  }

  Stream<String> streamNextResponse({
    String? runtimeSystemPrompt,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    bool preserveModelStepId = false,
    ResponseContinuationCoordinator? continuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    continuation ??= ResponseContinuationCoordinator();
    if (!preserveModelStepId || host.currentModelStepId == null) {
      host.beginModelStep();
    }
    host.checkpointCoordinator.saveCheckpoint(
      ctx: host.checkpointCtx,
      resumeHistoryLength: host.history.length,
    );
    final tools = host.registry.allTools.map((t) => t.schema).toList();

    host.steerCoordinator.drainPreApiSteer(host.steerCallbacks);

    var effectiveHistory = await host.prepareProviderHistory(
      runtimeSystemPrompt: runtimeSystemPrompt,
    );

    String fullContent = '';
    List<ToolCall>? accumulatedToolCalls;
    String? thought;
    String? reasoning;
    LLMProviderState? providerState;
    var finishReason = LLMFinishReason.unknown;
    final accumulatedMessageMetadata = <String, dynamic>{};

    bool isToolCall = false;
    Message? lastMessage;
    var streamStarted = false;

    final routing = host.turnRoute.resolveTurnRouting();
    var model = routing.model;
    var provider = routing.providerId;
    var baseUrl = routing.baseUrl;
    var apiKey = routing.apiKey;
    host.turnRoute.cacheResolvedRoute(host.turnRoute.adapterForTurn(), model);

    if (provider != null && model != null) {
      host.setActiveRoute(provider, model);
    }

    final attemptsByProviderInstanceId = <String, int>{};
    final failedProviderInstanceIds = <String>{};
    while (true) {
      if (host.admissionGate.stopRequested) return;
      try {
        final route = host.turnRoute.routeForTurn();
        final admitted = await host.admissionGate
            .claimProviderRequestAfterRestartDrain(
              checkpointCoordinator: host.checkpointCoordinator,
              checkpointCtx: host.checkpointCtx,
              historyLength: host.history.length,
            );
        if (!admitted) return;
        _logger.info('🧠 [Agent] Thinking...');
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpRequest(
            sessionId: host.sessionId,
            history: effectiveHistory,
            tools: tools,
            model: model,
            provider: provider,
            baseUrl: baseUrl,
            apiKey: apiKey,
          );
        }
        try {
          await host.stageInputUsageBaseline(
            requestMessages: effectiveHistory,
            toolSchemas: tools.map((tool) => tool.toJson()).toList(),
            providerId: provider,
            modelId: model,
          );
          await for (final response in route.adapter.generateStream(
            effectiveHistory,
            tools: tools,
            modelOverride: route.modelOverride,
            options: host.requestOptionsForTurn(provider),
          )) {
            if (host.admissionGate.stopRequested) return;
            host.recoveryCoordinator.clearResumingOnProviderProgress();
            streamStarted = true;
            host.updateMetrics(response);
            lastMessage = response.message;
            if (response.finishReason != LLMFinishReason.unknown) {
              finishReason = response.finishReason;
            }
            if (response.message.toolCalls?.isNotEmpty ?? false) {
              isToolCall = true;
              accumulatedToolCalls ??= [];
              accumulatedToolCalls.addAll(response.message.toolCalls!);
            }

            if (response.message.thought != null) {
              final thoughtDelta = response.message.thought!;
              thought = (thought ?? '') + thoughtDelta;
              if (thoughtDelta.isNotEmpty && onThoughtDelta != null) {
                await onThoughtDelta(thoughtDelta);
              }
            }
            if (response.message.reasoning != null) {
              final reasoningDelta = response.message.reasoning!;
              reasoning = (reasoning ?? '') + reasoningDelta;
              if (reasoningDelta.isNotEmpty && onReasoningDelta != null) {
                await onReasoningDelta(reasoningDelta);
              }
            }
            if (response.message.providerState != null) {
              providerState = response.message.providerState;
            }
            if (response.message.metadata != null) {
              accumulatedMessageMetadata.addAll(response.message.metadata!);
            }

            final chunk = response.message.content ?? '';
            fullContent += chunk;
            if (chunk.isNotEmpty) {
              yield chunk;
            }
          }
        } finally {
          if (host.admissionGate.stopRequested) {
            host.admissionGate.providerRequestInFlight = false;
          }
        }
        host.setLastSuccessfulLlmRoute(
          LLMRouteSnapshot(
            adapter: providerAdapterForBackground(route.adapter),
            providerInstanceId: provider,
            modelOverride: route.modelOverride,
          ),
        );
        if (host.admissionGate.stopRequested) return;
        break;
      } catch (e) {
        host.admissionGate.settleProviderRequest(
          checkpointCoordinator: host.checkpointCoordinator,
          checkpointCtx: host.checkpointCtx,
        );
        host.turnRoute.invalidateResolvedRoute();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.recordError(e);
        }
        final sanitizedHistory = host.recoveryCoordinator
            .recoverRejectedProviderState(e, continuation, effectiveHistory);
        if (sanitizedHistory != null) {
          effectiveHistory = sanitizedHistory;
          continue;
        }
        final providerAttempt = provider == null
            ? 0
            : attemptsByProviderInstanceId[provider] ?? 0;
        final handled = await host.recoveryCoordinator.handleRuntimeFailure(
          e,
          providerInstanceId: provider,
          modelId: model,
          attempt: providerAttempt,
          streamStarted: streamStarted,
          failedProviderInstanceIds: failedProviderInstanceIds,
          failedProviderProjection: effectiveHistory,
          failedProviderTools: tools,
        );
        if (!handled) {
          rethrow;
        }
        if (provider != null) {
          attemptsByProviderInstanceId[provider] = providerAttempt + 1;
        }
        final refreshedRouting = host.turnRoute.resolveTurnRouting();
        model = refreshedRouting.model;
        provider = refreshedRouting.providerId;
        baseUrl = refreshedRouting.baseUrl;
        apiKey = refreshedRouting.apiKey;
      }
    }
    host.turnRoute.invalidateResolvedRoute();

    if (host.admissionGate.stopRequested) return;

    if (lastMessage != null) {
      if (lastMessage.toolCalls != null && lastMessage.toolCalls!.isNotEmpty) {
        isToolCall = true;
      }

      final assistantMessage = Message(
        role: MessageRole.assistant,
        content: fullContent.isEmpty ? null : fullContent,
        toolCalls: accumulatedToolCalls ?? lastMessage.toolCalls,
        thought: thought ?? lastMessage.thought,
        reasoning: reasoning ?? lastMessage.reasoning,
        providerState: providerState ?? lastMessage.providerState,
        finishReason: finishReason == LLMFinishReason.unknown
            ? lastMessage.finishReason
            : finishReason,
        metadata: {
          ...accumulatedMessageMetadata,
          if (host.authoritativeRunId != null) 'run_id': host.authoritativeRunId,
          if (host.currentModelStepId != null)
            'model_step_id': host.currentModelStepId,
        },
      );
      if (hasPersistableAssistantState(assistantMessage)) {
        host.history.add(assistantMessage);
        await host.pluginManager.notifyMessage(assistantMessage);
        await host.pluginManager.runPostExecution(assistantMessage);
        host.saveHistory();
        host.pruneProcessedHistoryImages();
      }
      if (isToolCall && assistantMessage.toolCalls != null) {
        if (host.admissionGate.stopRequested) return;
        final toolCalls = assistantMessage.toolCalls!;
        host.admissionGate.settleProviderRequest(
          checkpointCoordinator: host.checkpointCoordinator,
          checkpointCtx: host.checkpointCtx,
        );
        if (host.admissionGate.stopRequested) return;
        await host.toolExecutionCoordinator.executeToolCalls(
          toolCalls,
          parallel: host.shouldParallelizeToolBatch(toolCalls),
          callbacks: host.toolCallbacks,
          ctx: host.checkpointCtx,
          cancellationScope: host.cancellationScope,
          onToolEvent: onToolEvent,
        );
        if (host.admissionGate.stopRequested) return;
        yield* streamNextResponse(
          runtimeSystemPrompt: runtimeSystemPrompt,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          continuation: continuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      } else {
        if (host.steerCoordinator.hasPendingSteers) {
          host.admissionGate.settleProviderRequest(
            checkpointCoordinator: host.checkpointCoordinator,
            checkpointCtx: host.checkpointCtx,
          );
          host.steerCoordinator.markLastAssistantSupersededBySteer(
            host.steerCallbacks,
          );
          host.steerCoordinator.appendPendingSteersAsUserMessages(
            host.steerCallbacks,
          );
          onSteerContinuation?.call();
          yield* streamNextResponse(
            runtimeSystemPrompt: runtimeSystemPrompt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            continuation: continuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
          return;
        }
        if (assistantMessage.finishReason == LLMFinishReason.incomplete &&
            continuation.claimIncompleteContinuation()) {
          host.admissionGate.settleProviderRequest(
            checkpointCoordinator: host.checkpointCoordinator,
            checkpointCtx: host.checkpointCtx,
          );
          yield* streamNextResponse(
            runtimeSystemPrompt: runtimeSystemPrompt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            continuation: continuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
          return;
        }
        if (host.authoritativeRunId == null) {
          host.admissionGate.settleProviderRequest(
            checkpointCoordinator: host.checkpointCoordinator,
            checkpointCtx: host.checkpointCtx,
          );
        }
        _logger.info('🏁 [Agent] Final answer committed');
      }
    } else if (fullContent.isNotEmpty) {
      _logger.info('🏁 [Agent] Final answer committed');
      final assistantMessage = Message(
        role: MessageRole.assistant,
        content: fullContent,
        metadata: {
          if (host.authoritativeRunId != null) 'run_id': host.authoritativeRunId,
          if (host.currentModelStepId != null)
            'model_step_id': host.currentModelStepId,
        },
      );
      host.history.add(assistantMessage);
      await host.pluginManager.notifyMessage(assistantMessage);
      await host.pluginManager.runPostExecution(assistantMessage);
      host.saveHistory();
      if (host.authoritativeRunId == null) {
        host.admissionGate.settleProviderRequest(
          checkpointCoordinator: host.checkpointCoordinator,
          checkpointCtx: host.checkpointCtx,
        );
      }
      if (host.steerCoordinator.hasPendingSteers) {
        host.admissionGate.settleProviderRequest(
          checkpointCoordinator: host.checkpointCoordinator,
          checkpointCtx: host.checkpointCtx,
        );
        host.steerCoordinator.markLastAssistantSupersededBySteer(
          host.steerCallbacks,
        );
        host.steerCoordinator.appendPendingSteersAsUserMessages(
          host.steerCallbacks,
        );
        onSteerContinuation?.call();
        yield* streamNextResponse(
          runtimeSystemPrompt: runtimeSystemPrompt,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      }
    }
  }

  Stream<String> resumeAfterToolCall({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    String? runtimeSystemPrompt,
    String? forcedOutput,
    bool forcedIsError = false,
    ToolEventCallback? onToolEvent,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    try {
      await host.toolExecutionCoordinator.executeSingleToolCall(
        ToolCall(id: toolCallId, name: toolName, arguments: arguments),
        callbacks: host.toolCallbacks,
        onToolEvent: onToolEvent,
        emitStartEvent: false,
        forcedOutput: forcedOutput,
        forcedIsError: forcedIsError,
      );
    } catch (e) {
      host.checkpointCoordinator.blockWorkItemOnResumeFailure(e);
      rethrow;
    }
    host.checkpointCoordinator.saveCheckpoint(
      ctx: host.checkpointCtx,
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindAfterToolResult,
      resumeHistoryLength: host.history.length,
    );
    yield* streamNextResponse(
      runtimeSystemPrompt: runtimeSystemPrompt,
      onToolEvent: onToolEvent,
      onThoughtDelta: onThoughtDelta,
      onReasoningDelta: onReasoningDelta,
    );
  }
}
