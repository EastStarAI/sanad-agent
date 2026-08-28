import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/session_queue_provider_override.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/models/pending_steer_record.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import 'session_queue_coordinator.dart';
import 'session_turn_executor.dart';
import 'session_recovery_restorer.dart';
import 'session_turn_request_helpers.dart';
import 'suspended_checkpoint_store.dart';
import 'package:sanad_agent/engine/runtime/tool_terminalization_service.dart';

class SuspendedRun {
  final GatewayEvent event;
  final AgentTurnRequest request;
  final AgentRunner agentRunner;
  final String? workItemId;

  const SuspendedRun({
    required this.event,
    required this.request,
    required this.agentRunner,
    required this.workItemId,
  });
}

class SessionRunOrchestrator implements SessionQueueProviderOverride {
  static const controlledRestartCheckpointTimeout = Duration(minutes: 1);
  static const providerRestartCancellationTimeout = Duration(seconds: 5);
  static const runStopCleanupTimeout = Duration(seconds: 5);
  static const controlledRestartCheckpointPollInterval = Duration(
    milliseconds: 25,
  );
  final _logger = Logger('SessionRunOrchestrator');

  final Map<String, SuspendedRun> _suspendedEvents = {};
  final Map<String, Future<void>> _stopRequests = {};
  final Set<String> _busySessions = {};
  final Set<String> _resumingSessions = {};
  bool _controlledRestartDraining = false;

  final _responseController = StreamController<GatewayResponse>.broadcast();
  Stream<GatewayResponse> get responses => _responseController.stream;

  late final SessionQueueCoordinator _queueCoordinator;
  late final SessionTurnExecutor _turnExecutor;

  /// Optional durable store for suspended runs and queued messages. Wired by
  /// DI when `PersistedRuntimeStateRepository` is registered; null in tests
  /// that do not exercise persistence.
  PersistedRuntimeStateRepository? _persistedState;
  PersistedRuntimeStateRepository? get persistedState {
    if (_persistedState != null) return _persistedState;
    if (getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      _persistedState = getIt<PersistedRuntimeStateRepository>();
    }
    return _persistedState;
  }

  SessionRunOrchestrator() {
    _queueCoordinator = SessionQueueCoordinator(
      getPersistedState: () => persistedState,
      defaultModelForProvider: _defaultModelForProvider,
    );
    _turnExecutor = SessionTurnExecutor(
      emitResponse: _emitResponse,
      getPersistedState: () => persistedState,
    );
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().attachResumeHandler(_autoResumeWaiting);
    }
  }

  List<GatewayEvent> getQueuedEvents(String sessionId) {
    return _queueCoordinator.getQueuedEvents(sessionId);
  }

  void cancelPendingSteer({
    required String sessionId,
    required String targetRequestId,
    required String commandRequestId,
  }) {
    final activeRun = _turnExecutor.getActiveRun(sessionId);
    final store = persistedState;
    final mutation = activeRun == null || store == null
        ? const PendingSteerMutation(PendingSteerCancelOutcome.notFound, null)
        : store.pendingInputs.cancel(
            sessionId: sessionId,
            requestId: targetRequestId,
            runId: activeRun.runId,
            generation: activeRun.generation,
          );
    if (mutation.outcome == PendingSteerCancelOutcome.cancelled ||
        mutation.outcome == PendingSteerCancelOutcome.alreadyCancelled) {
      activeRun?.agentRunner.cancelBufferedPendingSteer(targetRequestId);
    }
    _emitPendingSteerChanged(null, mutation.record);
    _emitCommandOutcome(
      sessionId: sessionId,
      type: 'session.pending_steer_cancel_result',
      targetRequestId: targetRequestId,
      commandRequestId: commandRequestId,
      outcome: _wireName(mutation.outcome.name),
    );
  }

  void deleteQueuedMessage({
    required String sessionId,
    required String targetRequestId,
    required String commandRequestId,
  }) {
    final store = persistedState;
    final result = store == null
        ? const QueueMutationResult(QueueMutationOutcome.notFound)
        : store.executionState.deleteQueuedMessage(
            sessionId: sessionId,
            requestId: targetRequestId,
          );
    if (result.outcome == QueueMutationOutcome.deleted ||
        result.outcome == QueueMutationOutcome.alreadyRemoved) {
      _queueCoordinator.removeQueuedRunByRequestId(sessionId, targetRequestId);
    }
    _emitCommandOutcome(
      sessionId: sessionId,
      type: 'session.queued_message_delete_result',
      targetRequestId: targetRequestId,
      commandRequestId: commandRequestId,
      outcome: _wireName(result.outcome.name),
    );
  }

  bool acknowledgeStopRecovery(
    String sessionId,
    String stopRequestId, {
    String? claimantId,
    String? recoveryOwnerToken,
  }) {
    return persistedState?.pendingInputs.acknowledgeStopOutcome(
          sessionId,
          stopRequestId,
          claimantId: claimantId,
          recoveryOwnerToken: recoveryOwnerToken,
        ) ??
        false;
  }

  bool isSessionBusy(String sessionId) {
    return _busySessions.contains(sessionId) ||
        _suspendedEvents.containsKey(sessionId) ||
        persistedState?.findActiveWorkItem(sessionId) != null;
  }

  bool hasSuspendedEvent(String sessionId) =>
      _suspendedEvents.containsKey(sessionId);

  /// Updates the route on the active [AgentRunner] for [sessionId] if one
  /// exists (Plan 30 Phase H P1). Delegates to [AgentRunner.updateTurnRoute]
  /// so the next retry iteration uses the new provider/model.
  void updateActiveRunnerRoute(
    String sessionId, {
    String? providerId,
    String? modelId,
  }) {
    _turnExecutor
        .getActiveRun(sessionId)
        ?.agentRunner
        .updateTurnRoute(providerId: providerId, modelId: modelId);
  }

  Future<ResumeSuspendedResult> resumeSuspended(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
    String? recoveryReason,
    String? recoveryMessage,
    Future<void> Function()? onClaimed,
  }) async {
    if (_controlledRestartDraining) {
      return ResumeSuspendedResult.restartDraining;
    }
    if (_resumingSessions.contains(sessionId) ||
        _isResumeAlreadyInFlight(sessionId)) {
      return ResumeSuspendedResult.alreadyResuming;
    }
    final suspended = _suspendedEvents[sessionId];
    if (suspended == null) {
      return _isResumeAlreadyInFlight(sessionId)
          ? ResumeSuspendedResult.alreadyResuming
          : ResumeSuspendedResult.missing;
    }
    _resumingSessions.add(sessionId);
    final hasRoute =
        (providerInstanceId != null && providerInstanceId.isNotEmpty) ||
        (modelId != null && modelId.isNotEmpty);
    try {
      final resumedRequest = overrideTurnRoute(
        suspended.request,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        defaultModelForProvider: _defaultModelForProvider,
      );
      if (hasRoute) {
        _queueCoordinator.rewriteQueuedRoute(
          sessionId,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          persist: !getIt.isRegistered<SessionRouteMutationCoordinator>(),
        );
        suspended.agentRunner.updateTurnRoute(
          providerId: providerInstanceId,
          modelId: modelId,
        );
      }
      final activeItem = persistedState?.findActiveWorkItem(sessionId);
      if (activeItem != null) {
        if (activeItem.state == SessionWorkState.resuming) {
          return ResumeSuspendedResult.alreadyResuming;
        }
        persistedState?.transitionWorkItemState(
          workItemId: activeItem.workItemId,
          fromState: activeItem.state,
          toState: SessionWorkState.resuming,
        );
      }
      _busySessions.add(sessionId);
      if (onClaimed != null) {
        await onClaimed();
      }
      if (recoveryReason != null &&
          getIt.isRegistered<RuntimeRecoveryService>()) {
        final recovery = getIt<RuntimeRecoveryService>();
        recovery.abort(sessionId);
        recovery.emitResuming(
          sessionId: sessionId,
          reason: recoveryReason,
          requestId: resumedRequest.requestId,
          providerInstanceId:
              providerInstanceId ?? resumedRequest.effectiveProviderInstanceId,
          message: recoveryMessage,
        );
      }
      if (recoveryReason == 'manual_retry' ||
          recoveryReason == 'provider_changed') {
        suspended.agentRunner.allowManualAmbiguousToolRecovery();
      }
      await _runTurn(
        event: suspended.event,
        turnRequest: resumedRequest,
        agentRunner: suspended.agentRunner,
        isResume: true,
        workItemId: suspended.workItemId,
      );
      if (_shouldRetainSuspendedOwnership(sessionId)) {
        _suspendedEvents[sessionId] = SuspendedRun(
          event: suspended.event,
          request: resumedRequest,
          agentRunner: suspended.agentRunner,
          workItemId: suspended.workItemId,
        );
      } else {
        _suspendedEvents.remove(sessionId);
        _drainNextQueuedEvent(sessionId);
      }
      return ResumeSuspendedResult.claimed;
    } finally {
      _resumingSessions.remove(sessionId);
    }
  }

  bool _isResumeAlreadyInFlight(String sessionId) {
    if (_resumingSessions.contains(sessionId)) return true;
    final activeItem = persistedState?.findActiveWorkItem(sessionId);
    if (activeItem?.state == SessionWorkState.resuming) {
      return true;
    }
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      final notice = getIt<RuntimeRecoveryService>().activeNotice(sessionId);
      if (notice?.status == RuntimeNoticeStatus.resuming) {
        return true;
      }
    }
    return false;
  }

  bool _shouldRetainSuspendedOwnership(String sessionId) {
    final activeItem = persistedState?.findActiveWorkItem(sessionId);
    if (activeItem != null &&
        (activeItem.state == SessionWorkState.waiting ||
            activeItem.state == SessionWorkState.blocked ||
            activeItem.state == SessionWorkState.resuming)) {
      return true;
    }
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      final notice = getIt<RuntimeRecoveryService>().activeNotice(sessionId);
      if (notice != null &&
          (notice.status == RuntimeNoticeStatus.waiting ||
              notice.status == RuntimeNoticeStatus.blocked ||
              notice.status == RuntimeNoticeStatus.resuming)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _autoResumeWaiting(RuntimeNotice notice) async {
    final sessionId = notice.sessionId;
    if (_busySessions.contains(sessionId)) {
      return;
    }
    _logger.info(
      'Auto-resuming restored waiting session $sessionId after resume_at.',
    );
    final resumed = await resumeSuspended(
      sessionId,
      providerInstanceId: notice.providerInstanceId,
      recoveryReason: 'auto_resume',
      recoveryMessage: 'Automatically resuming the last request.',
    );
    if (resumed == ResumeSuspendedResult.missing &&
        getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.unknown,
        requestId: notice.requestId,
        providerInstanceId: notice.providerInstanceId,
        title: 'Saved work could not be resumed automatically',
        message:
            'The daemon could not find the saved work needed for auto-resume. '
            'The session was blocked so you can retry, change provider, or stop.',
        forceBlocked: true,
      );
    }
  }

  /// Plan 30: requests a stop for [sessionId] from outside the normal gateway
  /// event flow (e.g. `session.runtime_stop`).
  ///
  /// Phase H §1 (Never-Trapped Session): this works in `waiting`,
  /// `blocked`, and `fatal` states independently of any client-side
  /// `processing` flag. It is idempotent: calling it from multiple clients
  /// or when the session is already idle is a safe no-op. It cancels any
  /// active run + wait/retry, deletes suspended work and all unexecuted
  /// queued messages, preserves completed history/results and any partial
  /// reply, and returns the session to `idle` ready for a new message.
  Future<void> requestStop(
    String sessionId, {
    bool forceEmitStopped = false,
    String? stopRequestId,
    String? recoveryOwnerToken,
  }) {
    final existing = _stopRequests[sessionId];
    if (existing != null) {
      return existing;
    }
    final future = _requestStop(
      sessionId,
      forceEmitStopped: forceEmitStopped,
      stopRequestId: stopRequestId,
      recoveryOwnerToken: recoveryOwnerToken,
    );
    _stopRequests[sessionId] = future;
    void clearCompletedStop() {
      if (identical(_stopRequests[sessionId], future)) {
        _stopRequests.remove(sessionId);
      }
    }

    unawaited(
      future.then<void>(
        (_) => clearCompletedStop(),
        onError: (Object _, StackTrace _) => clearCompletedStop(),
      ),
    );
    return future;
  }

  Future<void> _requestStop(
    String sessionId, {
    required bool forceEmitStopped,
    required String? stopRequestId,
    required String? recoveryOwnerToken,
  }) async {
    final activeRun = _turnExecutor.getActiveRun(sessionId);
    final stoppedRunId = activeRun?.runId;
    final stoppedModelStepId = activeRun?.agentRunner.currentModelStepId;
    final hadWork =
        forceEmitStopped ||
        activeRun != null ||
        _busySessions.contains(sessionId) ||
        _suspendedEvents.containsKey(sessionId) ||
        _queueCoordinator.hasQueuedEvents(sessionId);
    final capturedWorkItemIds =
        persistedState
            ?.findAllWorkItems(sessionId)
            .where(
              (item) =>
                  item.state != SessionWorkState.completed &&
                  item.state != SessionWorkState.cancelled,
            )
            .map((item) => item.workItemId)
            .toSet() ??
        <String>{};
    if (hadWork) {
      persistedState?.markSessionStopping(
        sessionId,
        expectedWorkItemId: activeRun?.workItemId,
      );
    }
    final recoveryOutcome =
        stopRequestId == null ||
            recoveryOwnerToken == null ||
            recoveryOwnerToken.isEmpty
        ? null
        : persistedState?.executionState.captureStopRecovery(
            sessionId: sessionId,
            stopRequestId: stopRequestId,
            recoveryOwnerToken: recoveryOwnerToken,
          );
    if (activeRun != null && recoveryOutcome != null) {
      activeRun.agentRunner.removeBufferedPendingSteers(
        recoveryOutcome.items
            .where((item) => item.source == 'pending_steer')
            .map((item) => item.requestId),
      );
    }
    Future<void>? stopFuture;
    if (activeRun != null) {
      _logger.info(
        'Runtime stop: cancelling active run for session $sessionId',
      );
      // Invalidate synchronously before any await. Messages received while the
      // subscription cancellation is pending belong to the next generation and
      // must remain queued.
      stopFuture = activeRun.requestStop();
    }
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().abort(sessionId, runId: activeRun?.runId);
    }
    // Clear only work that existed before the cancellation await. A new message
    // arriving after this point is intentionally preserved.
    _queueCoordinator.removePendingEvents(sessionId);
    _suspendedEvents.remove(sessionId);
    // Gate E.1: clear/stop must remove memory and durable state atomically.
    // The recovery service's in-memory notice and cancel token are cleared
    // here so requestStop (whether called from the event path or directly)
    // always leaves the session fully idle.
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      final recovery = getIt<RuntimeRecoveryService>();
      recovery.abort(sessionId, runId: activeRun?.runId);
      recovery.clear(
        sessionId,
        reasonOverride: 'stopped',
        runId: activeRun?.runId,
      );
    }
    if (stopFuture != null) {
      try {
        await stopFuture.timeout(runStopCleanupTimeout);
      } on TimeoutException {
        _logger.warning(
          'Run stop cleanup exceeded the bounded deadline for session '
          '$sessionId; publication remains invalidated.',
        );
      } on RuntimeRecoveryCancelled catch (error) {
        // Stop intentionally aborts an active recovery wait. The stream
        // cancellation can surface that expected lifecycle transition through
        // the subscription cancellation Future; durable cleanup must continue.
        _logger.info(
          'Runtime recovery cancelled while stopping session $sessionId: '
          '$error',
        );
      } on RuntimeRecoveryRequired catch (error) {
        // Recovery can race with Stop before stream cancellation completes.
        // Stop is authoritative and must still transition durable state to idle.
        _logger.info(
          'Runtime recovery transition superseded by stop for session '
          '$sessionId: $error',
        );
      }
    }
    if (activeRun != null) {
      final terminalRecords =
          ToolTerminalizationService(
            repository: persistedState,
            sessionManager: getIt<SessionManager>(),
          ).terminalizeExecutingTools(
            sessionId: sessionId,
            agentRunner: activeRun.agentRunner,
            runId: activeRun.runId,
            generation: activeRun.generation,
            modelStepId: stoppedModelStepId,
          );
      for (final record in terminalRecords) {
        _emitResponse(
          GatewayResponse(
            sessionId: sessionId,
            message: Message(
              role: MessageRole.tool,
              content: record.message,
              metadata: record.toHistoryMetadata(
                modelStepId: stoppedModelStepId,
              ),
            ),
            isComplete: true,
            runId: record.runId,
            modelStepId: stoppedModelStepId,
            toolCallId: record.toolCallId,
            toolName: record.toolName,
            isToolResult: true,
            isToolError: record.isError,
            isToolCancelled: record.isTerminalCancelled,
          ),
        );
      }
    }
    final hasNewerDurableWork =
        persistedState
            ?.findAllWorkItems(sessionId)
            .any(
              (item) =>
                  item.state != SessionWorkState.completed &&
                  item.state != SessionWorkState.cancelled &&
                  !capturedWorkItemIds.contains(item.workItemId),
            ) ??
        false;
    if (hasNewerDurableWork) {
      persistedState?.cancelWorkItems(sessionId, capturedWorkItemIds);
    } else {
      persistedState?.clearAllForSession(sessionId);
    }
    if (hadWork) {
      _emitResponse(
        GatewayResponse(
          sessionId: sessionId,
          message: Message(
            role: MessageRole.assistant,
            content: 'Execution stopped.',
            metadata: {
              'canonical_event_type': 'stopped',
              'canonical_payload': {
                'session_id': sessionId,
                'run_id': ?stoppedRunId,
                'model_step_id': ?stoppedModelStepId,
              },
            },
          ),
          isComplete: true,
          runId: stoppedRunId,
          modelStepId: stoppedModelStepId,
        ),
      );
    }
    if (recoveryOutcome != null) {
      _emitResponse(
        GatewayResponse(
          sessionId: sessionId,
          message: Message(
            role: MessageRole.system,
            metadata: {
              'canonical_event_type': 'session.stop_draft_recovery',
              'canonical_payload': recoveryOutcome.toPayload(),
            },
          ),
          isComplete: true,
        ),
      );
    }
    if (activeRun == null ||
        identical(_turnExecutor.getActiveRun(sessionId), activeRun) ||
        _turnExecutor.getActiveRun(sessionId) == null) {
      _turnExecutor.removeActiveRun(sessionId);
      _busySessions.remove(sessionId);
      _drainNextQueuedEvent(sessionId);
    }
  }

  /// Cancels provider streams that exhausted the controlled-restart timeout
  /// without terminally stopping or replaying their durable work.
  Future<void> interruptProviderRequestsForRestart(
    Iterable<ControlledRestartBlocker> blockers,
  ) async {
    final providerBlockers = blockers.where(
      (blocker) => blocker.providerRequestInFlight,
    );
    await Future.wait(
      providerBlockers.map((blocker) async {
        final activeRun = _turnExecutor.getActiveRun(blocker.sessionId);
        if (activeRun == null ||
            !_turnExecutor.ownsRun(activeRun) ||
            activeRun.workItemId != blocker.workItemId ||
            activeRun.runId != blocker.runId ||
            activeRun.generation != blocker.generation ||
            !activeRun.agentRunner.providerRequestInFlight) {
          return;
        }

        final item = blocker.workItemId == null
            ? null
            : persistedState?.findWorkItem(blocker.workItemId!);
        if (item == null ||
            (item.state != SessionWorkState.running &&
                item.state != SessionWorkState.resuming) ||
            item.continuationMetadata['owner_run_id'] != blocker.runId ||
            item.continuationMetadata['owner_generation'] !=
                blocker.generation ||
            item.continuationMetadata['checkpoint_kind'] !=
                ContinuationCheckpointCoordinator
                    .checkpointKindModelRequestInFlight) {
          return;
        }

        final metadata = Map<String, dynamic>.from(item.continuationMetadata)
          ..['restart_interrupted_provider_request'] = true;
        persistedState?.transitionWorkItemState(
          workItemId: item.workItemId,
          fromState: item.state,
          toState: SessionWorkState.blocked,
          continuationMetadata: metadata,
        );

        if (getIt.isRegistered<RuntimeRecoveryService>()) {
          getIt<RuntimeRecoveryService>().reportFailure(
            sessionId: blocker.sessionId,
            reason: RuntimeFailureReason.unknown,
            requestId: item.requestId,
            providerInstanceId: item.providerInstanceId,
            title: 'Provider request interrupted for restart',
            message:
                'The provider did not finish before the restart timeout. The request was cancelled and will not be sent again automatically. Retry, change provider, or stop the session.',
            forceBlocked: true,
            runId: activeRun.runId,
          );
        }

        try {
          await activeRun.requestStop().timeout(
            providerRestartCancellationTimeout,
          );
        } on TimeoutException {
          _logger.warning(
            'Provider stream cancellation exceeded the restart cleanup timeout '
            'for session ${blocker.sessionId}; publication remains invalidated.',
          );
        }
      }),
    );
  }

  /// Stops all daemon-owned work before a controlled restart.
  Future<void> requestStopAll() async {
    final sessionIds = <String>{
      ..._busySessions,
      ..._suspendedEvents.keys,
      ..._queueCoordinator.sessionIds,
      ..._turnExecutor.activeSessionIds,
    };
    await Future.wait(
      sessionIds.map(
        (sessionId) => requestStop(sessionId, forceEmitStopped: true),
      ),
    );
  }

  /// Waits for running tool work to reach a durable restart-safe checkpoint.
  ///
  /// The restart HTTP response may be consumed by `shell_execute` inside the
  /// active turn. Exiting on a fixed acknowledgement delay can kill that tool
  /// before its result and `after_tool_result` checkpoint are persisted,
  /// causing startup to classify the turn as an interrupted non-idempotent
  /// tool. A controlled restart therefore waits until every running/resuming
  /// durable owner is at a recognized checkpoint with no executing tools.
  void beginControlledRestartDrain() {
    _controlledRestartDraining = true;
    for (final activeRun in _turnExecutor.activeRuns.values) {
      activeRun.agentRunner.beginControlledRestartDrain();
    }
  }

  void cancelControlledRestartDrain() {
    if (!_controlledRestartDraining) return;
    _controlledRestartDraining = false;
    for (final activeRun in _turnExecutor.activeRuns.values) {
      activeRun.agentRunner.cancelControlledRestartDrain();
    }
    for (final sessionId in _queueCoordinator.sessionIds.toList()) {
      if (!isSessionBusy(sessionId)) {
        _drainNextQueuedEvent(sessionId);
      }
    }
  }

  Future<ControlledRestartCheckpointResult> waitForControlledRestartCheckpoint({
    Duration timeout = controlledRestartCheckpointTimeout,
    Duration pollInterval = controlledRestartCheckpointPollInterval,
    String? requesterSessionId,
    String? requesterToolCallId,
    bool requireRequesterCompletion = false,
  }) async {
    final store = persistedState;
    if (store == null) return ControlledRestartCheckpointResult.safe;
    final elapsed = Stopwatch()..start();
    while (true) {
      final blockers = <ControlledRestartBlocker>[];
      for (final sessionId in store.findAllSessionIdsWithWorkItems()) {
        final item = store.findActiveWorkItem(sessionId);
        if (item == null ||
            (item.state != SessionWorkState.running &&
                item.state != SessionWorkState.resuming)) {
          continue;
        }
        final metadata = item.continuationMetadata;
        final activeRun = _turnExecutor.getActiveRun(sessionId);
        final providerRequestInFlight =
            activeRun != null &&
            _turnExecutor.ownsRun(activeRun) &&
            activeRun.agentRunner.providerRequestInFlight;
        final checkpointKind = metadata['checkpoint_kind']?.toString();
        final recognizedCheckpoint =
            checkpointKind == AgentRunner.checkpointKindInitialModelRequest ||
            checkpointKind ==
                ContinuationCheckpointCoordinator
                    .checkpointKindModelRequestInFlight ||
            checkpointKind == AgentRunner.checkpointKindAfterToolResult;
        final completedResults = Map<String, dynamic>.from(
          metadata['completed_tool_results'] as Map? ?? const {},
        );
        final deferredResults = Map<String, dynamic>.from(
          metadata['deferred_tool_results'] as Map? ?? const {},
        );
        bool hasValidDeferredResult(String toolCallId) {
          final descriptor = DeferredToolResultDescriptor.tryParseMetadata(
            deferredResults[toolCallId],
          );
          return descriptor != null &&
              descriptor.requesterSessionId == sessionId &&
              descriptor.requesterToolCallId == toolCallId;
        }

        final executingTools =
            List<String>.from(
                  metadata['currently_executing_tools'] as List? ?? const [],
                )
                .where((toolCallId) {
                  if (completedResults.containsKey(toolCallId)) return false;
                  if (hasValidDeferredResult(toolCallId)) return false;
                  return !(!requireRequesterCompletion &&
                      sessionId == requesterSessionId &&
                      toolCallId == requesterToolCallId);
                })
                .toList(growable: false);
        final requesterCompletionSafe =
            !requireRequesterCompletion ||
            sessionId != requesterSessionId ||
            (checkpointKind == AgentRunner.checkpointKindAfterToolResult &&
                requesterToolCallId != null &&
                completedResults.containsKey(requesterToolCallId)) ||
            (requesterToolCallId != null &&
                hasValidDeferredResult(requesterToolCallId));
        if (!recognizedCheckpoint ||
            providerRequestInFlight ||
            executingTools.isNotEmpty ||
            !requesterCompletionSafe) {
          blockers.add(
            ControlledRestartBlocker(
              sessionId: sessionId,
              toolCallIds: executingTools,
              checkpointRecognized: recognizedCheckpoint,
              providerRequestInFlight: providerRequestInFlight,
              workItemId: item.workItemId,
              runId: activeRun?.runId,
              generation: activeRun?.generation,
            ),
          );
        }
      }
      if (blockers.isEmpty) return ControlledRestartCheckpointResult.safe;
      if (elapsed.elapsed >= timeout) {
        return ControlledRestartCheckpointResult(
          isSafe: false,
          blockers: blockers,
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  void _emitResponse(GatewayResponse response) {
    _responseController.add(response);
  }

  void _emitMessageClassification(
    GatewayEvent event, {
    required String requestId,
    required String classification,
    DateTime? receivedAt,
  }) {
    _emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': 'session.message_classified',
            'canonical_payload': {
              'session_id': event.sessionId,
              'request_id': requestId,
              'classification': classification,
              if (receivedAt != null)
                'received_at': receivedAt.toUtc().toIso8601String(),
            },
          },
        ),
        isComplete: true,
        runId: event.runId,
      ),
    );
  }

  void _emitPendingSteerChanged(
    String? platformId,
    PendingSteerRecord? record,
  ) {
    if (record == null) return;
    _emitResponse(
      GatewayResponse(
        sessionId: record.sessionId,
        platformId: platformId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': 'session.pending_steer_changed',
            'canonical_payload': record.toPayload(),
          },
        ),
        isComplete: true,
        runId: record.runId,
      ),
    );
  }

  void _emitCommandOutcome({
    required String sessionId,
    required String type,
    required String targetRequestId,
    required String commandRequestId,
    required String outcome,
  }) {
    _emitResponse(
      GatewayResponse(
        sessionId: sessionId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': type,
            'canonical_payload': {
              'session_id': sessionId,
              'target_request_id': targetRequestId,
              'command_request_id': commandRequestId,
              'outcome': outcome,
            },
          },
        ),
        isComplete: true,
      ),
    );
  }

  static String _wireName(String value) {
    return value.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => '_${match.group(0)!.toLowerCase()}',
    );
  }

  Future<void> handleEvent(GatewayEvent event) async {
    _logger.info('Incoming event for session: ${event.sessionId}');
    _logger.fine('Content: ${event.message.content}');

    if (event.type == 'stop') {
      _logger.info('Received STOP command for session: ${event.sessionId}');
      var forceEmitStopped = false;
      if (getIt.isRegistered<RuntimeRecoveryService>()) {
        final recovery = getIt<RuntimeRecoveryService>();
        forceEmitStopped = recovery.hasActiveNotice(event.sessionId);
      }
      await requestStop(
        event.sessionId,
        forceEmitStopped: forceEmitStopped,
        stopRequestId: requestIdForEvent(event),
        recoveryOwnerToken:
            (event.metadata['payload'] as Map?)?['recovery_owner_token']
                ?.toString(),
      );
      return;
    }

    if (event.type != 'create_session') {
      final sessionManager = getIt<SessionManager>();
      final existingSession = sessionManager.getSession(event.sessionId);
      final requestedWorkspaceId = _resolveWorkspaceId(
        event,
        fallback: existingSession?.workspaceId,
      );
      final turnRequest = _buildTurnRequest(
        event,
        requestedWorkspaceId: requestedWorkspaceId,
      );
      final activeRun = _turnExecutor.getActiveRun(event.sessionId);
      final durableActiveWork = persistedState?.findActiveWorkItem(
        event.sessionId,
      );
      final activeRecoveryNotice = getIt.isRegistered<RuntimeRecoveryService>()
          ? getIt<RuntimeRecoveryService>().activeNotice(event.sessionId)
          : null;
      final canSteer =
          !_controlledRestartDraining &&
          turnRequest.deliveryIntent == MessageDeliveryIntent.auto &&
          activeRun != null &&
          _turnExecutor.ownsRun(activeRun) &&
          !activeRun.stopRequested &&
          (durableActiveWork == null ||
              durableActiveWork.state == SessionWorkState.running ||
              durableActiveWork.state == SessionWorkState.resuming) &&
          (activeRecoveryNotice == null ||
              activeRecoveryNotice.status == RuntimeNoticeStatus.resuming);
      if (canSteer) {
        final requestId = turnRequest.requestId ?? requestIdForEvent(event);
        final text = event.message.content?.trim() ?? '';
        if (requestId != null && text.isNotEmpty) {
          final receivedAt = DateTime.now().toUtc();
          final store = persistedState;
          var pending = store?.pendingInputs.find(event.sessionId, requestId);
          final existingWork = store?.workItems.findByRequestId(
            event.sessionId,
            requestId,
          );
          if (existingWork?.state == SessionWorkState.queued) {
            final promoted = store!.executionState.promoteQueuedToPendingSteer(
              sessionId: event.sessionId,
              requestId: requestId,
              runId: activeRun.runId,
              generation: activeRun.generation,
              text: text,
              receivedAt: receivedAt,
            );
            if (promoted.outcome != QueueMutationOutcome.promoted) {
              _emitMessageClassification(
                event,
                requestId: requestId,
                classification: 'queue',
              );
              return;
            }
            pending = promoted.pendingSteer;
            _queueCoordinator.removeQueuedRunByRequestId(
              event.sessionId,
              requestId,
            );
          } else if (existingWork != null) {
            _emitMessageClassification(
              event,
              requestId: requestId,
              classification: existingWork.state == SessionWorkState.completed
                  ? 'think'
                  : 'queue',
            );
            return;
          } else {
            pending ??= store?.pendingInputs.insertPending(
              sessionId: event.sessionId,
              requestId: requestId,
              runId: activeRun.runId,
              generation: activeRun.generation,
              text: text,
              receivedAt: receivedAt,
            );
          }
          pending ??= store == null
              ? PendingSteerRecord(
                  sessionId: event.sessionId,
                  requestId: requestId,
                  runId: activeRun.runId,
                  generation: activeRun.generation,
                  text: text,
                  receivedAt: receivedAt,
                  state: PendingSteerState.pending,
                  revision: 1,
                  updatedAt: receivedAt,
                )
              : null;
          if (pending == null ||
              pending.runId != activeRun.runId ||
              pending.generation != activeRun.generation ||
              pending.state.name != 'pending') {
            _emitPendingSteerChanged(event.platformId, pending);
            return;
          }
          if (store != null) {
            activeRun.agentRunner.configurePendingSteerLifecycle(
              runId: activeRun.runId,
              generation: activeRun.generation,
              onChanged: (record) => _emitPendingSteerChanged(null, record),
            );
          }
          activeRun.agentRunner.steerEvent(
            text,
            requestId: requestId,
            receivedAt: receivedAt,
          );
          sessionManager.recordCanonicalUserMessageAccepted(
            event.sessionId,
            receivedAt,
          );
          _emitPendingSteerChanged(event.platformId, pending);
          _emitMessageClassification(
            event,
            requestId: requestId,
            classification: 'steer',
          );
          return;
        }
      }

      final hasOlderWork =
          _controlledRestartDraining ||
          isSessionBusy(event.sessionId) ||
          _queueCoordinator.hasQueuedEvents(event.sessionId);
      if (hasOlderWork) {
        _logger.info('Session ${event.sessionId} is busy. Queuing message.');
        final receivedAt = DateTime.now();
        final queuedTurnRequest = turnRequest.copyWith(
          metadata: {
            ...turnRequest.metadata,
            'received_at': receivedAt.toUtc().toIso8601String(),
          },
        );
        final existingWork = turnRequest.requestId == null
            ? null
            : persistedState?.workItems.findByRequestId(
                event.sessionId,
                turnRequest.requestId!,
              );
        if (existingWork != null) {
          _emitMessageClassification(
            event,
            requestId: turnRequest.requestId!,
            classification: existingWork.state == SessionWorkState.queued
                ? 'queue'
                : 'think',
          );
          if (!isSessionBusy(event.sessionId)) {
            _drainNextQueuedEvent(event.sessionId);
          }
          return;
        }
        _queueCoordinator.enqueue(
          event.sessionId,
          event,
          queuedTurnRequest,
          SessionWorkState.queued,
        );
        sessionManager.recordCanonicalUserMessageAccepted(
          event.sessionId,
          receivedAt,
        );

        final requestId =
            queuedTurnRequest.requestId ?? requestIdForEvent(event);
        _emitResponse(
          GatewayResponse(
            sessionId: event.sessionId,
            platformId: event.platformId,
            message: Message(
              role: MessageRole.user,
              content: event.message.content,
              metadata: {
                'queued': true,
                'request_id': requestId,
                'received_at': receivedAt.toUtc().toIso8601String(),
              },
            ),
            isComplete: true,
            runId: event.runId,
          ),
        );
        if (requestId != null) {
          _emitMessageClassification(
            event,
            requestId: requestId,
            classification: 'queue',
            receivedAt: receivedAt,
          );
        }

        // Plan 30 Phase H §4: Check if the session is in recovery (waiting or blocked)
        final recovery = getIt.isRegistered<RuntimeRecoveryService>()
            ? getIt<RuntimeRecoveryService>()
            : null;
        if (turnRequest.deliveryIntent == MessageDeliveryIntent.auto &&
            recovery != null &&
            recovery.hasActiveNotice(event.sessionId)) {
          final newProvider = turnRequest.effectiveProviderInstanceId;
          final newModel = turnRequest.model;

          // 1. Update suspended run in memory
          final suspended = _suspendedEvents[event.sessionId];
          if (suspended != null) {
            _suspendedEvents[event.sessionId] = SuspendedRun(
              event: suspended.event,
              request: overrideTurnRoute(
                suspended.request,
                providerInstanceId: newProvider,
                modelId: newModel,
                defaultModelForProvider: _defaultModelForProvider,
              ),
              agentRunner: suspended.agentRunner,
              workItemId: suspended.workItemId,
            );
          }

          // 2. Update queue
          _queueCoordinator.rewriteQueuedRoute(
            event.sessionId,
            providerInstanceId: newProvider,
            modelId: newModel,
            persist: !getIt.isRegistered<SessionRouteMutationCoordinator>(),
          );

          // 3. Update session preferences
          final currentSession = sessionManager.getSession(event.sessionId);
          final resolvedProvider = newProvider ?? currentSession?.providerId;
          final resolvedModel = newModel ?? currentSession?.model;
          if (resolvedProvider != null &&
              resolvedModel != null &&
              getIt.isRegistered<SessionRouteMutationCoordinator>()) {
            getIt<SessionRouteMutationCoordinator>().mutate(
              sessionId: event.sessionId,
              providerInstanceId: resolvedProvider,
              model: resolvedModel,
              source: SessionRouteSource.recovery,
              reason: 'recovery_message_route',
              requestId: turnRequest.requestId,
              publish: true,
            );
          } else {
            sessionManager.updateSessionModeling(
              event.sessionId,
              providerId: newProvider,
              model: newModel,
            );
          }

          // 4. Update the active AgentRunner's route so the retry loop uses the
          // new provider/model as soon as the wait is aborted (P1 fix).
          _turnExecutor
              .getActiveRun(event.sessionId)
              ?.agentRunner
              .updateTurnRoute(providerId: newProvider, modelId: newModel);

          // 5. Abort the active wait or block
          recovery.abort(event.sessionId);

          // 6. If it was suspended/blocked, resume execution. If it was waiting,
          // aborting the wait above resumes the retry loop in the AgentRunner.
          if (suspended != null) {
            Future.microtask(
              () => resumeSuspended(
                event.sessionId,
                providerInstanceId: newProvider,
                modelId: newModel,
                recoveryReason: 'new_message',
                recoveryMessage: 'Resuming last request with the new route.',
              ),
            );
          } else {
            recovery.emitResuming(
              sessionId: event.sessionId,
              reason: 'new_message',
              requestId: requestId,
              providerInstanceId: newProvider,
              message: 'Resuming last request with the new route.',
            );
          }
        }

        return;
      }
      if (turnRequest.requestId != null) {
        _emitMessageClassification(
          event,
          requestId: turnRequest.requestId!,
          classification: 'think',
        );
      }
    }

    final sessionManager = getIt<SessionManager>();
    final existingSession = sessionManager.getSession(event.sessionId);
    var titleOwnerSession = existingSession;
    final isNewSession = existingSession == null;
    final requestedWorkspaceId = _resolveWorkspaceId(
      event,
      fallback: existingSession?.workspaceId,
    );
    final turnRequest = _buildTurnRequest(
      event,
      requestedWorkspaceId: requestedWorkspaceId,
    );
    final payloadModel = turnRequest.model;

    if (isNewSession) {
      final initialTitle = _resolveInitialSessionTitle(event);
      final sessionMetadata = await _buildWorkspaceSessionMetadata(
        requestedWorkspaceId,
      );

      final model = (payloadModel != null && payloadModel.isNotEmpty)
          ? payloadModel
          : (getIt.isRegistered<Config>()
                ? getIt<Config>().llmModel
                : 'sanad-agent');

      final session = SessionState(
        sessionId: event.sessionId,
        model: model,
        providerId: turnRequest.effectiveProviderInstanceId,
        thinkingMode: turnRequest.thinkingMode,
        title: initialTitle.title,
        titleStatus: initialTitle.isPlaceholder
            ? SessionTitleStatus.pending
            : SessionTitleStatus.finalized,
        workspaceId: _workspaceIdFromMetadata(
          sessionMetadata,
          fallback: requestedWorkspaceId,
        ),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      sessionManager.db.saveSession(session);
      titleOwnerSession = session;
      if (sessionMetadata.isNotEmpty) {
        sessionManager.saveSessionMetadata(event.sessionId, sessionMetadata);
      }

      _emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: Message(
            role: MessageRole.assistant,
            content: initialTitle.title,
          ),
          isSessionCreated: true,
          isComplete: true,
          runId: event.runId,
          sessionPayload: buildSessionPayload(
            session: session,
            sessionMetadata: sessionMetadata,
          ),
        ),
      );

      if (event.type == 'create_session') {
        return;
      }
    } else if (payloadModel != null && payloadModel.isNotEmpty) {
      final provider =
          turnRequest.effectiveProviderInstanceId ?? existingSession.providerId;
      if (provider != null &&
          provider.isNotEmpty &&
          getIt.isRegistered<SessionRouteMutationCoordinator>()) {
        getIt<SessionRouteMutationCoordinator>().mutate(
          sessionId: event.sessionId,
          providerInstanceId: provider,
          model: payloadModel,
          source: SessionRouteSource.user,
          reason: 'turn_route',
          requestId: turnRequest.requestId,
          publish: true,
        );
      } else {
        sessionManager.updateSessionModel(event.sessionId, payloadModel);
      }
    }

    if (existingSession != null &&
        requestedWorkspaceId != null &&
        requestedWorkspaceId.isNotEmpty &&
        existingSession.workspaceId != requestedWorkspaceId) {
      final resolvedWorkspaceMetadata = await _buildWorkspaceSessionMetadata(
        requestedWorkspaceId,
      );
      sessionManager.db.saveSession(
        SessionState(
          sessionId: existingSession.sessionId,
          model: existingSession.model,
          providerId: existingSession.providerId,
          thinkingMode: existingSession.thinkingMode,
          title: existingSession.title,
          titleStatus: existingSession.titleStatus,
          workspaceId: _workspaceIdFromMetadata(
            resolvedWorkspaceMetadata,
            fallback: requestedWorkspaceId,
          ),
          createdAt: existingSession.createdAt,
          updatedAt: DateTime.now(),
          lastUserMessageAt: existingSession.lastUserMessageAt,
          routeRevision: existingSession.routeRevision,
          routeUpdatedAt: existingSession.routeUpdatedAt,
          messages: existingSession.messages,
        ),
      );
    }

    final agentRunner = getIt<AgentRunner>(param1: event.sessionId);
    final receivedAt = DateTime.now();
    final liveTurnRequest = turnRequest.copyWith(
      metadata: {
        ...turnRequest.metadata,
        'received_at': receivedAt.toUtc().toIso8601String(),
      },
    );
    final liveWorkItem = _queueCoordinator.enqueue(
      event.sessionId,
      event,
      liveTurnRequest,
      SessionWorkState.running,
    );
    sessionManager.recordCanonicalUserMessageAccepted(
      event.sessionId,
      receivedAt,
    );
    if (liveWorkItem?.state == SessionWorkState.queued) {
      final requestId = liveTurnRequest.requestId ?? requestIdForEvent(event);
      _emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: Message(
            role: MessageRole.user,
            content: event.message.content,
            metadata: {
              'queued': true,
              'request_id': requestId,
              'received_at': receivedAt.toUtc().toIso8601String(),
            },
          ),
          isComplete: true,
          runId:
              event.runId ?? 'queued_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      return;
    }
    _busySessions.add(event.sessionId);
    await _runTurn(
      event: event,
      turnRequest: liveTurnRequest,
      agentRunner: agentRunner,
      isNewSession: isNewSession,
      existingSession: titleOwnerSession,
      payloadModel: payloadModel,
      workItemId: liveWorkItem?.workItemId,
    );
  }

  Future<void> _runTurn({
    required GatewayEvent event,
    required AgentTurnRequest turnRequest,
    required AgentRunner agentRunner,
    bool isResume = false,
    bool isNewSession = false,
    SessionState? existingSession,
    String? payloadModel,
    String? workItemId,
  }) async {
    await _turnExecutor.runTurn(
      event: event,
      turnRequest: turnRequest,
      agentRunner: agentRunner,
      isResume: isResume,
      isNewSession: isNewSession,
      existingSession: existingSession,
      payloadModel: payloadModel,
      workItemId: workItemId,
      onRecoveryRequired: _handleRecoveryRequired,
      onTurnComplete: () {
        _busySessions.remove(event.sessionId);
        if (!_suspendedEvents.containsKey(event.sessionId)) {
          _drainNextQueuedEvent(event.sessionId);
        }
      },
    );
  }

  void _handleRecoveryRequired(
    GatewayEvent event,
    AgentTurnRequest request,
    AgentRunner agentRunner,
    String? workItemId,
  ) {
    _suspendedEvents[event.sessionId] = SuspendedRun(
      event: event,
      request: request,
      agentRunner: agentRunner,
      workItemId: workItemId,
    );
    _persistSuspendedRun(event.sessionId, event, request, workItemId);
  }

  void _persistSuspendedRun(
    String sessionId,
    GatewayEvent event,
    AgentTurnRequest request,
    String? workItemId,
  ) {
    final store = persistedState;
    if (store == null) return;
    final activeItem = workItemId == null
        ? null
        : store.findWorkItem(workItemId);
    if (activeItem != null) {
      final recovery = getIt.isRegistered<RuntimeRecoveryService>()
          ? getIt<RuntimeRecoveryService>()
          : null;
      final notice = recovery?.activeNotice(sessionId);
      final nextState = notice?.status == RuntimeNoticeStatus.waiting
          ? SessionWorkState.waiting
          : SessionWorkState.blocked;
      store.transitionWorkItemState(
        workItemId: activeItem.workItemId,
        fromState: activeItem.state,
        toState: nextState,
      );
    }
  }

  void _drainNextQueuedEvent(String sessionId) {
    if (_controlledRestartDraining) {
      return;
    }
    if (isSessionBusy(sessionId)) {
      return;
    }
    final nextRun = _queueCoordinator.claimNext(sessionId);
    if (nextRun == null) {
      return;
    }
    _logger.info('Processing next queued event for session: $sessionId');
    _busySessions.add(sessionId);
    Future.microtask(
      () => _runTurn(
        event: nextRun.event,
        turnRequest: nextRun.request,
        agentRunner: getIt<AgentRunner>(param1: sessionId),
        isResume: nextRun.isResume,
        workItemId: nextRun.workItemId,
      ),
    );
  }

  AgentTurnRequest _buildTurnRequest(
    GatewayEvent event, {
    String? requestedWorkspaceId,
  }) {
    return event.turnRequest ??
        AgentTurnRequest(
          sessionId: event.sessionId,
          message: event.message.content ?? '',
          workspaceId: requestedWorkspaceId,
          model: event.metadata['payload']?['model'] as String?,
          providerInstanceId:
              event.metadata['payload']?['provider_instance_id'] as String?,
          providerId: event.metadata['payload']?['provider_id'] as String?,
          thinkingMode: event.metadata['payload']?['thinking_mode'] as String?,
          requestId: event.metadata['payload']?['request_id'] as String?,
          deliveryIntent:
              event.metadata['payload']?['delivery_intent'] == 'queue'
              ? MessageDeliveryIntent.queue
              : MessageDeliveryIntent.auto,
        );
  }

  String? _defaultModelForProvider(String providerInstanceId) {
    if (!getIt.isRegistered<ProviderInstanceRepository>()) {
      return null;
    }
    return getIt<ProviderInstanceRepository>()
        .findById(providerInstanceId)
        ?.defaultModel;
  }

  @override
  void rewriteQueuedProvider(String sessionId, String providerInstanceId) {
    rewriteQueuedRoute(
      sessionId,
      providerInstanceId: providerInstanceId,
      persist: !getIt.isRegistered<SessionRouteMutationCoordinator>(),
    );
  }

  /// Phase H §3: rewrites both provider and model on every queued request so
  /// the route is consistent (no stale model id reaches a new provider).
  /// Gate E.2: when [allNonTerminal] is true the durable route rewrite covers
  /// every non-terminal work item (queued, running, waiting, blocked,
  /// resuming) so a provider/model change after restart updates suspended
  /// and blocked work as well, not only queued items.
  void rewriteQueuedRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
    bool allNonTerminal = false,
    bool persist = true,
  }) {
    _queueCoordinator.rewriteQueuedRoute(
      sessionId,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      allNonTerminal: allNonTerminal,
      persist: persist,
    );
  }

  ({String title, bool isPlaceholder}) _resolveInitialSessionTitle(
    GatewayEvent event,
  ) {
    final payload = event.metadata['payload'];
    final payloadMap = payload is Map<String, dynamic>
        ? payload
        : payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final explicitTitle = payloadMap['title']?.toString().trim();
    if (explicitTitle != null && explicitTitle.isNotEmpty) {
      return (
        title: explicitTitle,
        isPlaceholder: payloadMap['title_is_placeholder'] == true,
      );
    }

    final goal = event.message.content?.trim();
    if (goal != null && goal.isNotEmpty) {
      final snippet = goal.split('\n').first;
      final title = snippet.length > 60
          ? '${snippet.substring(0, 57).trim()}...'
          : snippet;
      return (title: title, isPlaceholder: true);
    }

    return (title: 'Chat', isPlaceholder: true);
  }

  String? _resolveWorkspaceId(GatewayEvent event, {String? fallback}) {
    final directWorkspaceId = event.turnRequest?.workspaceId?.trim();
    if (directWorkspaceId != null && directWorkspaceId.isNotEmpty) {
      return directWorkspaceId;
    }

    final payload = event.metadata['payload'];
    final payloadMap = payload is Map<String, dynamic>
        ? payload
        : payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final payloadWorkspaceId = payloadMap['workspace_id']?.toString().trim();
    if (payloadWorkspaceId != null && payloadWorkspaceId.isNotEmpty) {
      return payloadWorkspaceId;
    }

    final normalizedFallback = fallback?.trim();
    if (normalizedFallback == null || normalizedFallback.isEmpty) {
      return null;
    }
    return normalizedFallback;
  }

  Future<Map<String, dynamic>> _buildWorkspaceSessionMetadata(
    String? workspaceId,
  ) async {
    final normalizedWorkspaceId = workspaceId?.trim();
    if (normalizedWorkspaceId == null || normalizedWorkspaceId.isEmpty) {
      return const {};
    }

    final metadata = <String, dynamic>{'workspace_id': normalizedWorkspaceId};
    final workspace = await getIt<LocalWorkspaceRuntimeService>()
        .describeWorkspace(normalizedWorkspaceId);
    if (workspace == null) {
      return metadata;
    }

    metadata['workspace'] = workspace;
    final resolvedWorkspaceId = workspace['id']?.toString();
    if (resolvedWorkspaceId != null && resolvedWorkspaceId.isNotEmpty) {
      metadata['workspace_id'] = resolvedWorkspaceId;
    }
    final workspaceName = workspace['name']?.toString();
    final workspacePath = workspace['path']?.toString();
    if (workspaceName != null && workspaceName.isNotEmpty) {
      metadata['workspace_name'] = workspaceName;
    }
    if (workspacePath != null && workspacePath.isNotEmpty) {
      metadata['workspace_path'] = workspacePath;
    }
    return metadata;
  }

  String? _workspaceIdFromMetadata(
    Map<String, dynamic> metadata, {
    String? fallback,
  }) {
    final fromWorkspace = metadata['workspace'];
    if (fromWorkspace is Map) {
      final workspaceId = fromWorkspace['id']?.toString().trim();
      if (workspaceId != null && workspaceId.isNotEmpty) {
        return workspaceId;
      }
    }

    final topLevel = metadata['workspace_id']?.toString().trim();
    if (topLevel != null && topLevel.isNotEmpty) {
      return topLevel;
    }

    final normalizedFallback = fallback?.trim();
    if (normalizedFallback == null || normalizedFallback.isEmpty) {
      return null;
    }
    return normalizedFallback;
  }

  /// Rebuilds in-memory suspended runs, queued messages, and runtime notices
  /// from SQLite after a daemon restart. Called once during startup after DI
  /// is ready and before any new gateway events are processed.
  ///
  /// Sessions with persisted suspended work are marked busy so that a new
  /// message from the client triggers the recovery banner instead of starting
  /// a fresh turn. The client re-hydrates the notice via
  /// `get_session_history` (which reads the persisted notice).
  Future<void> restorePersistedState() async {
    final restartRecoveries =
        persistedState?.pendingInputs.reconcileAfterRestart() ?? const [];
    for (final outcome in restartRecoveries) {
      _emitResponse(
        GatewayResponse(
          sessionId: outcome.sessionId,
          message: Message(
            role: MessageRole.system,
            metadata: {
              'canonical_event_type': 'session.stop_draft_recovery',
              'canonical_payload': outcome.toPayload(),
            },
          ),
          isComplete: true,
        ),
      );
    }
    final restorer = SessionRecoveryRestorer(
      getPersistedState: () => persistedState,
      queueCoordinator: _queueCoordinator,
      suspendedEvents: _suspendedEvents,
      busySessions: _busySessions,
      listAwaitingSuspensions: _listAwaitingSuspensions,
      runTurnCallback:
          ({
            required GatewayEvent event,
            required AgentTurnRequest turnRequest,
            required AgentRunner agentRunner,
            required bool isResume,
          }) => _runRestoredTurn(
            event: event,
            turnRequest: turnRequest,
            agentRunner: agentRunner,
            isResume: isResume,
          ),
      resumeSuspendedCallback: _resumeRestoredSuspended,
    );
    await restorer.restorePersistedState();
  }

  /// Gate F.1 fallback: when startup restore fails partway, do not leave
  /// persisted work in an unknown silent state. Instead, convert each
  /// affected session into a controllable blocked notice so the client can
  /// retry, change provider, or stop explicitly.
  void markRestoreFailureAsBlocked({Object? error}) {
    final restorer = SessionRecoveryRestorer(
      getPersistedState: () => persistedState,
      queueCoordinator: _queueCoordinator,
      suspendedEvents: _suspendedEvents,
      busySessions: _busySessions,
      listAwaitingSuspensions: _listAwaitingSuspensions,
      runTurnCallback:
          ({
            required GatewayEvent event,
            required AgentTurnRequest turnRequest,
            required AgentRunner agentRunner,
            required bool isResume,
          }) => _runRestoredTurn(
            event: event,
            turnRequest: turnRequest,
            agentRunner: agentRunner,
            isResume: isResume,
          ),
      resumeSuspendedCallback: _resumeRestoredSuspended,
    );
    restorer.markRestoreFailureAsBlocked(error: error);
  }

  Future<List<SuspendedCheckpoint>> _listAwaitingSuspensions() {
    if (!getIt.isRegistered<SuspendedCheckpointStore>()) {
      return Future.value(const <SuspendedCheckpoint>[]);
    }
    return getIt<SuspendedCheckpointStore>().listAwaitingPermission();
  }

  Future<void> _runRestoredTurn({
    required GatewayEvent event,
    required AgentTurnRequest turnRequest,
    required AgentRunner agentRunner,
    required bool isResume,
  }) async {
    // The queue/restorer has already performed the durable claim before this
    // callback. Capture that exact owner once for both normal and resume turns
    // so terminal callbacks never rediscover a different session-wide item.
    final restoredWorkItemId = persistedState
        ?.findActiveWorkItem(event.sessionId)
        ?.workItemId;
    final recovery = isResume && getIt.isRegistered<RuntimeRecoveryService>()
        ? getIt<RuntimeRecoveryService>()
        : null;
    recovery?.emitResuming(
      sessionId: event.sessionId,
      reason: 'daemon_restart',
      requestId: turnRequest.requestId,
      providerInstanceId: turnRequest.effectiveProviderInstanceId,
      message: 'Resuming the interrupted request from its saved checkpoint.',
    );

    await _runTurn(
      event: event,
      turnRequest: turnRequest,
      agentRunner: agentRunner,
      isResume: isResume,
      workItemId: restoredWorkItemId,
    );

    if (recovery != null &&
        restoredWorkItemId != null &&
        persistedState?.findWorkItem(restoredWorkItemId)?.state ==
            SessionWorkState.completed) {
      recovery.clearResumingOnProgress(event.sessionId);
    }
  }

  Future<void> _resumeRestoredSuspended(String sessionId) async {
    final result = await resumeSuspended(
      sessionId,
      recoveryReason: 'daemon_restart',
      recoveryMessage:
          'Resuming the interrupted request from its saved checkpoint.',
    );
    if (result == ResumeSuspendedResult.missing &&
        getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.unknown,
        title: 'Saved recovery work is unavailable',
        message:
            'The daemon could not claim the restored request. Retry, change provider, or stop the session.',
        forceBlocked: true,
      );
    }
  }

  void dispose() {
    _queueCoordinator.removePendingEvents('');
    _turnExecutor.activeRuns.clear();
    _responseController.close();
  }
}

class ControlledRestartBlocker {
  const ControlledRestartBlocker({
    required this.sessionId,
    required this.toolCallIds,
    required this.checkpointRecognized,
    this.providerRequestInFlight = false,
    this.workItemId,
    this.runId,
    this.generation,
  });

  final String sessionId;
  final List<String> toolCallIds;
  final bool checkpointRecognized;
  final bool providerRequestInFlight;
  final String? workItemId;
  final String? runId;
  final int? generation;

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'tool_call_ids': toolCallIds,
    'reason': providerRequestInFlight
        ? 'active_provider_request'
        : checkpointRecognized
        ? 'active_tool_execution'
        : 'unrecognized_checkpoint',
  };
}

class ControlledRestartCheckpointResult {
  const ControlledRestartCheckpointResult({
    required this.isSafe,
    this.blockers = const [],
  });

  final bool isSafe;
  final List<ControlledRestartBlocker> blockers;

  static const safe = ControlledRestartCheckpointResult(isSafe: true);
}

enum ResumeSuspendedResult {
  claimed,
  alreadyResuming,
  missing,
  restartDraining,
}
