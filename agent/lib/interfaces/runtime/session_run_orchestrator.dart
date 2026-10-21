import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/session_queue_provider_override.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
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
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import 'session_queue_coordinator.dart';
import 'session_turn_executor.dart';
import 'session_recovery_restorer.dart';
import 'session_turn_request_helpers.dart';
import 'suspended_checkpoint_store.dart';
import 'session_restart_checkpoint_manager.dart';
import 'session_stop_coordinator.dart';
import 'session_metadata_resolver.dart';

export 'session_restart_checkpoint_manager.dart'
    show ControlledRestartBlocker, ControlledRestartCheckpointResult;
export 'session_stop_coordinator.dart' show SessionStopCoordinator;
export 'session_metadata_resolver.dart' show SessionMetadataResolver;

import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context_compaction_engine.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:uuid/uuid.dart';

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

typedef PersistedSuspendedDecisionResumer = Future<bool> Function({
  required SuspendedCheckpoint checkpoint,
  required Future<void> Function(GatewayResponse response) emitResponse,
});

class SessionRunOrchestrator implements SessionQueueProviderOverride {
  static const controlledRestartCheckpointTimeout = Duration(minutes: 1);
  static const providerRestartCancellationTimeout = Duration(seconds: 5);
  static const runStopCleanupTimeout = Duration(seconds: 5);
  static const controlledRestartCheckpointPollInterval = Duration(
    milliseconds: 25,
  );
  final _logger = Logger('SessionRunOrchestrator');

  final Map<String, SuspendedRun> _suspendedEvents = {};
  final Set<String> _busySessions = {};
  final Map<String, String> _compactingSessionOwners = {};
  Set<String> get _compactingSessions => _compactingSessionOwners.keys.toSet();
  final Set<String> _resumingSessions = {};
  bool get _controlledRestartDraining =>
      _restartManager.controlledRestartDraining;
  final PersistedSuspendedDecisionResumer? _resumePersistedSuspendedDecision;

  final _responseController = StreamController<GatewayResponse>.broadcast();
  Stream<GatewayResponse> get responses => _responseController.stream;

  late final SessionQueueCoordinator _queueCoordinator;
  late final SessionTurnExecutor _turnExecutor;
  late final SessionRestartCheckpointManager _restartManager;
  late final SessionStopCoordinator _stopCoordinator;
  final SessionMetadataResolver _metadataResolver =
      const SessionMetadataResolver();

  /// Optional durable store for suspended runs and queued messages. Wired by
  /// DI when `PersistedRuntimeStateRepository` is registered; null in tests
  /// that do not exercise persistence.
  PersistedRuntimeStateRepository? get persistedState {
    if (getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      return getIt<PersistedRuntimeStateRepository>();
    }
    return null;
  }

  SessionRunOrchestrator({
    PersistedSuspendedDecisionResumer? resumePersistedSuspendedDecision,
  }) : _resumePersistedSuspendedDecision = resumePersistedSuspendedDecision {
    _queueCoordinator = SessionQueueCoordinator(
      getPersistedState: () => persistedState,
      defaultModelForProvider: _defaultModelForProvider,
    );
    _turnExecutor = SessionTurnExecutor(
      emitResponse: _emitResponse,
      getPersistedState: () => persistedState,
    );
    _restartManager = SessionRestartCheckpointManager(
      getPersistedState: () => persistedState,
      turnExecutor: _turnExecutor,
      queueCoordinator: _queueCoordinator,
      listAwaitingSuspensions: _listAwaitingSuspensions,
      isSessionBusy: isSessionBusy,
      drainNextQueuedEvent: _drainNextQueuedEvent,
    );
    _stopCoordinator = SessionStopCoordinator(
      turnExecutor: _turnExecutor,
      queueCoordinator: _queueCoordinator,
      busySessions: _busySessions,
      suspendedEvents: _suspendedEvents,
      getPersistedState: () => persistedState,
      listRecoverableSuspensions: _listRecoverableSuspensions,
      emitResponse: _emitResponse,
      drainNextQueuedEvent: _drainNextQueuedEvent,
      runStopCleanupTimeout: runStopCleanupTimeout,
      logger: _logger,
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

  ActiveRun adoptPersistedSuspendedRun({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    required AgentRunner agentRunner,
  }) {
    _busySessions.add(sessionId);
    return _turnExecutor.adoptPersistedRun(
      sessionId: sessionId,
      workItemId: workItemId,
      runId: runId,
      generation: generation,
      agentRunner: agentRunner,
    );
  }

  bool ownsPersistedSuspendedRun(ActiveRun activeRun) =>
      _turnExecutor.ownsRun(activeRun) &&
      activeRun.cancellationScope.isPublicationOpen;

  void releasePersistedSuspendedRun(ActiveRun activeRun) {
    _turnExecutor.releasePersistedRun(activeRun);
  }

  /// Reconciles the in-memory projection after a restart-restored suspended
  /// decision commits its original durable work item as terminal.
  ///
  /// [SuspendedResumeService] owns reconstructing the lost interactive tool
  /// continuation, but the orchestrator remains the admission and queue-drain
  /// authority. The durable terminal commit must already have removed active
  /// work before this method is called.
  void reconcilePersistedSuspendedTerminal(String sessionId) {
    if (persistedState?.findActiveWorkItem(sessionId) != null) return;
    _suspendedEvents.remove(sessionId);
    _busySessions.remove(sessionId);
    _drainNextQueuedEvent(sessionId);
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

  /// Whether deferred database maintenance must pause before its next batch.
  /// This projection is checked only after durable startup restoration.
  bool get hasMaintenanceBlockingActivity =>
      _controlledRestartDraining ||
      _busySessions.isNotEmpty ||
      _suspendedEvents.isNotEmpty ||
      _compactingSessions.isNotEmpty ||
      _resumingSessions.isNotEmpty ||
      _queueCoordinator.sessionIds.isNotEmpty ||
      _turnExecutor.activeSessionIds.isNotEmpty;

  bool isSessionCompacting(String sessionId) =>
      _compactingSessionOwners.containsKey(sessionId);

  @visibleForTesting
  void debugEnterCompactionBarrier(String sessionId) {
    _compactingSessionOwners[sessionId] = 'barrier';
  }

  @visibleForTesting
  void debugExitCompactionBarrier(String sessionId) {
    _compactingSessionOwners.remove(sessionId);
    _drainNextQueuedEvent(sessionId);
  }

  @visibleForTesting
  void debugMarkSessionBusy(String sessionId) {
    _busySessions.add(sessionId);
  }

  @visibleForTesting
  void debugClearSessionBusy(String sessionId) {
    _busySessions.remove(sessionId);
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
      final activeItem = persistedState?.findActiveWorkItem(sessionId);
      Map<String, dynamic>? claimedContinuationMetadata;
      if (activeItem != null &&
          (recoveryReason == 'manual_retry' ||
              recoveryReason == 'provider_changed') &&
          activeItem.continuationMetadata['checkpoint_kind'] ==
              ContinuationCheckpointCoordinator
                  .checkpointKindModelRequestInFlight &&
          activeItem
                  .continuationMetadata['restart_interrupted_provider_request'] ==
              true) {
        claimedContinuationMetadata =
            ContinuationCheckpointCoordinator.metadataForInterruptedProviderRetry(
              activeItem.continuationMetadata,
            );
        if (claimedContinuationMetadata == null) {
          return ResumeSuspendedResult.unsafeCheckpoint;
        }
      }
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
      if (activeItem != null) {
        if (activeItem.state == SessionWorkState.resuming) {
          return ResumeSuspendedResult.alreadyResuming;
        }
        persistedState?.transitionWorkItemState(
          workItemId: activeItem.workItemId,
          fromState: activeItem.state,
          toState: SessionWorkState.resuming,
          continuationMetadata: claimedContinuationMetadata,
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
    bool preserveInteractiveWait = false,
  }) =>
      _stopCoordinator.requestStop(
        sessionId,
        forceEmitStopped: forceEmitStopped,
        stopRequestId: stopRequestId,
        recoveryOwnerToken: recoveryOwnerToken,
        preserveInteractiveWait: preserveInteractiveWait,
      );

  /// Cancels provider streams that exhausted the controlled-restart timeout
  /// without terminally stopping or replaying their durable work.
  Future<void> interruptProviderRequestsForRestart(
    Iterable<ControlledRestartBlocker> blockers,
  ) => _restartManager.interruptProviderRequestsForRestart(blockers);

  /// Stops all daemon-owned work before a controlled restart.
  Future<void> requestStopAll({bool preserveInteractiveWaits = false}) =>
      _stopCoordinator.requestStopAll(
        preserveInteractiveWaits: preserveInteractiveWaits,
      );

  /// Waits for running tool work to reach a durable restart-safe checkpoint.
  ///
  /// The restart HTTP response may be consumed by `shell_execute` inside the
  /// active turn. Exiting on a fixed acknowledgement delay can kill that tool
  /// before its result and `after_tool_result` checkpoint are persisted,
  /// causing startup to classify the turn as an interrupted non-idempotent
  /// tool. A controlled restart therefore waits until every running/resuming
  /// durable owner is at a recognized checkpoint with no executing tools.
  void beginControlledRestartDrain() =>
      _restartManager.beginControlledRestartDrain();

  void cancelControlledRestartDrain() =>
      _restartManager.cancelControlledRestartDrain();

  Future<ControlledRestartCheckpointResult> waitForControlledRestartCheckpoint({
    Duration timeout =
        SessionRestartCheckpointManager.controlledRestartCheckpointTimeout,
    Duration pollInterval =
        SessionRestartCheckpointManager.controlledRestartCheckpointPollInterval,
    String? requesterSessionId,
    String? requesterToolCallId,
    bool requireRequesterCompletion = false,
  }) => _restartManager.waitForControlledRestartCheckpoint(
    timeout: timeout,
    pollInterval: pollInterval,
    requesterSessionId: requesterSessionId,
    requesterToolCallId: requesterToolCallId,
    requireRequesterCompletion: requireRequesterCompletion,
  );

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

  /// Plan 53d — manual `/compact` admission when the session is idle.
  Future<Map<String, dynamic>> handleCompactCommand({
    required String sessionId,
    required String requestId,
  }) async {
    if (isSessionBusy(sessionId)) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': CompactionFailureReason.sessionBusy.wireValue,
        'failure_reason': CompactionFailureReason.sessionBusy.wireValue,
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.sessionBusy,
      };
    }
    if (isSessionCompacting(sessionId)) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': CompactionFailureReason.compactionInProgress.wireValue,
        'failure_reason': CompactionFailureReason.compactionInProgress.wireValue,
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.compactionInProgress,
      };
    }
    if (getIt.isRegistered<CompactionBoundaryRepository>()) {
      final started = getIt<CompactionBoundaryRepository>()
          .findStartedForSession(sessionId);
      if (started != null) {
        return {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': CompactionFailureReason.compactionInProgress.wireValue,
          'failure_reason': CompactionFailureReason.compactionInProgress.wireValue,
          'failure_stage': CompactionFailureStage.preparation,
          'failure_cause': CompactionFailureCause.compactionInProgress,
        };
      }
    }
    if (!getIt.isRegistered<CompactionCoordinator>() ||
        !getIt.isRegistered<CompactionBoundaryRepository>()) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'unavailable',
        'failure_reason': 'unavailable',
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.unavailable,
      };
    }

    final compactionId = const Uuid().v4();
    final CompactionEngineRequest? engineRequest;
    try {
      final compactionRunner = getIt<AgentRunner>(param1: sessionId);
      final providerSeed =
          await compactionRunner.prepareCompactionProviderSeed();
      engineRequest = await CompactionRequestFactory.forSession(
        sessionId: sessionId,
        trigger: CompactionTrigger.manual,
        compactionId: compactionId,
        providerProjection: providerSeed.projection,
        providerTools: providerSeed.tools,
        providerRequestOptions: providerSeed.options,
      );
    } catch (error) {
      final diagnostics = CompactionDiagnostics.classify(
        error,
        stageHint: CompactionFailureStage.preparation,
      );
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'failed',
        'failure_reason': diagnostics.failureReason.wireValue,
        'failure_stage': diagnostics.stage,
        'failure_cause': diagnostics.cause,
      };
    }
    if (engineRequest == null) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'invalid_request',
        'failure_reason': 'invalid_request',
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.invalidRequest,
      };
    }

    _compactingSessionOwners[sessionId] = compactionId;
    try {
      final outcome = await getIt<CompactionCoordinator>().runCompaction(
        request: engineRequest,
        force: true,
      );
      if (outcome == null) {
        return {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': 'no_op',
        };
      }
      if (outcome.status == CompactionStatus.completed) {
        return {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': 'accepted',
          'compaction_id': outcome.compactionId,
        };
      }
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'failed',
        'failure_reason': outcome.failureReason?.wireValue,
        'compaction_id': outcome.compactionId,
        if (outcome.failureStage != null) 'failure_stage': outcome.failureStage,
        if (outcome.failureCause != null) 'failure_cause': outcome.failureCause,
      };
    } catch (error) {
      final diagnostics = CompactionDiagnostics.classify(error);
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'failed',
        'failure_reason': diagnostics.failureReason.wireValue,
        'compaction_id': compactionId,
        'failure_stage': diagnostics.stage,
        'failure_cause': diagnostics.cause,
      };
    } finally {
      if (_compactingSessionOwners[sessionId] == compactionId) {
        _compactingSessionOwners.remove(sessionId);
        _drainNextQueuedEvent(sessionId);
      }
    }
  }

  Future<void> handleEvent(GatewayEvent event) async {
    _logger.info('Incoming session event');

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

    final sessionManager = getIt<SessionManager>();
    final existingSessionRecord = sessionManager.getSessionRecord(
      event.sessionId,
    );

    if (event.type != 'create_session') {
      final existingSession = existingSessionRecord;
      final requestedWorkspaceId = _resolveWorkspaceId(
        event,
        fallback: existingSession?.workspaceId,
      );
      final turnRequest = _buildTurnRequest(
        event,
        requestedWorkspaceId: requestedWorkspaceId,
      );
      final rawCommandRequestId =
          (event.metadata['payload'] as Map?)?['command_request_id']
              ?.toString()
              .trim();
      final isQueuePromotionCommand =
          rawCommandRequestId != null && rawCommandRequestId.isNotEmpty;
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
      if (!canSteer && isQueuePromotionCommand) {
        final targetRequestId =
            turnRequest.requestId ?? requestIdForEvent(event) ?? '';
        _emitCommandOutcome(
          sessionId: event.sessionId,
          type: 'session.queued_message_steer_result',
          targetRequestId: targetRequestId,
          commandRequestId: rawCommandRequestId,
          outcome: 'stale_owner',
        );
        _emitMessageClassification(
          event,
          requestId: targetRequestId,
          classification: 'queue',
        );
        return;
      }
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
          final commandRequestId = rawCommandRequestId ?? requestId;
          final isQueuePromotion = isQueuePromotionCommand;
          if (isQueuePromotion) {
            final promoted = store!.executionState.promoteQueuedToPendingSteer(
              sessionId: event.sessionId,
              requestId: requestId,
              runId: activeRun.runId,
              generation: activeRun.generation,
              text: text,
              receivedAt: receivedAt,
            );
            if (promoted.outcome != QueueMutationOutcome.promoted) {
              _emitCommandOutcome(
                sessionId: event.sessionId,
                type: 'session.queued_message_steer_result',
                targetRequestId: requestId,
                commandRequestId: commandRequestId,
                outcome: _wireName(promoted.outcome.name),
              );
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
              onCommitDelivery: (history, placements) =>
                  _turnExecutor.commitPendingSteerDelivery(
                    owner: activeRun,
                    history: history,
                    placements: placements,
                  ),
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
          if (isQueuePromotion) {
            _emitCommandOutcome(
              sessionId: event.sessionId,
              type: 'session.queued_message_steer_result',
              targetRequestId: requestId,
              commandRequestId: commandRequestId,
              outcome: 'promoted',
            );
          }
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
          isSessionCompacting(event.sessionId) ||
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
          final currentSession = sessionManager.getSessionRecord(
            event.sessionId,
          );
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

    final existingSession = existingSessionRecord;
    var titleOwnerSession = existingSession;
    final isNewSession = existingSession == null;
    final requestedWorkspaceId = _resolveWorkspaceId(
      event,
      fallback: existingSession?.workspaceId,
    );
    var turnRequest = _buildTurnRequest(
      event,
      requestedWorkspaceId: requestedWorkspaceId,
    );
    final payloadModel = turnRequest.model;
    var thinkingRouteRevalidated = false;

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
      final priorModel = existingSession.model;
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

      if (provider != null &&
          provider.isNotEmpty &&
          getIt.isRegistered<ThinkingRouteSessionSync>() &&
          (priorModel != payloadModel ||
              provider != existingSession.providerId)) {
        thinkingRouteRevalidated = true;
        final corrected = getIt<ThinkingRouteSessionSync>()
            .revalidateAndApplySession(
              sessionId: event.sessionId,
              providerInstanceId: provider,
              modelId: payloadModel,
              selectionId:
                  turnRequest.thinkingMode ?? existingSession.thinkingMode,
            );
        turnRequest = turnRequest.copyWith(
          thinkingMode: corrected.selectionId,
        );
      }
    }

    // A turn that echoes the already-persisted session preference carries an
    // inherited selection; the target route must not reject it (Task 115).
    if (existingSession != null &&
        !thinkingRouteRevalidated &&
        getIt.isRegistered<ThinkingRouteSessionSync>()) {
      turnRequest = getIt<ThinkingRouteSessionSync>()
          .revalidateCarriedTurnSelection(
            turnRequest,
            persistedSelection: existingSession.thinkingMode,
            sessionProviderInstanceId: existingSession.providerId,
            sessionModelId: existingSession.model,
          );
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
          historyRevision: existingSession.historyRevision,
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
    if (liveWorkItem?.state == SessionWorkState.queued) {
      sessionManager.recordCanonicalUserMessageAccepted(
        event.sessionId,
        receivedAt,
      );
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
    if (isSessionBusy(sessionId) || isSessionCompacting(sessionId)) {
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
  ) =>
      _metadataResolver.resolveInitialSessionTitle(event);

  String? _resolveWorkspaceId(GatewayEvent event, {String? fallback}) =>
      _metadataResolver.resolveWorkspaceId(event, fallback: fallback);

  Future<Map<String, dynamic>> _buildWorkspaceSessionMetadata(
    String? workspaceId,
  ) =>
      _metadataResolver.buildWorkspaceSessionMetadata(workspaceId);

  String? _workspaceIdFromMetadata(
    Map<String, dynamic> metadata, {
    String? fallback,
  }) =>
      _metadataResolver.workspaceIdFromMetadata(metadata, fallback: fallback);

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
      listAwaitingSuspensions: _resumePersistedSuspendedDecision == null
          ? _listAwaitingSuspensions
          : _listRecoverableSuspensions,
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
    final decisionResumer = _resumePersistedSuspendedDecision;
    if (decisionResumer != null) {
      final checkpoints = await _listRecoverableSuspensions();
      for (final checkpoint in checkpoints.where(
        (candidate) =>
            candidate.status == 'decision_ready' &&
            candidate.resolvedDecision != null,
      )) {
        final active = persistedState?.findActiveWorkItem(checkpoint.sessionId);
        final executingTools = List<String>.from(
          active?.continuationMetadata['currently_executing_tools'] as List? ??
              const [],
        );
        if (active?.state != SessionWorkState.waiting ||
            !executingTools.contains(checkpoint.toolCallId)) {
          continue;
        }
        Future.microtask(() async {
          try {
            await decisionResumer(
              checkpoint: checkpoint,
              emitResponse: (response) async => _emitResponse(response),
            );
          } catch (error, stackTrace) {
            _logger.severe(
              'Failed to reclaim a persisted suspended decision.',
              error,
              stackTrace,
            );
          }
        });
      }
    }
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
      listAwaitingSuspensions: _resumePersistedSuspendedDecision == null
          ? _listAwaitingSuspensions
          : _listRecoverableSuspensions,
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

  Future<List<SuspendedCheckpoint>> _listRecoverableSuspensions() {
    if (!getIt.isRegistered<SuspendedCheckpointStore>()) {
      return Future.value(const <SuspendedCheckpoint>[]);
    }
    return getIt<SuspendedCheckpointStore>().listRecoverable();
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
        message: 'The daemon could not claim the restored request. Retry, change provider, or stop the session.',
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



enum ResumeSuspendedResult {
  claimed,
  alreadyResuming,
  missing,
  restartDraining,
  unsafeCheckpoint,
}
