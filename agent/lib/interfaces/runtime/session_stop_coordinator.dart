import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/runtime/tool_terminalization_service.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';

import 'session_queue_coordinator.dart';
import 'session_turn_executor.dart';

/// Coordinates graceful and authoritative session stopping, active run
/// cancellation, tool terminalization, stop draft recovery, and queue draining.
class SessionStopCoordinator {
  SessionStopCoordinator({
    required SessionTurnExecutor turnExecutor,
    required SessionQueueCoordinator queueCoordinator,
    required Set<String> busySessions,
    required Map<String, Object?> suspendedEvents,
    required PersistedRuntimeStateRepository? Function() getPersistedState,
    required Future<List<SuspendedCheckpoint>> Function()
    listRecoverableSuspensions,
    required void Function(GatewayResponse) emitResponse,
    required void Function(String sessionId) drainNextQueuedEvent,
    this.runStopCleanupTimeout = const Duration(seconds: 5),
    Logger? logger,
  })  : _turnExecutor = turnExecutor,
        _queueCoordinator = queueCoordinator,
        _busySessions = busySessions,
        _suspendedEvents = suspendedEvents,
        _getPersistedState = getPersistedState,
        _listRecoverableSuspensions = listRecoverableSuspensions,
        _emitResponse = emitResponse,
        _drainNextQueuedEvent = drainNextQueuedEvent,
        _logger = logger ?? Logger('SessionStopCoordinator');

  final SessionTurnExecutor _turnExecutor;
  final SessionQueueCoordinator _queueCoordinator;
  final Set<String> _busySessions;
  final Map<String, Object?> _suspendedEvents;
  final PersistedRuntimeStateRepository? Function() _getPersistedState;
  final Future<List<SuspendedCheckpoint>> Function() _listRecoverableSuspensions;
  final void Function(GatewayResponse) _emitResponse;
  final void Function(String sessionId) _drainNextQueuedEvent;
  final Duration runStopCleanupTimeout;
  final Logger _logger;

  final Map<String, Future<void>> _stopRequests = {};

  /// Requests a stop for [sessionId] from outside the normal gateway event flow.
  ///
  /// Works in `waiting`, `blocked`, and `fatal` states independently of any
  /// client-side `processing` flag. It is idempotent: calling it from multiple
  /// clients or when the session is already idle is a safe no-op.
  Future<void> requestStop(
    String sessionId, {
    bool forceEmitStopped = false,
    String? stopRequestId,
    String? recoveryOwnerToken,
    bool preserveInteractiveWait = false,
  }) {
    final existing = _stopRequests[sessionId];
    if (existing != null) {
      return existing;
    }
    final future = _executeStop(
      sessionId,
      forceEmitStopped: forceEmitStopped,
      stopRequestId: stopRequestId,
      recoveryOwnerToken: recoveryOwnerToken,
      preserveInteractiveWait: preserveInteractiveWait,
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

  Future<void> _executeStop(
    String sessionId, {
    required bool forceEmitStopped,
    required String? stopRequestId,
    required String? recoveryOwnerToken,
    required bool preserveInteractiveWait,
  }) async {
    if (preserveInteractiveWait &&
        await _tryPreserveInteractiveWait(sessionId)) {
      return;
    }
    final persistedState = _getPersistedState();
    final activeRun = _turnExecutor.getActiveRun(sessionId);
    final stoppedRunId = activeRun?.runId;
    final stoppedTurnId = activeRun?.turnId;
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
    if (activeRun != null && activeRun.workItemId != null) {
      final cleanupReport = activeRun.cancellationScope.report;
      final terminalRecords =
          ToolTerminalizationService(
            repository: persistedState,
          ).terminalizeExecutingTools(
            sessionId: sessionId,
            agentRunner: activeRun.agentRunner,
            workItemId: activeRun.workItemId!,
            runId: activeRun.runId,
            generation: activeRun.generation,
            modelStepId: stoppedModelStepId,
            cleanupOutcome:
                cleanupReport?.finalState.name ??
                activeRun.cancellationScope.state.name,
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
            turnId: stoppedTurnId,
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
    final deferredExecutionChange = hasNewerDurableWork
        ? persistedState?.cancelWorkItems(
            sessionId,
            capturedWorkItemIds,
            publishExecutionChange: false,
          )
        : persistedState?.clearAllForSession(
            sessionId,
            publishExecutionChange: false,
          );
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
                'turn_id': ?stoppedTurnId,
                'model_step_id': ?stoppedModelStepId,
              },
            },
          ),
          isComplete: true,
          runId: stoppedRunId,
          turnId: stoppedTurnId,
          modelStepId: stoppedModelStepId,
        ),
      );
      // Durable cleanup is already committed, but response delivery is
      // asynchronous while execution-snapshot publication is synchronous.
      // Let the cancelled tool terminal and stopped acknowledgement reach
      // clients before publishing the final idle/queued snapshot.
      await Future<void>.delayed(Duration.zero);
    }
    if (deferredExecutionChange != null) {
      persistedState?.executionState.publishCommittedChange(
        deferredExecutionChange,
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

  /// Stops all daemon-owned work before a controlled restart.
  Future<void> requestStopAll({bool preserveInteractiveWaits = false}) async {
    final sessionIds = <String>{
      ..._busySessions,
      ..._suspendedEvents.keys,
      ..._queueCoordinator.sessionIds,
      ..._turnExecutor.activeSessionIds,
    };
    await Future.wait(
      sessionIds.map(
        (sessionId) => requestStop(
          sessionId,
          forceEmitStopped: true,
          preserveInteractiveWait: preserveInteractiveWaits,
        ),
      ),
    );
  }

  /// Preserves a session whose only unfinished work is awaiting user input
  /// (`system_ask_user` or a tool-permission decision) across a managed
  /// daemon shutdown. Startup recovery restores this exact wait instead of
  /// recording an unknown tool outcome, matching power-cut recovery.
  ///
  /// The condition mirrors [SessionRecoveryRestorer]'s interactive-wait
  /// detection: the active work item is `running`/`waiting`,
  /// `currently_executing_tools` is non-empty, and every id is owned by a
  /// suspended checkpoint for this session whose status is not
  /// `executing_tool` (an approved decision may already have started its
  /// side effect and keeps the existing interrupted-tool recovery).
  ///
  /// The live run is deliberately NOT cancelled: the awaiting tool owns the
  /// durable checkpoint and its cancellation path may delete it (the
  /// `system_ask_user` `finally` block). The exiting process abandons the
  /// in-memory wait while durable state stays truthful.
  Future<bool> _tryPreserveInteractiveWait(String sessionId) async {
    final store = _getPersistedState();
    if (store == null) return false;
    final activeItem = store.findActiveWorkItem(sessionId);
    if (activeItem == null ||
        (activeItem.state != SessionWorkState.running &&
            activeItem.state != SessionWorkState.waiting)) {
      return false;
    }
    final executingTools = List<String>.from(
      activeItem.continuationMetadata['currently_executing_tools'] as List? ??
          const [],
    );
    if (executingTools.isEmpty) return false;
    final unresolvedToolCallIds = <String>{};
    for (final checkpoint in await _listRecoverableSuspensions()) {
      if (checkpoint.sessionId == sessionId &&
          checkpoint.status != 'executing_tool') {
        unresolvedToolCallIds.add(checkpoint.toolCallId);
      }
    }
    if (!executingTools.every(unresolvedToolCallIds.contains)) {
      return false;
    }

    _logger.info(
      'Preserving interactive user-input wait for session $sessionId across '
      'daemon stop; startup recovery will restore the pending decision.',
    );
    if (activeItem.state == SessionWorkState.running) {
      store.transitionWorkItemState(
        workItemId: activeItem.workItemId,
        fromState: SessionWorkState.running,
        toState: SessionWorkState.waiting,
      );
    }
    _turnExecutor.removeActiveRun(sessionId);
    _busySessions.remove(sessionId);
    _suspendedEvents.remove(sessionId);
    return true;
  }
}
