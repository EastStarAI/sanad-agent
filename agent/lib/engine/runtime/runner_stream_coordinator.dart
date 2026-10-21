import 'dart:async';

import 'package:logging/logging.dart';

import '../../capabilities/registry/tools_registry.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/llm_provider_state.dart';
import '../../core/models/llm_usage_snapshot.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../core/provider_runtime/runtime_recovery_exception.dart';
import '../../core/utils/scrubber.dart';
import '../../evolution/memory/file_memory_store.dart';
import '../../evolution/models/compaction_operation_record.dart';
import '../../plugins/plugin_manager.dart';
import '../adapters/llm_adapter.dart';
import '../adapters/llm_request_options.dart';
import '../adapters/provider_request_cancelled_exception.dart';
import '../adapters/rate_limited_llm_adapter.dart';
import '../llm_request_dumper.dart';
import 'continuation_checkpoint_coordinator.dart';
import 'llm_route_snapshot.dart';
import 'post_boundary_usage_reservation.dart';
import 'response_continuation_coordinator.dart';
import 'run_cancellation_scope.dart';
import 'runner_admission_gate.dart';
import 'runner_compaction_orchestrator.dart';
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
  RunnerCompactionOrchestrator get compactionOrchestrator;
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

  /// Compaction boundary of the provider projection built for the current
  /// request, or `null` when it has none.
  CompactionOperationRecord? get activeProjectionBoundary;

  /// Admits and freezes the turn route capability profile before the provider
  /// request is built, so later configuration changes cannot affect this turn.
  Future<void> admitTurnCapabilityProfile();

  /// Ends the turn's capability admission; only an admitted turn may move the
  /// frozen profile to a new route.
  void endTurnCapabilityAdmission();

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

  /// Records the dispatch route on the metrics and the active provider
  /// instance identity.
  void setActiveRoute(String? provider, String? model);
  void setLastSuccessfulLlmRoute(LLMRouteSnapshot snapshot);
  Future<List<Message>> prepareProviderHistory({String? runtimeSystemPrompt});
  LLMRequestOptions requestOptionsForTurn(
    String? providerId, {
    String? requestId,
  });

  /// One-shot thinking-field rejection handling: records the rejected
  /// selection for this session and reports whether the same request may be
  /// retried once without the field.
  bool retryWithoutRejectedThinkingField(Object error, String? provider);
}

/// Coordinates streaming turns: the cancellable turn stream, the provider
/// stream loop (token, reasoning and thought deltas, per-attempt post-boundary
/// usage reservations, the one-shot thinking-field retry, runtime recovery),
/// in-stream tool execution and its continuation, live steering, and resume
/// after a single tool call.
class RunnerStreamCoordinator {
  final RunnerStreamHost host;
  final Logger _logger;

  Future<void> _detachedTurnStreamUnwind = Future<void>.value();

  RunnerStreamCoordinator(this.host, {Logger? logger})
    : _logger = logger ?? Logger('RunnerStreamCoordinator');

  /// Completes once the most recently cancelled turn stream has unwound.
  Future<void> get detachedTurnStreamUnwind => _detachedTurnStreamUnwind;

  RunnerCompactionOrchestrator get _compaction => host.compactionOrchestrator;

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

  Stream<String> _cancellableTurnStream(
    Stream<String> source, {
    required StreamReservationHolder holder,
  }) {
    late StreamController<String> controller;
    StreamSubscription<String>? sub;

    controller = StreamController<String>(
      onListen: () {
        sub = source.listen(
          (data) => controller.add(data),
          onError: (Object e, StackTrace st) => controller.addError(e, st),
          onDone: () => controller.close(),
        );
      },
      onCancel: () {
        if (!holder.confirmed) {
          final res = holder.dispatchedReservation;
          if (res != null) {
            holder.dispatchedReservation = null;
            _compaction.finalizeReservation(res, 'no_provider_usage');
          }
        }
        // Stop acknowledgement must not await generator unwind (F3), so the
        // inner cancel future is detached. A generator suspended at an await
        // (for example a 429 `waitForRetry`) resumes after cancel and may
        // throw; that error completes this future with no listener. Contain
        // it here so a stopped run can never crash the daemon zone.
        final pending = sub?.cancel();
        if (pending != null) {
          _detachedTurnStreamUnwind = pending.then<void>(
            (_) {},
            onError: _reportDetachedTurnStreamUnwindError,
          );
        }
      },
    );
    return controller.stream;
  }

  static bool _isCancellationUnwindError(Object error) =>
      error is RuntimeRecoveryCancelled ||
      error is RateLimitCancelled ||
      error is ProviderRequestCancelledException;

  void _reportDetachedTurnStreamUnwindError(Object error, StackTrace stack) {
    // Cancellation signals are the expected end of a stopped run.
    if (_isCancellationUnwindError(error)) return;
    // Real failures still surface. Log the type only: error payloads can
    // carry provider bodies or user content and must not enter logs.
    _logger.severe(
      'Cancelled turn stream failed while unwinding for session '
      '${host.sessionId}: ${error.runtimeType}',
      null,
      stack,
    );
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
  }) {
    final holder = StreamReservationHolder();
    return _cancellableTurnStream(
      _streamMessageCore(
        userContent,
        requestId: requestId,
        runtimeSystemPrompt: runtimeSystemPrompt,
        providerId: providerId,
        model: model,
        thinkingMode: thinkingMode,
        receivedAt: receivedAt,
        onToolEvent: onToolEvent,
        onSteerContinuation: onSteerContinuation,
        onThoughtDelta: onThoughtDelta,
        onReasoningDelta: onReasoningDelta,
        streamReservationHolder: holder,
      ),
      holder: holder,
    );
  }

  Stream<String> _streamMessageCore(
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
    StreamReservationHolder? streamReservationHolder,
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
        streamReservationHolder: streamReservationHolder,
      )) {
        final cleanChunk = scrubber.feed(chunk);
        if (cleanChunk.isNotEmpty) {
          yield cleanChunk;
        }
      }
    } finally {
      host.turnRoute.setTurnRequestId(null);
      host.endTurnCapabilityAdmission();
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
  }) {
    final holder = StreamReservationHolder();
    return _cancellableTurnStream(
      _resumeStreamCore(
        requestId: requestId,
        runtimeSystemPrompt: runtimeSystemPrompt,
        providerId: providerId,
        model: model,
        thinkingMode: thinkingMode,
        onToolEvent: onToolEvent,
        onSteerContinuation: onSteerContinuation,
        onThoughtDelta: onThoughtDelta,
        onReasoningDelta: onReasoningDelta,
        streamReservationHolder: holder,
      ),
      holder: holder,
    );
  }

  Stream<String> _resumeStreamCore({
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
    StreamReservationHolder? streamReservationHolder,
  }) async* {
    try {
      await host.resumeCoordinator.restoreCheckpointForResume(
        requestId: requestId,
      );
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
        streamReservationHolder: streamReservationHolder,
      )) {
        final cleanChunk = scrubber.feed(chunk);
        if (cleanChunk.isNotEmpty) {
          yield cleanChunk;
        }
      }
    } finally {
      host.turnRoute.setTurnRequestId(null);
      host.endTurnCapabilityAdmission();
    }
  }

  void _settleProviderRequest() => host.admissionGate.settleProviderRequest(
    checkpointCoordinator: host.checkpointCoordinator,
    checkpointCtx: host.checkpointCtx,
  );

  Stream<String> streamNextResponse({
    String? runtimeSystemPrompt,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    bool preserveModelStepId = false,
    ResponseContinuationCoordinator? continuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
    StreamReservationHolder? streamReservationHolder,
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
    var thinkingFieldRetried = false;
    DispatchedReservation? dispatchedReservation;
    while (true) {
      final turnRequestId = host.turnRoute.turnRequestId ?? '';
      final stepRequestId = _compaction.stepRequestId();
      final providerAttempt = provider == null
          ? 0
          : attemptsByProviderInstanceId[provider] ?? 0;
      final attemptRequestId = providerAttempt == 0
          ? (turnRequestId.isNotEmpty ? turnRequestId : stepRequestId)
          : (turnRequestId.isNotEmpty
                ? '$turnRequestId:retry_$providerAttempt'
                : '$stepRequestId:retry_$providerAttempt');
      final activeBoundary = host.activeProjectionBoundary;
      final priorReservation = dispatchedReservation;
      if (priorReservation != null &&
          (activeBoundary == null ||
              activeBoundary.compactionId != priorReservation.compactionId)) {
        _compaction.finalizeReservation(priorReservation, 'no_provider_usage');
        dispatchedReservation = null;
        if (streamReservationHolder?.dispatchedReservation?.compactionId ==
            priorReservation.compactionId) {
          streamReservationHolder?.dispatchedReservation = null;
        }
      }
      var callRecordedUsage = false;

      void finalizeMissingUnlessRecorded([
        String reason = 'no_provider_usage',
      ]) {
        if (!callRecordedUsage) {
          final currentReservation = dispatchedReservation;
          if (currentReservation != null) {
            _compaction.finalizeReservation(currentReservation, reason);
            dispatchedReservation = null;
            if (streamReservationHolder?.dispatchedReservation?.compactionId ==
                currentReservation.compactionId) {
              streamReservationHolder?.dispatchedReservation = null;
            }
          } else {
            _compaction.finalizePostBoundaryMissingUsage(
              activeBoundary: activeBoundary,
              stepRequestId: stepRequestId,
              missingReason: reason,
            );
          }
        }
      }

      if (host.admissionGate.stopRequested) {
        finalizeMissingUnlessRecorded();
        return;
      }

      try {
        final route = host.turnRoute.routeForTurn();
        final admitted = await host.admissionGate
            .claimProviderRequestAfterRestartDrain(
              persistInFlightCheckpoint: () =>
                  host.checkpointCoordinator.saveCheckpoint(
                    ctx: host.checkpointCtx,
                    checkpointKind: ContinuationCheckpointCoordinator
                        .checkpointKindModelRequestInFlight,
                    resumeHistoryLength: host.history.length,
                  ),
            );
        if (!admitted) {
          finalizeMissingUnlessRecorded();
          return;
        }
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
            requestId: attemptRequestId,
          );
        }
        await _compaction.stageInputUsageBaseline(
          requestMessages: effectiveHistory,
          toolSchemas: tools.map((tool) => tool.toJson()).toList(),
          providerId: provider,
          modelId: model,
        );
        final reserved = _compaction.reservePostBoundaryDispatch(
          activeBoundary: activeBoundary,
          stepRequestId: stepRequestId,
        );
        if (reserved != null) {
          dispatchedReservation = reserved;
          streamReservationHolder?.dispatchedReservation = reserved;
          streamReservationHolder?.confirmed = false;
        }
        var streamFailedWithException = false;
        try {
          await for (final response in route.adapter.generateStream(
            effectiveHistory,
            tools: tools,
            modelOverride: route.modelOverride,
            options: host.requestOptionsForTurn(
              provider,
              requestId: attemptRequestId,
            ),
          )) {
            if (host.admissionGate.stopRequested) {
              finalizeMissingUnlessRecorded();
              return;
            }
            host.recoveryCoordinator.clearResumingOnProviderProgress();
            // Any provider event makes a transparent retry unsafe: reasoning,
            // metadata, or a partial tool call may already be visible or carry
            // state even when no final-content text has arrived yet.
            streamStarted = true;
            final responseUsage = response.usage;
            if (responseUsage != null) {
              final snapshot = LlmUsageSnapshot.fromProviderUsage(
                responseUsage,
              );
              if (snapshot.inputTokens != null) {
                callRecordedUsage = true;
                streamReservationHolder?.confirmed = true;
              }
            }
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
        } catch (e) {
          streamFailedWithException = true;
          rethrow;
        } finally {
          if (host.admissionGate.stopRequested) {
            host.admissionGate.providerRequestInFlight = false;
          }
          if (!streamFailedWithException) {
            finalizeMissingUnlessRecorded();
          }
        }
        host.setLastSuccessfulLlmRoute(
          LLMRouteSnapshot(
            adapter: providerAdapterForBackground(route.adapter),
            providerInstanceId: provider,
            modelOverride: route.modelOverride,
          ),
        );
        if (host.admissionGate.stopRequested) {
          finalizeMissingUnlessRecorded();
          return;
        }
        break;
      } catch (e) {
        _settleProviderRequest();
        host.turnRoute.invalidateResolvedRoute();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.recordError(e, requestId: attemptRequestId);
        }
        if (!thinkingFieldRetried &&
            !streamStarted &&
            host.retryWithoutRejectedThinkingField(e, provider)) {
          // Exactly one retry of the same request without the thinking field.
          thinkingFieldRetried = true;
          if (provider != null) {
            attemptsByProviderInstanceId[provider] =
                (attemptsByProviderInstanceId[provider] ?? 0) + 1;
          }
          continue;
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
        final previousProvider = provider;
        final previousModel = model;
        bool handled = false;
        try {
          handled = await host.recoveryCoordinator.handleRuntimeFailure(
            e,
            providerInstanceId: provider,
            modelId: model,
            attempt: providerAttempt,
            streamStarted: streamStarted,
            failedProviderInstanceIds: failedProviderInstanceIds,
            failedProviderProjection: effectiveHistory,
            failedProviderTools: tools,
          );
        } catch (failure) {
          finalizeMissingUnlessRecorded('no_provider_usage');
          rethrow;
        }
        if (!handled) {
          finalizeMissingUnlessRecorded('no_provider_usage');
          rethrow;
        }
        if (provider != null) {
          attemptsByProviderInstanceId[provider] = providerAttempt + 1;
        }
        final refreshedRouting = host.turnRoute.resolveTurnRouting();
        final routeChanged =
            refreshedRouting.providerId != previousProvider ||
            refreshedRouting.model != previousModel;
        if (routeChanged) {
          finalizeMissingUnlessRecorded('route_failover');
        }
        try {
          effectiveHistory = await host.prepareProviderHistory(
            runtimeSystemPrompt: runtimeSystemPrompt,
          );
        } catch (prepError) {
          finalizeMissingUnlessRecorded('no_provider_usage');
          rethrow;
        }
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
          if (host.authoritativeRunId != null)
            'run_id': host.authoritativeRunId,
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
        _settleProviderRequest();
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
          streamReservationHolder: streamReservationHolder,
        );
      } else {
        if (host.steerCoordinator.hasPendingSteers) {
          _settleProviderRequest();
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
            streamReservationHolder: streamReservationHolder,
          );
          return;
        }
        if (assistantMessage.finishReason == LLMFinishReason.incomplete &&
            continuation.claimIncompleteContinuation()) {
          _settleProviderRequest();
          yield* streamNextResponse(
            runtimeSystemPrompt: runtimeSystemPrompt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            continuation: continuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
            streamReservationHolder: streamReservationHolder,
          );
          return;
        }
        if (host.authoritativeRunId == null) {
          _settleProviderRequest();
        }
        _logger.info('🏁 [Agent] Final answer committed');
      }
    } else if (fullContent.isNotEmpty) {
      _logger.info('🏁 [Agent] Final answer committed');
      final assistantMessage = Message(
        role: MessageRole.assistant,
        content: fullContent,
        metadata: {
          if (host.authoritativeRunId != null)
            'run_id': host.authoritativeRunId,
          if (host.currentModelStepId != null)
            'model_step_id': host.currentModelStepId,
        },
      );
      host.history.add(assistantMessage);
      await host.pluginManager.notifyMessage(assistantMessage);
      await host.pluginManager.runPostExecution(assistantMessage);
      host.saveHistory();
      if (host.authoritativeRunId == null) {
        _settleProviderRequest();
      }
      if (host.steerCoordinator.hasPendingSteers) {
        _settleProviderRequest();
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
          streamReservationHolder: streamReservationHolder,
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
