import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';

import 'session_queue_coordinator.dart';
import 'session_turn_executor.dart';

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

/// Manages controlled daemon restart draining, safe checkpoint polling,
/// and interrupted provider request cancellation across sessions.
class SessionRestartCheckpointManager {
  static const controlledRestartCheckpointTimeout = Duration(minutes: 1);
  static const providerRestartCancellationTimeout = Duration(seconds: 5);
  static const controlledRestartCheckpointPollInterval = Duration(
    milliseconds: 25,
  );

  final Logger _logger = Logger('SessionRestartCheckpointManager');

  final PersistedRuntimeStateRepository? Function() getPersistedState;
  final SessionTurnExecutor turnExecutor;
  final SessionQueueCoordinator queueCoordinator;
  final Future<List<SuspendedCheckpoint>> Function() listAwaitingSuspensions;
  final bool Function(String sessionId) isSessionBusy;
  final void Function(String sessionId) drainNextQueuedEvent;

  bool _controlledRestartDraining = false;
  bool get controlledRestartDraining => _controlledRestartDraining;

  SessionRestartCheckpointManager({
    required this.getPersistedState,
    required this.turnExecutor,
    required this.queueCoordinator,
    required this.listAwaitingSuspensions,
    required this.isSessionBusy,
    required this.drainNextQueuedEvent,
  });

  void beginControlledRestartDrain() {
    _controlledRestartDraining = true;
    for (final activeRun in turnExecutor.activeRuns.values) {
      activeRun.agentRunner.beginControlledRestartDrain();
    }
  }

  void cancelControlledRestartDrain() {
    if (!_controlledRestartDraining) return;
    _controlledRestartDraining = false;
    for (final activeRun in turnExecutor.activeRuns.values) {
      activeRun.agentRunner.cancelControlledRestartDrain();
    }
    for (final sessionId in queueCoordinator.sessionIds.toList()) {
      if (!isSessionBusy(sessionId)) {
        drainNextQueuedEvent(sessionId);
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
    final store = getPersistedState();
    if (store == null) return ControlledRestartCheckpointResult.safe;
    final elapsed = Stopwatch()..start();
    while (true) {
      final awaitingInteractiveTools = <String, Set<String>>{};
      for (final checkpoint in await listAwaitingSuspensions()) {
        awaitingInteractiveTools
            .putIfAbsent(checkpoint.sessionId, () => <String>{})
            .add(checkpoint.toolCallId);
      }
      final blockers = <ControlledRestartBlocker>[];
      for (final sessionId in store.findAllSessionIdsWithWorkItems()) {
        final item = store.findActiveWorkItem(sessionId);
        if (item == null ||
            (item.state != SessionWorkState.running &&
                item.state != SessionWorkState.resuming)) {
          continue;
        }
        final metadata = item.continuationMetadata;
        final activeRun = turnExecutor.getActiveRun(sessionId);
        final providerRequestInFlight =
            activeRun != null &&
            turnExecutor.ownsRun(activeRun) &&
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
        final awaitingForSession =
            awaitingInteractiveTools[sessionId] ?? const <String>{};
        final isDurableInteractiveWait =
            (item.state == SessionWorkState.running ||
                item.state == SessionWorkState.waiting) &&
            !providerRequestInFlight &&
            executingTools.isNotEmpty &&
            executingTools.every(awaitingForSession.contains);
        if (isDurableInteractiveWait) {
          continue;
        }
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

  Future<void> interruptProviderRequestsForRestart(
    Iterable<ControlledRestartBlocker> blockers,
  ) async {
    final providerBlockers = blockers.where(
      (blocker) => blocker.providerRequestInFlight,
    );
    await Future.wait(
      providerBlockers.map((blocker) async {
        final activeRun = turnExecutor.getActiveRun(blocker.sessionId);
        if (activeRun == null ||
            !turnExecutor.ownsRun(activeRun) ||
            activeRun.workItemId != blocker.workItemId ||
            activeRun.runId != blocker.runId ||
            activeRun.generation != blocker.generation ||
            !activeRun.agentRunner.providerRequestInFlight) {
          return;
        }

        final store = getPersistedState();
        final item = blocker.workItemId == null
            ? null
            : store?.findWorkItem(blocker.workItemId!);
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
        store?.transitionWorkItemState(
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
}
