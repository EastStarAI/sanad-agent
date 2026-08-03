import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'session_run_orchestrator.dart';
import 'session_queue_coordinator.dart';

class SessionRecoveryRestorer {
  static final Logger _logger = Logger('SessionRecoveryRestorer');

  final PersistedRuntimeStateRepository? Function() _getPersistedState;
  final SessionQueueCoordinator _queueCoordinator;
  final Map<String, SuspendedRun> _suspendedEvents;
  final Set<String> _busySessions;
  final Future<List<SuspendedCheckpoint>> Function() _listAwaitingSuspensions;
  final Future<void> Function({
    required GatewayEvent event,
    required AgentTurnRequest turnRequest,
    required AgentRunner agentRunner,
    required bool isResume,
  })
  _runTurnCallback;
  final Future<void> Function(String sessionId) _resumeSuspendedCallback;

  SessionRecoveryRestorer({
    required PersistedRuntimeStateRepository? Function() getPersistedState,
    required SessionQueueCoordinator queueCoordinator,
    required Map<String, SuspendedRun> suspendedEvents,
    required Set<String> busySessions,
    required Future<List<SuspendedCheckpoint>> Function()
    listAwaitingSuspensions,
    required Future<void> Function({
      required GatewayEvent event,
      required AgentTurnRequest turnRequest,
      required AgentRunner agentRunner,
      required bool isResume,
    })
    runTurnCallback,
    required Future<void> Function(String sessionId) resumeSuspendedCallback,
  }) : _getPersistedState = getPersistedState,
       _queueCoordinator = queueCoordinator,
       _suspendedEvents = suspendedEvents,
       _busySessions = busySessions,
       _listAwaitingSuspensions = listAwaitingSuspensions,
       _runTurnCallback = runTurnCallback,
       _resumeSuspendedCallback = resumeSuspendedCallback;

  Future<void> restorePersistedState() async {
    final store = _getPersistedState();
    if (store == null) return;
    store.cleanupOrphanedWorkItems();
    _deleteOrphanedRuntimeNotices(store);

    final awaitingSuspensions = await _listAwaitingSuspensions();
    final suspendedToolCallIdsBySession = <String, Set<String>>{};
    for (final checkpoint in awaitingSuspensions) {
      suspendedToolCallIdsBySession
          .putIfAbsent(checkpoint.sessionId, () => <String>{})
          .add(checkpoint.toolCallId);
    }

    // Restore active notices in recovery service first (E.1)
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().restoreActiveNotices();
    }

    final sessionIds = store.findSessionIdsWithRestorableWorkItems();
    int restoredSuspendedCount = 0;
    int restoredQueuedCount = 0;

    for (final sessionId in sessionIds) {
      final allItems = store.findRestorableWorkItems(sessionId);
      if (allItems.isEmpty) continue;
      final resumableWorkItemIds = <String>{};
      final autoResumeWorkItemIds = <String>{};

      final hasActiveWaitingNotice =
          getIt.isRegistered<RuntimeRecoveryService>() &&
          getIt<RuntimeRecoveryService>().hasActiveNotice(sessionId);
      final hasActiveBlockedNotice = hasActiveWaitingNotice
          ? getIt<RuntimeRecoveryService>().activeNotice(sessionId)?.status ==
                RuntimeNoticeStatus.blocked
          : false;

      // 1. Check if there was a running (crashed) work item (E.2.3)
      final runningItems = allItems
          .where((item) => item.state == SessionWorkState.running)
          .toList();
      for (final running in runningItems) {
        final meta = running.continuationMetadata;
        final executingTools = List<String>.from(
          meta['currently_executing_tools'] as List? ?? const [],
        );
        final checkpointKind = meta['checkpoint_kind']?.toString();
        final hasRecognizedCheckpoint =
            checkpointKind == AgentRunner.checkpointKindInitialModelRequest ||
            checkpointKind == AgentRunner.checkpointKindAfterToolResult;
        final suspendedToolCallIds =
            suspendedToolCallIdsBySession[sessionId] ?? const <String>{};
        final isInteractiveWait =
            executingTools.isNotEmpty &&
            executingTools.every(suspendedToolCallIds.contains);

        if (isInteractiveWait) {
          _logger.info(
            'Restoring work item ${running.workItemId} as waiting because '
            'every executing tool is owned by an unresolved user-input '
            'checkpoint.',
          );
          store.transitionWorkItemState(
            workItemId: running.workItemId,
            fromState: SessionWorkState.running,
            toState: SessionWorkState.waiting,
          );
          continue;
        }

        if (hasActiveWaitingNotice && executingTools.isEmpty) {
          final waitingState = hasActiveBlockedNotice
              ? SessionWorkState.blocked
              : SessionWorkState.waiting;
          _logger.info(
            '🔁 [Orchestrator] Promoting running work item '
            '${running.workItemId} to $waitingState because a matching '
            'recovery notice was restored for session $sessionId',
          );
          try {
            store.transitionWorkItemState(
              workItemId: running.workItemId,
              fromState: SessionWorkState.running,
              toState: waitingState,
            );
          } catch (e) {
            _logger.warning(
              'Failed to promote running work item ${running.workItemId} '
              'to $waitingState: $e',
            );
          }
          continue;
        }

        bool canRequeue = true;
        if (executingTools.isNotEmpty) {
          final toolReplaySafety = Map<String, dynamic>.from(
            meta['tool_replay_safety'] as Map? ?? const {},
          );
          final deferredResults = Map<String, dynamic>.from(
            meta['deferred_tool_results'] as Map? ?? const {},
          );
          // If any executing tool is non-idempotent, we cannot re-queue
          for (final toolId in executingTools) {
            final deferred = DeferredToolResultDescriptor.tryParseMetadata(
              deferredResults[toolId],
            );
            if (deferred != null &&
                deferred.requesterSessionId == sessionId &&
                deferred.requesterToolCallId == toolId) {
              continue;
            }
            if (toolReplaySafety[toolId] != true) {
              canRequeue = false;
              break;
            }
          }
        }

        if (canRequeue) {
          if (hasRecognizedCheckpoint) {
            resumableWorkItemIds.add(running.workItemId);
          }
          _logger.info(
            hasRecognizedCheckpoint
                ? '🔄 [Orchestrator] Queueing checkpointed work item ${running.workItemId} for resume'
                : '🔄 [Orchestrator] Re-queuing crashed idempotent work item ${running.workItemId}',
          );
          store.transitionWorkItemState(
            workItemId: running.workItemId,
            fromState: SessionWorkState.running,
            toState: SessionWorkState.queued,
          );
        } else {
          _logger.warning(
            '⚠️ [Orchestrator] Crashed work item ${running.workItemId} has non-idempotent executing tools. Marking as blocked.',
          );
          store.transitionWorkItemState(
            workItemId: running.workItemId,
            fromState: SessionWorkState.running,
            toState: SessionWorkState.blocked,
          );

          if (getIt.isRegistered<RuntimeRecoveryService>()) {
            getIt<RuntimeRecoveryService>().reportFailure(
              sessionId: sessionId,
              reason: RuntimeFailureReason.unknown,
              requestId: running.requestId,
              providerInstanceId: running.providerInstanceId,
              title: 'Execution interrupted',
              message:
                  'The agent crashed or restarted while executing a non-idempotent tool. Execution has been blocked to prevent duplicate actions. Please review session history and select retry or stop.',
              forceBlocked: true,
            );
          }
        }
      }

      // Re-fetch all items for the session after crash recovery.
      var updatedItems = store.findRestorableWorkItems(sessionId);

      // Repair state written by older startup logic that incorrectly blocked
      // an interactive wait as an interrupted non-idempotent tool. Both hops
      // stay inside the existing transition graph while returning the durable
      // owner to its truthful waiting state.
      for (final item in updatedItems.where(
        (candidate) => candidate.state == SessionWorkState.blocked,
      )) {
        final executingTools = List<String>.from(
          item.continuationMetadata['currently_executing_tools'] as List? ??
              const [],
        );
        final suspendedToolCallIds =
            suspendedToolCallIdsBySession[sessionId] ?? const <String>{};
        final isInteractiveWait =
            executingTools.isNotEmpty &&
            executingTools.every(suspendedToolCallIds.contains);
        if (!isInteractiveWait) continue;
        _logger.info(
          'Repairing falsely blocked interactive work item '
          '${item.workItemId} to waiting.',
        );
        store.transitionWorkItemState(
          workItemId: item.workItemId,
          fromState: SessionWorkState.blocked,
          toState: SessionWorkState.resuming,
        );
        store.transitionWorkItemState(
          workItemId: item.workItemId,
          fromState: SessionWorkState.resuming,
          toState: SessionWorkState.waiting,
        );
        store.deleteNotice(sessionId);
      }
      updatedItems = store.findRestorableWorkItems(sessionId);

      for (final item in updatedItems.where(
        (candidate) => candidate.state == SessionWorkState.resuming,
      )) {
        if (_isSafeInterruptedResume(item)) {
          _logger.info(
            '🔁 [Orchestrator] Reclassifying safely owned interrupted '
            'resuming work item ${item.workItemId} to waiting for an atomic '
            'resume claim',
          );
          store.transitionWorkItemState(
            workItemId: item.workItemId,
            fromState: SessionWorkState.resuming,
            toState: SessionWorkState.waiting,
          );
          autoResumeWorkItemIds.add(item.workItemId);
          if (getIt.isRegistered<RuntimeRecoveryService>()) {
            final recovery = getIt<RuntimeRecoveryService>();
            final staleNotice = recovery.activeNotice(sessionId);
            if (staleNotice?.status == RuntimeNoticeStatus.resuming) {
              recovery.clear(
                sessionId,
                runId: staleNotice?.runId,
                reasonOverride: 'daemon_restart_reclaim',
              );
            }
          }
        } else {
          _logger.warning(
            '⚠️ [Orchestrator] Interrupted resuming work item '
            '${item.workItemId} has no safe replay checkpoint. Marking it '
            'blocked to prevent duplicate side effects.',
          );
          store.transitionWorkItemState(
            workItemId: item.workItemId,
            fromState: SessionWorkState.resuming,
            toState: SessionWorkState.blocked,
          );
          _persistBlockedNoticeIfMissing(
            store,
            sessionId: sessionId,
            requestId: item.requestId,
            providerInstanceId: item.providerInstanceId,
          );
        }
      }

      final normalizedItems = store.findRestorableWorkItems(sessionId);
      store.executionState.normalizeAfterRestart(sessionId);

      // 2. Restore active/blocked run into _suspendedEvents (E.2.2)
      SessionWorkItem? activeWorkItem;
      for (final item in normalizedItems) {
        if (item.state == SessionWorkState.waiting ||
            item.state == SessionWorkState.blocked ||
            item.state == SessionWorkState.resuming) {
          activeWorkItem = item;
          break;
        }
      }

      var persistedNotice = store.findNotice(sessionId);
      if (activeWorkItem != null &&
          activeWorkItem.state == SessionWorkState.waiting &&
          !autoResumeWorkItemIds.contains(activeWorkItem.workItemId) &&
          !_hasProvableWaitingOwner(
            activeWorkItem,
            persistedNotice,
            suspendedToolCallIdsBySession[sessionId] ?? const <String>{},
          )) {
        _logger.warning(
          'Legacy waiting work ${activeWorkItem.workItemId} has no provable '
          'resume owner; converting it to blocked recovery.',
        );
        store.transitionWorkItemState(
          workItemId: activeWorkItem.workItemId,
          fromState: SessionWorkState.waiting,
          toState: SessionWorkState.blocked,
        );
        if (getIt.isRegistered<RuntimeRecoveryService>()) {
          getIt<RuntimeRecoveryService>().clear(
            sessionId,
            runId: persistedNotice?.runId,
          );
        } else {
          store.deleteNotice(sessionId);
        }
        _persistBlockedNoticeIfMissing(
          store,
          sessionId: sessionId,
          requestId: activeWorkItem.requestId,
          providerInstanceId: activeWorkItem.providerInstanceId,
        );
        persistedNotice = store.findNotice(sessionId);
        activeWorkItem = store.findActiveWorkItem(sessionId);
      }
      if (activeWorkItem != null &&
          activeWorkItem.state == SessionWorkState.blocked &&
          persistedNotice == null) {
        _persistBlockedNoticeIfMissing(
          store,
          sessionId: sessionId,
          requestId: activeWorkItem.requestId,
          providerInstanceId: activeWorkItem.providerInstanceId,
        );
      }

      if (activeWorkItem != null) {
        final payload = activeWorkItem.payload;
        final reconstructed = _reconstructGatewayEvent(
          sessionId: sessionId,
          message: payload['message'] as String? ?? '',
          metadata: Map<String, dynamic>.from(
            payload['eventMetadata'] as Map? ?? const {},
          ),
          requestId: activeWorkItem.requestId,
          runId: payload['runId'] as String?,
          workspaceId: activeWorkItem.workspaceId,
          providerInstanceId: activeWorkItem.providerInstanceId,
          model: activeWorkItem.modelId,
          thinkingMode: payload['thinkingMode'] as String?,
        );
        final request = _reconstructTurnRequest(
          sessionId: sessionId,
          message: payload['message'] as String? ?? '',
          workspaceId: activeWorkItem.workspaceId,
          providerInstanceId: activeWorkItem.providerInstanceId,
          model: activeWorkItem.modelId,
          thinkingMode: payload['thinkingMode'] as String?,
          requestId: activeWorkItem.requestId,
          metadata: Map<String, dynamic>.from(
            payload['eventMetadata'] as Map? ?? const {},
          ),
        );
        _suspendedEvents[sessionId] = SuspendedRun(
          event: reconstructed,
          request: request,
          agentRunner: getIt<AgentRunner>(param1: sessionId),
          workItemId: activeWorkItem.workItemId,
        );
        restoredSuspendedCount++;
      }

      // 3. Restore queued items into _pendingEvents in FIFO order (E.2.1)
      final queuedItems = normalizedItems
          .where((item) => item.state == SessionWorkState.queued)
          .toList();
      queuedItems.sort((a, b) => a.sequence.compareTo(b.sequence));

      final queue = <QueuedRun>[];
      for (final item in queuedItems) {
        final payload = item.payload;
        final reconstructed = _reconstructGatewayEvent(
          sessionId: sessionId,
          message: payload['message'] as String? ?? '',
          metadata: Map<String, dynamic>.from(
            payload['eventMetadata'] as Map? ?? const {},
          ),
          requestId: item.requestId,
          runId: payload['runId'] as String?,
          workspaceId: item.workspaceId,
          providerInstanceId: item.providerInstanceId,
          model: item.modelId,
          thinkingMode: payload['thinkingMode'] as String?,
        );
        final request = _reconstructTurnRequest(
          sessionId: sessionId,
          message: payload['message'] as String? ?? '',
          workspaceId: item.workspaceId,
          providerInstanceId: item.providerInstanceId,
          model: item.modelId,
          thinkingMode: payload['thinkingMode'] as String?,
          requestId: item.requestId,
          metadata: Map<String, dynamic>.from(
            payload['eventMetadata'] as Map? ?? const {},
          ),
        );
        queue.add(
          QueuedRun(
            event: reconstructed,
            request: request,
            isResume: resumableWorkItemIds.contains(item.workItemId),
            workItemId: item.workItemId,
          ),
        );
        restoredQueuedCount++;
      }
      _queueCoordinator.restoreQueue(sessionId, queue);

      // 4. Queue-only bootstrap: restart must not leave the oldest queued item
      // stranded until a newer user message arrives.
      final hasActiveRecoveryNotice =
          getIt.isRegistered<RuntimeRecoveryService>() &&
          getIt<RuntimeRecoveryService>().hasActiveNotice(sessionId);
      if (activeWorkItem == null &&
          !hasActiveRecoveryNotice &&
          queue.isNotEmpty) {
        final nextRun = _queueCoordinator.claimNext(sessionId);
        if (nextRun != null) {
          _busySessions.add(sessionId);
          Future.microtask(
            () => _runTurnCallback(
              event: nextRun.event,
              turnRequest: nextRun.request,
              agentRunner: getIt<AgentRunner>(param1: sessionId),
              isResume: nextRun.isResume,
            ),
          );
        } else {
          _logger.warning(
            'Queue bootstrap could not claim the oldest queued work item for session $sessionId.',
          );
        }
      }

      if (activeWorkItem != null &&
          activeWorkItem.state == SessionWorkState.waiting &&
          autoResumeWorkItemIds.contains(activeWorkItem.workItemId) &&
          !hasActiveRecoveryNotice &&
          getIt.isRegistered<RuntimeRecoveryService>()) {
        _scheduleAtomicResume(sessionId);
      }
    }

    if (restoredSuspendedCount > 0 || restoredQueuedCount > 0) {
      _logger.info(
        'Restored $restoredSuspendedCount suspended run(s) and '
        '$restoredQueuedCount queued message(s) from session_work_items table',
      );
    }
  }

  bool _hasProvableWaitingOwner(
    SessionWorkItem workItem,
    PersistedRuntimeNotice? notice,
    Set<String> suspendedToolCallIds,
  ) {
    final executingTools = List<String>.from(
      workItem.continuationMetadata['currently_executing_tools'] as List? ??
          const [],
    );
    if (executingTools.isNotEmpty &&
        executingTools.every(suspendedToolCallIds.contains)) {
      return true;
    }
    if (notice == null || notice.status != 'waiting') return false;
    final resumeAt = notice.resumeAt == null
        ? null
        : DateTime.tryParse(notice.resumeAt!);
    if (resumeAt == null) return false;
    final ownerRunId = workItem.continuationMetadata['owner_run_id']
        ?.toString();
    if (ownerRunId == null ||
        ownerRunId.isEmpty ||
        notice.runId != ownerRunId) {
      return false;
    }
    if (workItem.requestId != null && notice.requestId != workItem.requestId) {
      return false;
    }
    return true;
  }

  void _deleteOrphanedRuntimeNotices(PersistedRuntimeStateRepository store) {
    var removed = 0;
    for (final sessionId in store.findAllNotices().keys) {
      if (store.findActiveWorkItem(sessionId) != null) continue;
      store.deleteNotice(sessionId);
      removed++;
    }
    if (removed > 0) {
      _logger.info(
        'Removed $removed orphaned runtime notice(s) without active work.',
      );
    }
  }

  void markRestoreFailureAsBlocked({Object? error}) {
    final store = _getPersistedState();
    if (store == null || !getIt.isRegistered<RuntimeRecoveryService>()) {
      return;
    }
    final recovery = getIt<RuntimeRecoveryService>();
    final sessionIds = store.findSessionIdsWithRestorableWorkItems();
    for (final sessionId in sessionIds) {
      final items = store.findRestorableWorkItems(sessionId);
      if (items.isEmpty) continue;
      SessionWorkItem? activeItem;
      for (final item in items) {
        if (item.state == SessionWorkState.running ||
            item.state == SessionWorkState.resuming ||
            item.state == SessionWorkState.waiting ||
            item.state == SessionWorkState.blocked) {
          activeItem = item;
          break;
        }
      }
      if (activeItem == null) {
        continue;
      }
      if (activeItem.state != SessionWorkState.blocked) {
        store.transitionWorkItemState(
          workItemId: activeItem.workItemId,
          fromState: activeItem.state,
          toState: SessionWorkState.blocked,
        );
      }
      recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.unknown,
        requestId: activeItem.requestId,
        providerInstanceId: activeItem.providerInstanceId,
        title: 'Runtime recovery failed on startup',
        message:
            'The daemon could not safely restore persisted work during startup. '
            'The session was blocked so you can retry, change provider, or stop.',
        forceBlocked: true,
      );
      _logger.warning(
        'Marked session $sessionId as blocked after startup restore failure: $error',
      );
    }
  }

  GatewayEvent _reconstructGatewayEvent({
    required String sessionId,
    required String message,
    required Map<String, dynamic> metadata,
    String? requestId,
    String? runId,
    String? workspaceId,
    String? providerInstanceId,
    String? model,
    String? thinkingMode,
    String eventType = 'message',
  }) {
    return GatewayEvent(
      sessionId: sessionId,
      platformId: '',
      type: eventType,
      message: Message(role: MessageRole.user, content: message),
      runId: runId,
      metadata: {
        ...metadata,
        'payload': {
          'provider_instance_id': providerInstanceId,
          'model': model,
          'thinking_mode': thinkingMode,
          'request_id': requestId,
          'workspace_id': workspaceId,
        },
      },
    );
  }

  AgentTurnRequest _reconstructTurnRequest({
    required String sessionId,
    required String message,
    String? workspaceId,
    String? providerInstanceId,
    String? model,
    String? thinkingMode,
    String? requestId,
    Map<String, dynamic>? metadata,
  }) {
    return AgentTurnRequest(
      sessionId: sessionId,
      message: message,
      workspaceId: workspaceId,
      providerInstanceId: providerInstanceId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: requestId,
      metadata: metadata ?? const {},
    );
  }

  bool _isSafeInterruptedResume(SessionWorkItem item) {
    final metadata = item.continuationMetadata;
    final ownerRunId = metadata['owner_run_id']?.toString();
    final ownerGeneration = metadata['owner_generation'];
    if (ownerRunId == null ||
        ownerRunId.isEmpty ||
        (ownerGeneration is! int && int.tryParse('$ownerGeneration') == null)) {
      return false;
    }

    final checkpointKind = metadata['checkpoint_kind']?.toString();
    final hasRecognizedCheckpoint =
        checkpointKind == AgentRunner.checkpointKindInitialModelRequest ||
        checkpointKind == AgentRunner.checkpointKindAfterToolResult;
    if (!hasRecognizedCheckpoint) {
      return false;
    }

    final executingTools = List<String>.from(
      metadata['currently_executing_tools'] as List? ?? const [],
    );
    if (executingTools.isEmpty) {
      return true;
    }
    final replaySafety = Map<String, dynamic>.from(
      metadata['tool_replay_safety'] as Map? ?? const {},
    );
    return executingTools.every((toolId) => replaySafety[toolId] == true);
  }

  void _scheduleAtomicResume(String sessionId) {
    Future.microtask(() async {
      try {
        await _resumeSuspendedCallback(sessionId);
      } catch (error, stackTrace) {
        _logger.severe(
          'Failed to auto-resume restored session $sessionId',
          error,
          stackTrace,
        );
      }
    });
  }

  void _persistBlockedNoticeIfMissing(
    PersistedRuntimeStateRepository store, {
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
  }) {
    if (store.findNotice(sessionId)?.status ==
        RuntimeNoticeStatus.blocked.name) {
      return;
    }
    store.upsertNotice(
      sessionId: sessionId,
      requestId: requestId,
      status: RuntimeNoticeStatus.blocked.name,
      reason: RuntimeFailureReason.unknown.name,
      title: 'Session recovery needs your input',
      message:
          'The daemon restored blocked work for this session. Review it and choose retry, change provider, or stop.',
      providerInstanceId: providerInstanceId,
      actions: const ['stop', 'retry', 'changeProvider'],
    );
  }
}
