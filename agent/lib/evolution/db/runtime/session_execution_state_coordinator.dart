import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../core/models/message.dart';
import '../../models/session_execution_snapshot.dart';
import '../../models/pending_steer_record.dart';
import '../../models/stop_recovery_outcome.dart';
import '../session_history_revision_repository.dart';
import '../agent_state_database.dart';
import '../persisted_runtime_state_repository.dart';
import 'pending_input_repository.dart';
import 'session_execution_snapshot_repository.dart';
import 'session_work_item_repository.dart';

/// Atomic owner of the durable session execution aggregate.
///
/// Every work-state mutation and the corresponding aggregate recomputation
/// commit on the same [AgentStateDatabase] transaction. Protocol delivery is
/// intentionally outside this owner and happens only after a returned change
/// has committed.
class SessionExecutionStateCoordinator {
  final AgentStateDatabase _state;
  final SessionWorkItemRepository _workItems;
  final SessionExecutionSnapshotRepository _snapshots;
  final PendingInputRepository? _pendingInputs;
  final StreamController<SessionExecutionSnapshot> _changes =
      StreamController<SessionExecutionSnapshot>.broadcast(sync: true);

  Stream<SessionExecutionSnapshot> get changes => _changes.stream;

  SessionExecutionStateCoordinator({
    required AgentStateDatabase state,
    required SessionWorkItemRepository workItems,
    required SessionExecutionSnapshotRepository snapshots,
    PendingInputRepository? pendingInputs,
  }) : _state = state,
       _workItems = workItems,
       _snapshots = snapshots,
       _pendingInputs = pendingInputs;

  QueueMutationResult promoteQueuedToPendingSteer({
    required String sessionId,
    required String requestId,
    required String runId,
    required int generation,
    required String text,
    required DateTime receivedAt,
  }) {
    final pendingInputs = _pendingInputs;
    if (pendingInputs == null) {
      return const QueueMutationResult(QueueMutationOutcome.notFound);
    }
    final result = _state.transaction((tx) {
      final target = _workItems.findByRequestId(
        sessionId,
        requestId,
        transaction: tx,
      );
      if (target == null) {
        return const QueueMutationResult(QueueMutationOutcome.notFound);
      }
      if (target.state == SessionWorkState.cancelled) {
        final existing = pendingInputs.find(
          sessionId,
          requestId,
          transaction: tx,
        );
        return QueueMutationResult(
          existing == null
              ? QueueMutationOutcome.alreadyRemoved
              : QueueMutationOutcome.promoted,
          pendingSteer: existing,
        );
      }
      if (target.state != SessionWorkState.queued) {
        return const QueueMutationResult(QueueMutationOutcome.alreadyProcessed);
      }
      final active = _workItems.findActiveWorkItem(sessionId);
      if (active == null ||
          active.continuationMetadata['owner_run_id'] != runId ||
          active.continuationMetadata['owner_generation'] != generation) {
        return const QueueMutationResult(QueueMutationOutcome.staleOwner);
      }
      if (!_workItems.cancelQueuedWorkItem(
        sessionId,
        requestId,
        transaction: tx,
      )) {
        return const QueueMutationResult(QueueMutationOutcome.alreadyProcessed);
      }
      final pending = pendingInputs.insertPending(
        sessionId: sessionId,
        requestId: requestId,
        runId: runId,
        generation: generation,
        text: text,
        receivedAt: receivedAt,
        transaction: tx,
      );
      final execution = _recomputeInTransaction(sessionId, tx);
      return QueueMutationResult(
        QueueMutationOutcome.promoted,
        pendingSteer: pending,
        execution: execution,
      );
    });
    final execution = result.execution;
    if (execution != null) _publish(execution);
    return result;
  }

  QueueMutationResult deleteQueuedMessage({
    required String sessionId,
    required String requestId,
  }) {
    final result = _state.transaction((tx) {
      final target = _workItems.findByRequestId(
        sessionId,
        requestId,
        transaction: tx,
      );
      if (target == null) {
        return const QueueMutationResult(QueueMutationOutcome.notFound);
      }
      if (target.state == SessionWorkState.cancelled) {
        return const QueueMutationResult(QueueMutationOutcome.alreadyRemoved);
      }
      if (target.state != SessionWorkState.queued) {
        return const QueueMutationResult(QueueMutationOutcome.alreadyProcessed);
      }
      _workItems.cancelQueuedWorkItem(sessionId, requestId, transaction: tx);
      final execution = _recomputeInTransaction(sessionId, tx);
      return QueueMutationResult(
        QueueMutationOutcome.deleted,
        execution: execution,
      );
    });
    final execution = result.execution;
    if (execution != null) _publish(execution);
    return result;
  }

  StopRecoveryOutcome captureStopRecovery({
    required String sessionId,
    required String stopRequestId,
    required String recoveryOwnerToken,
  }) {
    final pendingInputs = _pendingInputs;
    if (pendingInputs == null) {
      return StopRecoveryOutcome(
        sessionId: sessionId,
        stopRequestId: stopRequestId,
        items: const [],
        createdAt: DateTime.now().toUtc(),
      );
    }
    return _state.transaction((tx) {
      final pending = pendingInputs.recoverPendingForStop(
        sessionId,
        transaction: tx,
      );
      final queued = _workItems.findQueuedWorkItems(sessionId);
      final items = <StopRecoveryItem>[
        ...pending.map(
          (record) => StopRecoveryItem(
            requestId: record.requestId,
            source: 'pending_steer',
            text: record.text,
            receivedAt: record.receivedAt,
          ),
        ),
        ...queued
            .where((item) => item.requestId != null)
            .map(
              (item) => StopRecoveryItem(
                requestId: item.requestId!,
                source: 'queued',
                text: item.payload['message']?.toString() ?? '',
                receivedAt:
                    DateTime.tryParse(
                      item.payload['eventMetadata']?['payload']?['received_at']
                              ?.toString() ??
                          '',
                    )?.toUtc() ??
                    item.createdAt.toUtc(),
              ),
            ),
      ];
      _workItems.cancelWorkItems(
        queued.map((item) => item.workItemId),
        transaction: tx,
      );
      _recomputeInTransaction(sessionId, tx);
      return pendingInputs.saveStopOutcome(
        sessionId: sessionId,
        stopRequestId: stopRequestId,
        items: items,
        recoveryOwnerToken: recoveryOwnerToken,
        transaction: tx,
      );
    });
  }

  SessionExecutionMutation<SessionWorkItem> enqueueWorkItem({
    required String workItemId,
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    String? workspaceId,
    Map<String, dynamic> payload = const {},
    int attempt = 0,
    SessionWorkState state = SessionWorkState.queued,
    Map<String, dynamic> continuationMetadata = const {},
  }) {
    final mutation = _state.transaction((tx) {
      final requiresClaim =
          state == SessionWorkState.running ||
          state == SessionWorkState.resuming;
      var item = _workItems.enqueueWorkItem(
        workItemId: workItemId,
        sessionId: sessionId,
        requestId: requestId,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        workspaceId: workspaceId,
        payload: payload,
        attempt: attempt,
        state: requiresClaim ? SessionWorkState.queued : state,
        continuationMetadata: continuationMetadata,
        transaction: tx,
      );
      if (requiresClaim) {
        final claimed = _workItems.claimNextQueuedWorkItem(
          sessionId,
          toState: state,
          transaction: tx,
        );
        if (claimed == null || claimed.workItemId != workItemId) {
          throw StateError(
            'Could not claim newly enqueued work item $workItemId',
          );
        }
        item = claimed;
      }
      return SessionExecutionMutation(
        value: item,
        execution: _recomputeInTransaction(sessionId, tx),
        applied: true,
      );
    });
    _publish(mutation.execution);
    return mutation;
  }

  /// Atomically decides whether newly accepted work starts immediately or is
  /// queued behind the session's durable active owner.
  ///
  /// The partial unique index on active work is the final invariant. The
  /// transaction keeps the active-work read and the insert/claim decision on
  /// one owner so callers never perform a check-then-insert sequence.
  SessionExecutionMutation<SessionWorkItem> admitWorkItem({
    required String workItemId,
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    String? workspaceId,
    Map<String, dynamic> payload = const {},
    int attempt = 0,
  }) {
    SessionExecutionMutation<SessionWorkItem> admit({
      required bool forceQueued,
    }) {
      return _state.transaction((tx) {
        final hasActiveOwner =
            forceQueued || _workItems.findActiveWorkItem(sessionId) != null;
        var item = _workItems.enqueueWorkItem(
          workItemId: workItemId,
          sessionId: sessionId,
          requestId: requestId,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          workspaceId: workspaceId,
          payload: payload,
          attempt: attempt,
          state: SessionWorkState.queued,
          transaction: tx,
        );
        if (!hasActiveOwner) {
          final claimed = _workItems.claimNextQueuedWorkItem(
            sessionId,
            toState: SessionWorkState.running,
            transaction: tx,
          );
          if (claimed == null || claimed.workItemId != workItemId) {
            throw StateError(
              'Could not claim newly admitted work item $workItemId',
            );
          }
          item = claimed;
        }
        return SessionExecutionMutation(
          value: item,
          execution: _recomputeInTransaction(sessionId, tx),
          applied: true,
        );
      });
    }

    late final SessionExecutionMutation<SessionWorkItem> mutation;
    try {
      mutation = admit(forceQueued: false);
    } on SqliteException catch (error) {
      if (!_isActiveWorkConflict(error)) rethrow;
      // A second connection may have won admission after our preflight. The
      // failed transaction has rolled back, so retry as queued and preserve a
      // normal acceptance outcome instead of leaking SqliteException.
      mutation = admit(forceQueued: true);
    }
    _publish(mutation.execution);
    return mutation;
  }

  static bool _isActiveWorkConflict(SqliteException error) {
    final message = error.message;
    return message.contains(
          'UNIQUE constraint failed: session_work_items.session_id',
        ) &&
        !message.contains('session_work_items.request_id');
  }

  /// Binds the durable work owner to the executor identity before streaming.
  bool bindRunOwnership({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
  }) {
    final mutation = _state.transaction((tx) {
      final active = _workItems.findActiveWorkItem(sessionId);
      if (active == null ||
          active.workItemId != workItemId ||
          (active.state != SessionWorkState.running &&
              active.state != SessionWorkState.resuming)) {
        return false;
      }
      _workItems.updateWorkItem(
        active.copyWith(
          continuationMetadata: {
            ...active.continuationMetadata,
            'owner_run_id': runId,
            'owner_generation': generation,
          },
        ),
        transaction: tx,
      );
      return true;
    });
    return mutation;
  }

  /// Claims a recovery-owned work item for an automatic retry performed by
  /// the same authoritative run. The exact durable owner must still match;
  /// otherwise a stop, manual retry, provider change, or newer generation has
  /// already won and the stale retry must not continue.
  SessionExecutionMutation<SessionWorkItem?> claimOwnedAutomaticRetry({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    String? requestId,
  }) {
    final mutation = _state.transaction((tx) {
      final active = _workItems.findActiveWorkItem(sessionId);
      final ownsRecovery =
          active != null &&
          active.workItemId == workItemId &&
          (active.state == SessionWorkState.waiting ||
              active.state == SessionWorkState.blocked) &&
          active.continuationMetadata['owner_run_id'] == runId &&
          active.continuationMetadata['owner_generation'] == generation &&
          (requestId == null || active.requestId == requestId);
      if (!ownsRecovery) {
        return SessionExecutionMutation(
          value: active,
          execution: SessionExecutionSnapshotChange(
            snapshot: _snapshots.getSnapshot(sessionId),
            changed: false,
          ),
          applied: false,
        );
      }

      _workItems.transitionWorkItemState(
        workItemId: workItemId,
        fromState: active.state,
        toState: SessionWorkState.resuming,
        transaction: tx,
      );
      return SessionExecutionMutation(
        value: _workItems.findWorkItem(workItemId),
        execution: _recomputeInTransaction(sessionId, tx),
        applied: true,
      );
    });
    _publish(mutation.execution);
    return mutation;
  }

  /// Persists the final assistant result and closes the exact owning work item
  /// in one transaction. Transport delivery deliberately happens only after a
  /// [TerminalCommitOutcome.committed] result is returned.
  TerminalCommitOutcome commitTerminal({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    required Message assistantResult,
  }) {
    SessionExecutionSnapshotChange? publishedChange;
    late final TerminalCommitOutcome outcome;
    try {
      outcome = _state.transaction((tx) {
        final active = _workItems.findActiveWorkItem(sessionId);
        if (active == null || active.workItemId != workItemId) {
          return TerminalCommitOutcome.staleOwner;
        }
        if (active.state == SessionWorkState.waiting ||
            active.state == SessionWorkState.blocked) {
          return TerminalCommitOutcome.recoveryOwnsState;
        }
        if (active.state != SessionWorkState.running &&
            active.state != SessionWorkState.resuming) {
          return TerminalCommitOutcome.staleOwner;
        }
        if (active.continuationMetadata['owner_run_id'] != runId ||
            active.continuationMetadata['owner_generation'] != generation) {
          return TerminalCommitOutcome.staleOwner;
        }

        _persistAssistantResult(
          tx,
          sessionId: sessionId,
          workItemId: workItemId,
          runId: runId,
          generation: generation,
          assistantResult: assistantResult,
        );
        _workItems.transitionWorkItemState(
          workItemId: workItemId,
          fromState: active.state,
          toState: SessionWorkState.completed,
          transaction: tx,
        );
        publishedChange = _recomputeInTransaction(sessionId, tx);
        return TerminalCommitOutcome.committed;
      });
    } catch (_) {
      return TerminalCommitOutcome.persistenceFailed;
    }
    final change = publishedChange;
    if (change != null) {
      try {
        _publish(change);
      } catch (_) {
        // The durable commit already succeeded. Projection delivery failure
        // must not be misreported as persistence failure or trigger a second
        // terminal outcome.
      }
    }
    return outcome;
  }

  /// Commits cancelled tool terminals for the exact active run owner.
  ///
  /// Checkpoint outputs and their history messages are written in one
  /// transaction. A completed tool, stale run/generation, or repeated call is
  /// a no-op, so cancellation can never replace another terminal outcome or
  /// emit a second revision.
  ToolTerminalCommitResult commitCancelledToolTerminals({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    required Map<String, Map<String, dynamic>> checkpointOutputs,
    required Map<String, Message> historyMessages,
  }) => commitToolTerminals(
    sessionId: sessionId,
    workItemId: workItemId,
    runId: runId,
    generation: generation,
    checkpointOutputs: checkpointOutputs,
    historyMessages: historyMessages,
  );

  ToolTerminalCommitResult commitToolTerminals({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    required Map<String, Map<String, dynamic>> checkpointOutputs,
    required Map<String, Message> historyMessages,
  }) {
    return _state.transaction((tx) {
      final active = _workItems.findActiveWorkItem(sessionId);
      if (active == null ||
          active.workItemId != workItemId ||
          (active.state != SessionWorkState.running &&
              active.state != SessionWorkState.resuming) ||
          active.continuationMetadata['owner_run_id'] != runId ||
          active.continuationMetadata['owner_generation'] != generation) {
        return const ToolTerminalCommitResult(
          outcome: ToolTerminalCommitOutcome.staleOwner,
        );
      }

      final metadata = Map<String, dynamic>.from(active.continuationMetadata);
      final executing = List<String>.from(
        metadata['currently_executing_tools'] as List? ?? const [],
      ).toSet();
      final completedResults = Map<String, dynamic>.from(
        metadata['completed_tool_results'] as Map? ?? const {},
      );
      final completedOutputs = Map<String, dynamic>.from(
        metadata['completed_tool_outputs'] as Map? ?? const {},
      );
      final toolStartedAt = Map<String, dynamic>.from(
        metadata['tool_started_at'] as Map? ?? const {},
      );
      final executingProgress = Map<String, dynamic>.from(
        metadata['executing_tool_progress'] as Map? ?? const {},
      );
      final persistedToolIds = <String>{};
      final persistedToolArguments = <String, Map<String, dynamic>>{};
      final rows = tx.db.select(
        'SELECT data FROM messages WHERE session_id = ? ORDER BY id ASC',
        [sessionId],
      );
      for (final row in rows) {
        final decoded = jsonDecode(row['data'] as String);
        if (decoded is! Map) continue;
        final message = Message.fromJson(Map<String, dynamic>.from(decoded));
        for (final toolCall in message.toolCalls ?? const []) {
          persistedToolArguments[toolCall.id] = toolCall.arguments;
        }
        if (message.role == MessageRole.tool && message.toolCallId != null) {
          persistedToolIds.add(message.toolCallId!);
        }
      }

      final committedIds = <String>[];
      for (final entry in checkpointOutputs.entries) {
        final toolCallId = entry.key;
        final output = Map<String, dynamic>.from(entry.value);
        if (!executing.contains(toolCallId) ||
            completedResults.containsKey(toolCallId) ||
            completedOutputs.containsKey(toolCallId) ||
            persistedToolIds.contains(toolCallId) ||
            output['session_id'] != sessionId ||
            output['tool_call_id'] != toolCallId ||
            output['run_id'] != runId ||
            output['generation'] != generation ||
            output['status'] == 'running') {
          continue;
        }
        final historyMessage = historyMessages[toolCallId];
        if (historyMessage == null ||
            historyMessage.role != MessageRole.tool ||
            historyMessage.toolCallId != toolCallId) {
          continue;
        }

        // Startup recovery constructs the terminal record from the durable
        // process snapshot. Recover the arguments from the persisted assistant
        // call so the provider receives one faithful tool-use/result pair.
        final originalArguments = persistedToolArguments[toolCallId];
        if (originalArguments != null) {
          output['arguments'] = originalArguments;
        }

        completedResults[toolCallId] = output['result']?.toString() ?? '';
        completedOutputs[toolCallId] = output;
        executing.remove(toolCallId);
        toolStartedAt.remove(toolCallId);
        executingProgress.remove(toolCallId);
        tx.db.execute('INSERT INTO messages (session_id, data) VALUES (?, ?)', [
          sessionId,
          jsonEncode(historyMessage.toJson()),
        ]);
        SessionHistoryRevisionRepository.bumpDatabase(tx.db, sessionId);
        tx.db.execute(
          'DELETE FROM suspended_checkpoints WHERE tool_call_id = ?',
          [toolCallId],
        );
        committedIds.add(toolCallId);
      }

      if (committedIds.isEmpty) {
        return const ToolTerminalCommitResult(
          outcome: ToolTerminalCommitOutcome.noChange,
        );
      }

      metadata['completed_tool_results'] = completedResults;
      metadata['completed_tool_outputs'] = completedOutputs;
      metadata['checkpoint_kind'] = 'after_tool_result';
      final restartTerminalizedToolIds = <String>{
        ...List<String>.from(
          metadata['restart_terminalized_tool_ids'] as List? ?? const [],
        ),
        ...committedIds,
      };
      metadata['restart_terminalized_tool_ids'] = restartTerminalizedToolIds
          .toList();
      if (executing.isEmpty) {
        metadata.remove('currently_executing_tools');
        metadata.remove('tool_started_at');
        metadata.remove('executing_tool_progress');
      } else {
        metadata['currently_executing_tools'] = executing.toList();
        metadata['tool_started_at'] = toolStartedAt;
        if (executingProgress.isEmpty) {
          metadata.remove('executing_tool_progress');
        } else {
          metadata['executing_tool_progress'] = executingProgress;
        }
      }
      _workItems.transitionWorkItemState(
        workItemId: workItemId,
        fromState: active.state,
        toState: active.state,
        continuationMetadata: metadata,
        transaction: tx,
      );
      return ToolTerminalCommitResult(
        outcome: ToolTerminalCommitOutcome.committed,
        committedToolCallIds: committedIds,
      );
    });
  }

  void _persistAssistantResult(
    AgentStateTransaction transaction, {
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    required Message assistantResult,
  }) {
    final rows = transaction.db.select(
      'SELECT id, data FROM messages WHERE session_id = ? ORDER BY id DESC',
      [sessionId],
    );
    int? matchingMessageId;
    Message? matchingMessage;
    for (final row in rows) {
      final decoded = jsonDecode(row['data'] as String);
      if (decoded is! Map) continue;
      final message = Message.fromJson(Map<String, dynamic>.from(decoded));
      if (message.role != MessageRole.assistant) continue;
      final metadata = message.metadata;
      if (metadata?['terminal_work_item_id'] == workItemId ||
          metadata?['run_id'] == runId) {
        matchingMessageId = row['id'] as int;
        matchingMessage = message;
        break;
      }
    }

    final durableResult = (matchingMessage ?? assistantResult).copyWith(
      content: assistantResult.content,
      metadata: {
        ...?matchingMessage?.metadata,
        ...?assistantResult.metadata,
        'run_id': runId,
        'terminal_work_item_id': workItemId,
        'terminal_generation': generation,
      },
    );
    final encoded = jsonEncode(durableResult.toJson());
    if (matchingMessageId == null) {
      transaction.db.execute(
        'INSERT INTO messages (session_id, data) VALUES (?, ?)',
        [sessionId, encoded],
      );
      SessionHistoryRevisionRepository.bumpDatabase(transaction.db, sessionId);
    } else {
      transaction.db.execute('UPDATE messages SET data = ? WHERE id = ?', [
        encoded,
        matchingMessageId,
      ]);
    }
  }

  SessionExecutionMutation<SessionWorkItem?> claimNext(
    String sessionId, {
    bool isResume = false,
    SessionWorkState? toState,
  }) {
    final mutation = _state.transaction((tx) {
      final targetState =
          toState ??
          (isResume ? SessionWorkState.resuming : SessionWorkState.running);
      final item = _workItems.claimNextQueuedWorkItem(
        sessionId,
        toState: targetState,
        transaction: tx,
      );
      return SessionExecutionMutation(
        value: item,
        execution: _recomputeInTransaction(sessionId, tx),
        applied: item != null,
      );
    });
    _publish(mutation.execution);
    return mutation;
  }

  SessionExecutionMutation<SessionWorkItem> transitionWorkItem({
    required String workItemId,
    required SessionWorkState fromState,
    required SessionWorkState toState,
    int? attempt,
    Map<String, dynamic>? continuationMetadata,
    String? providerInstanceId,
    String? modelId,
  }) {
    final mutation = _state.transaction((tx) {
      final current = _workItems.findWorkItem(workItemId);
      if (current == null) {
        throw StateError('Work item $workItemId not found');
      }
      _workItems.transitionWorkItemState(
        workItemId: workItemId,
        fromState: fromState,
        toState: toState,
        attempt: attempt,
        continuationMetadata: continuationMetadata,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        transaction: tx,
      );
      return SessionExecutionMutation(
        value: _workItems.findWorkItem(workItemId)!,
        execution: _recomputeInTransaction(current.sessionId, tx),
        applied: true,
      );
    });
    _publish(mutation.execution);
    return mutation;
  }

  /// Applies a callback-owned transition only while [workItemId] is still the
  /// session's active durable owner. A stale generation becomes a no-op and
  /// cannot mutate the aggregate for a newer run.
  SessionExecutionMutation<SessionWorkItem?> transitionOwnedWorkItem({
    required String sessionId,
    required String workItemId,
    required SessionWorkState toState,
  }) {
    final mutation = _state.transaction((tx) {
      final active = _workItems.findActiveWorkItem(sessionId);
      if (active == null || active.workItemId != workItemId) {
        return SessionExecutionMutation(
          value: active,
          execution: SessionExecutionSnapshotChange(
            snapshot: _snapshots.getSnapshot(sessionId),
            changed: false,
          ),
          applied: false,
        );
      }
      _workItems.transitionWorkItemState(
        workItemId: workItemId,
        fromState: active.state,
        toState: toState,
        transaction: tx,
      );
      return SessionExecutionMutation(
        value: _workItems.findWorkItem(workItemId),
        execution: _recomputeInTransaction(sessionId, tx),
        applied: true,
      );
    });
    _publish(mutation.execution);
    return mutation;
  }

  SessionExecutionSnapshotChange markStopping(
    String sessionId, {
    String? expectedWorkItemId,
  }) {
    final change = _state.transaction((tx) {
      final representative = _representativeWorkItem(sessionId);
      if (expectedWorkItemId != null &&
          representative?.workItemId != expectedWorkItemId) {
        return SessionExecutionSnapshotChange(
          snapshot: _snapshots.getSnapshot(sessionId),
          changed: false,
        );
      }
      return _snapshots.updateSnapshot(
        sessionId: sessionId,
        state: SessionExecutionState.stopping,
        workItemId: representative?.workItemId,
        requestId: representative?.requestId,
        transaction: tx,
        turnStartedAt: representative?.createdAt,
      );
    });
    _publish(change);
    return change;
  }

  SessionExecutionSnapshotChange cancelAll(
    String sessionId, {
    bool publish = true,
  }) {
    final change = _state.transaction((tx) {
      _workItems.cancelAllActiveAndQueuedWorkItems(sessionId, transaction: tx);
      return _recomputeInTransaction(sessionId, tx, preserveStopping: false);
    });
    if (publish) _publish(change);
    return change;
  }

  SessionExecutionSnapshotChange cancelWorkItems(
    String sessionId,
    Iterable<String> workItemIds, {
    bool publish = true,
  }) {
    final change = _state.transaction((tx) {
      _workItems.cancelWorkItems(workItemIds, transaction: tx);
      return _recomputeInTransaction(sessionId, tx, preserveStopping: false);
    });
    if (publish) _publish(change);
    return change;
  }

  SessionExecutionSnapshotChange recompute(String sessionId) {
    final change = _state.transaction(
      (tx) => _recomputeInTransaction(sessionId, tx),
    );
    _publish(change);
    return change;
  }

  /// Rebuilds a snapshot from durable work after a process restart.
  ///
  /// Unlike normal recomputation this deliberately does not preserve the
  /// transient `stopping` projection: the new process derives authority from
  /// the work rows it actually restored.
  SessionExecutionSnapshotChange normalizeAfterRestart(String sessionId) {
    final change = _state.transaction(
      (tx) => _recomputeInTransaction(sessionId, tx, preserveStopping: false),
    );
    _publish(change);
    return change;
  }

  void _publish(SessionExecutionSnapshotChange change) {
    if (change.changed) {
      _changes.add(change.snapshot);
    }
  }

  /// Publishes a snapshot change committed atomically by another aggregate
  /// coordinator on the same state database.
  ///
  /// Automatic failover owns a cross-table transaction that includes the
  /// work-item claim, route mutation, and execution snapshot. It delegates
  /// the post-commit notification here so every execution transition still
  /// leaves through the single authoritative [changes] stream.
  void publishCommittedChange(SessionExecutionSnapshotChange change) {
    _publish(change);
  }

  SessionExecutionSnapshotChange _recomputeInTransaction(
    String sessionId,
    AgentStateTransaction transaction, {
    bool preserveStopping = true,
  }) {
    final currentSnapshot = _snapshots.getSnapshot(sessionId);
    if (preserveStopping &&
        currentSnapshot.state == SessionExecutionState.stopping) {
      return SessionExecutionSnapshotChange(
        snapshot: currentSnapshot,
        changed: false,
      );
    }
    final active = _workItems.findActiveWorkItem(sessionId);
    if (active != null) {
      return _snapshots.updateSnapshot(
        sessionId: sessionId,
        state: _executionStateFor(active.state),
        workItemId: active.workItemId,
        requestId: active.requestId,
        transaction: transaction,
        turnStartedAt: active.createdAt,
      );
    }
    final queued = _workItems.findQueuedWorkItems(sessionId);
    if (queued.isNotEmpty) {
      final head = queued.first;
      return _snapshots.updateSnapshot(
        sessionId: sessionId,
        state: SessionExecutionState.queued,
        workItemId: head.workItemId,
        requestId: head.requestId,
        transaction: transaction,
        turnStartedAt: head.createdAt,
      );
    }
    return _snapshots.updateSnapshot(
      sessionId: sessionId,
      state: SessionExecutionState.idle,
      transaction: transaction,
    );
  }

  SessionWorkItem? _representativeWorkItem(String sessionId) {
    return _workItems.findActiveWorkItem(sessionId) ??
        _workItems.findQueuedWorkItems(sessionId).firstOrNull;
  }

  static SessionExecutionState _executionStateFor(SessionWorkState state) {
    return switch (state) {
      SessionWorkState.running => SessionExecutionState.running,
      SessionWorkState.waiting => SessionExecutionState.waiting,
      SessionWorkState.blocked => SessionExecutionState.blocked,
      SessionWorkState.resuming => SessionExecutionState.resuming,
      SessionWorkState.queued => SessionExecutionState.queued,
      SessionWorkState.completed ||
      SessionWorkState.cancelled => SessionExecutionState.idle,
    };
  }
}

enum ToolTerminalCommitOutcome { committed, noChange, staleOwner }

class ToolTerminalCommitResult {
  final ToolTerminalCommitOutcome outcome;
  final List<String> committedToolCallIds;

  const ToolTerminalCommitResult({
    required this.outcome,
    this.committedToolCallIds = const [],
  });
}

class SessionExecutionMutation<T> {
  final T value;
  final SessionExecutionSnapshotChange execution;
  final bool applied;

  const SessionExecutionMutation({
    required this.value,
    required this.execution,
    required this.applied,
  });
}

enum TerminalCommitOutcome {
  committed,
  staleOwner,
  recoveryOwnsState,
  persistenceFailed,
}

enum QueueMutationOutcome {
  promoted,
  deleted,
  alreadyProcessed,
  alreadyRemoved,
  staleOwner,
  notFound,
}

class QueueMutationResult {
  final QueueMutationOutcome outcome;
  final PendingSteerRecord? pendingSteer;
  final SessionExecutionSnapshotChange? execution;

  const QueueMutationResult(this.outcome, {this.pendingSteer, this.execution});
}
