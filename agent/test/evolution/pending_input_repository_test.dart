import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/models/pending_steer_record.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository runtime;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    runtime = PersistedRuntimeStateRepository(state.db);
  });

  tearDown(() => state.dispose());

  void seedSession(String sessionId) {
    state.db.execute(
      'INSERT INTO sessions (session_id, model, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      [sessionId, 'test-model', '2026-07-15', '2026-07-15'],
    );
  }

  test(
    'cancel and delivery reservation resolve to one authoritative winner',
    () {
      seedSession('session-race');
      runtime.pendingInputs.insertPending(
        sessionId: 'session-race',
        requestId: 'request-1',
        runId: 'run-1',
        generation: 3,
        text: 'change direction',
        receivedAt: DateTime.utc(2026, 7, 15, 10),
      );

      final reserved = runtime.pendingInputs.reserve(
        sessionId: 'session-race',
        requestId: 'request-1',
        runId: 'run-1',
        generation: 3,
      );
      expect(reserved.outcome, PendingSteerReserveOutcome.reserved);
      expect(reserved.record!.state, PendingSteerState.delivering);
      expect(reserved.record!.revision, 2);

      final cancelled = runtime.pendingInputs.cancel(
        sessionId: 'session-race',
        requestId: 'request-1',
        runId: 'run-1',
        generation: 3,
      );
      expect(cancelled.outcome, PendingSteerCancelOutcome.deliveryInProgress);
      expect(cancelled.record!.revision, 2);

      final delivered = runtime.pendingInputs.markDelivered(
        sessionId: 'session-race',
        requestId: 'request-1',
        runId: 'run-1',
        generation: 3,
        messageId: 'steer-message-1',
        turnId: 'turn-1',
        anchorMessageId: 'tool-message-1',
        anchorToolCallId: 'tool-call-1',
        historyRevision: 8,
      );
      expect(delivered!.state, PendingSteerState.delivered);
      expect(delivered.revision, 3);
      expect(delivered.messageId, 'steer-message-1');
      expect(delivered.turnId, 'turn-1');
      expect(delivered.anchorMessageId, 'tool-message-1');
      expect(delivered.anchorToolCallId, 'tool-call-1');
      expect(delivered.historyRevision, 8);
    },
  );

  test(
    'delivery placement rolls back with its owning aggregate transaction',
    () {
      seedSession('session-atomic');
      runtime.pendingInputs.insertPending(
        sessionId: 'session-atomic',
        requestId: 'request-atomic',
        runId: 'run-atomic',
        generation: 1,
        text: 'atomic steer',
        receivedAt: DateTime.utc(2026, 7, 15, 10),
      );
      runtime.pendingInputs.reserve(
        sessionId: 'session-atomic',
        requestId: 'request-atomic',
        runId: 'run-atomic',
        generation: 1,
      );

      expect(
        () => state.transaction((transaction) {
          runtime.pendingInputs.markDelivered(
            sessionId: 'session-atomic',
            requestId: 'request-atomic',
            runId: 'run-atomic',
            generation: 1,
            messageId: 'message-atomic',
            turnId: 'turn-atomic',
            anchorToolCallId: 'tool-atomic',
            historyRevision: 2,
            transaction: transaction,
          );
          throw StateError('rollback aggregate');
        }),
        throwsStateError,
      );

      final record = runtime.pendingInputs.find(
        'session-atomic',
        'request-atomic',
      )!;
      expect(record.state, PendingSteerState.delivering);
      expect(record.messageId, isNull);
      expect(record.historyRevision, isNull);
    },
  );

  test('failed history persistence releases delivery without losing text', () {
    seedSession('session-failure');
    runtime.pendingInputs.insertPending(
      sessionId: 'session-failure',
      requestId: 'request-failure',
      runId: 'run-failure',
      generation: 1,
      text: 'do not lose me',
      receivedAt: DateTime.utc(2026, 7, 15, 11),
    );
    runtime.pendingInputs.reserve(
      sessionId: 'session-failure',
      requestId: 'request-failure',
      runId: 'run-failure',
      generation: 1,
    );

    final released = runtime.pendingInputs.releaseDeliveryAfterFailure(
      sessionId: 'session-failure',
      requestId: 'request-failure',
      runId: 'run-failure',
      generation: 1,
    );
    expect(released!.state, PendingSteerState.pending);
    expect(released.text, 'do not lose me');
    expect(released.revision, 3);
  });

  test(
    'queued promotion cancels durable queue row and creates pending steer',
    () {
      seedSession('session-promotion');
      runtime.executionState.enqueueWorkItem(
        workItemId: 'active-work',
        sessionId: 'session-promotion',
        requestId: 'active-request',
        state: SessionWorkState.running,
      );
      expect(
        runtime.bindRunOwnership(
          sessionId: 'session-promotion',
          workItemId: 'active-work',
          runId: 'run-active',
          generation: 4,
        ),
        isTrue,
      );
      runtime.executionState.enqueueWorkItem(
        workItemId: 'queued-work',
        sessionId: 'session-promotion',
        requestId: 'queued-request',
        payload: const {'message': 'queued text'},
      );

      final result = runtime.executionState.promoteQueuedToPendingSteer(
        sessionId: 'session-promotion',
        requestId: 'queued-request',
        runId: 'run-active',
        generation: 4,
        text: 'queued text',
        receivedAt: DateTime.utc(2026, 7, 15, 12),
      );

      expect(result.outcome, QueueMutationOutcome.promoted);
      expect(
        runtime.workItems.findWorkItem('queued-work')!.state,
        SessionWorkState.cancelled,
      );
      expect(result.pendingSteer!.state, PendingSteerState.pending);
      expect(
        runtime.executionSnapshots.getSnapshot('session-promotion').requestId,
        'active-request',
      );
    },
  );

  test(
    'stop capture orders pending before FIFO queue and survives until ack',
    () {
      seedSession('session-stop');
      runtime.pendingInputs.insertPending(
        sessionId: 'session-stop',
        requestId: 'pending-a',
        runId: 'run-stop',
        generation: 1,
        text: 'A',
        receivedAt: DateTime.utc(2026, 7, 15, 8),
      );
      runtime.executionState.enqueueWorkItem(
        workItemId: 'queued-c',
        sessionId: 'session-stop',
        requestId: 'queued-c',
        payload: const {'message': 'C'},
      );
      runtime.executionState.enqueueWorkItem(
        workItemId: 'queued-d',
        sessionId: 'session-stop',
        requestId: 'queued-d',
        payload: const {'message': 'D'},
      );

      final outcome = runtime.executionState.captureStopRecovery(
        sessionId: 'session-stop',
        stopRequestId: 'stop-1',
        recoveryOwnerToken: 'owner-stop-1',
      );
      expect(outcome.items.map((item) => item.text), ['A', 'C', 'D']);
      expect(outcome.items.map((item) => item.source), [
        'pending_steer',
        'queued',
        'queued',
      ]);
      expect(outcome.toPayload(), isNot(contains('claimed_by')));
      expect(runtime.pendingInputs.findStopOutcome('stop-1'), isNotNull);
      expect(
        runtime.pendingInputs.acknowledgeStopOutcome(
          'session-stop',
          'stop-1',
          recoveryOwnerToken: 'wrong-owner',
        ),
        isFalse,
      );
      expect(
        runtime.pendingInputs.acknowledgeStopOutcome(
          'session-stop',
          'stop-1',
          recoveryOwnerToken: 'owner-stop-1',
        ),
        isTrue,
      );
      expect(
        runtime.pendingInputs.findStopOutcome('stop-1')!.isAcknowledged,
        isTrue,
      );
      expect(runtime.pendingInputs.findStopOutcome('stop-1')!.items, isEmpty);
    },
  );

  test(
    'restart converts an unowned pending steer into durable draft recovery',
    () {
      seedSession('session-restart');
      runtime.pendingInputs.insertPending(
        sessionId: 'session-restart',
        requestId: 'pending-restart',
        runId: 'old-run',
        generation: 7,
        text: 'recover after restart',
        receivedAt: DateTime.utc(2026, 7, 15, 13),
      );

      final restarted = PersistedRuntimeStateRepository(state.db);
      final outcomes = restarted.pendingInputs.reconcileAfterRestart();

      expect(outcomes, hasLength(1));
      expect(outcomes.single.items.single.text, 'recover after restart');
      expect(outcomes.single.recoveryReason, 'daemon_restart');
      expect(outcomes.single.toPayload()['claim_required'], isTrue);
      expect(outcomes.single.toPayload()['items'], isEmpty);
      final claimed = restarted.pendingInputs.claimStopOutcome(
        sessionId: 'session-restart',
        stopRequestId: outcomes.single.stopRequestId,
        claimantId: 'claim-command-1',
      );
      expect(claimed, isNotNull);
      expect(claimed!.toPayload()['claim_required'], isFalse);
      expect(claimed.toPayload()['claimed_by'], 'claim-command-1');
      expect(claimed.items.single.text, 'recover after restart');
      expect(
        restarted.pendingInputs.claimStopOutcome(
          sessionId: 'session-restart',
          stopRequestId: outcomes.single.stopRequestId,
          claimantId: 'claim-command-2',
        ),
        isNull,
      );
      final stored = restarted.pendingInputs.findStopOutcome(
        outcomes.single.stopRequestId,
      )!;
      expect(stored.toPayload()['claim_required'], isTrue);
      expect(stored.toPayload()['items'], isEmpty);
      expect(stored.toPayload(), isNot(contains('claimed_by')));
      expect(
        restarted.pendingInputs.acknowledgeStopOutcome(
          'session-restart',
          outcomes.single.stopRequestId,
          claimantId: 'claim-command-2',
        ),
        isFalse,
      );
      expect(
        restarted.pendingInputs
            .findStopOutcome(outcomes.single.stopRequestId)!
            .isAcknowledged,
        isFalse,
      );
      expect(
        restarted.pendingInputs.acknowledgeStopOutcome(
          'session-restart',
          outcomes.single.stopRequestId,
          claimantId: 'claim-command-1',
        ),
        isTrue,
      );
      expect(
        restarted.pendingInputs
            .findStopOutcome(outcomes.single.stopRequestId)!
            .items,
        isEmpty,
      );
      expect(
        restarted.pendingInputs
            .find('session-restart', 'pending-restart')!
            .state,
        PendingSteerState.recovered,
      );
      expect(restarted.pendingInputs.reconcileAfterRestart(), isEmpty);
    },
  );
}
