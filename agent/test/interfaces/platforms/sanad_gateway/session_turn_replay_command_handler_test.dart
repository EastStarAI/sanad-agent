import 'dart:async';

import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_turn_replay_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late SessionManager sessions;
  late PersistedRuntimeStateRepository runtime;
  late CompactionBoundaryRepository compactionBoundaries;
  late _RecordingOrchestrator orchestrator;
  late SessionTurnReplayCommandHandler handler;
  late String sessionId;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    runtime = PersistedRuntimeStateRepository.fromState(state);
    compactionBoundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    orchestrator = _RecordingOrchestrator();
    handler = SessionTurnReplayCommandHandler(
      orchestrator: orchestrator,
      sessionManager: sessions,
      persistedState: runtime,
      compactionBoundaries: compactionBoundaries,
      bridge: _EnvelopeBridge(),
      idleWaitTimeout: const Duration(milliseconds: 80),
      idlePollInterval: const Duration(milliseconds: 10),
    );
    sessionId = sessions.createSession('model').sessionId;
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
  });

  CanonicalEvent command({
    required String requestId,
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    Object? expectedHistoryRevision,
    String action = 'retry',
    String? message,
    bool confirmed = false,
    bool confirmedDropSteers = false,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
  }) {
    return CanonicalEvent(
      type: CanonicalEventTypes.sessionTurnReplay,
      sessionId: sessionId,
      payload: {
        'session_id': sessionId,
        'request_id': requestId,
        'target_request_id': targetRequestId,
        'target_message_id': ?targetMessageId,
        'target_turn_id': ?targetTurnId,
        'expected_history_revision':
            expectedHistoryRevision ??
            sessions.getSession(sessionId)?.historyRevision,
        'action': action,
        'message': ?message,
        'confirmed_replay_unsafe': confirmed,
        'confirmed_drop_steers': confirmedDropSteers,
        'provider_instance_id': ?providerInstanceId,
        'model_id': ?modelId,
        'thinking_mode': ?thinkingMode,
      },
    );
  }

  test('omitted identity fields are invalid_request before Stop', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(requestId: 'cmd-1', targetRequestId: 'root-1'),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'invalid_request');
    expect(orchestrator.stopCount, 0);
    expect(sessions.getMessages(sessionId), hasLength(1));
  });

  test('compacted targets are rejected before Stop or mutation', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'compact this',
        metadata: const {'request_id': 'root-compacted'},
      ),
      Message(role: MessageRole.assistant, content: 'answer'),
    ]);
    final stored = sessions.getMessages(sessionId);
    final target = stored.first;
    final rows = state.db.select(
      'SELECT id FROM messages WHERE session_id = ? ORDER BY id ASC',
      [sessionId],
    );
    _insertCompletedCompaction(
      state,
      sessionId: sessionId,
      sourceRowId: rows.first['id'] as int,
      tailRowId: rows.last['id'] as int,
    );
    final envelopes = <Map<String, dynamic>>[];

    await handler.handle(
      command(
        requestId: 'cmd-compacted',
        targetRequestId: 'root-compacted',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );

    expect(
      envelopes.single['payload']['outcome'],
      'target_precedes_compaction',
    );
    expect(orchestrator.stopCount, 0);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId), hasLength(2));
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('pending steer targets are rejected before Stop or mutation', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'root',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    runtime.pendingInputs.insertPending(
      sessionId: sessionId,
      requestId: 'steer-pending',
      runId: 'run-1',
      generation: 1,
      text: 'nudge',
      receivedAt: DateTime.utc(2026, 8, 30),
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'cmd-1',
        targetRequestId: 'steer-pending',
        targetMessageId: 'missing-message',
        targetTurnId: 'missing-turn',
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(
      envelopes.single['payload']['outcome'],
      'target_not_replayable_input',
    );
    expect(orchestrator.stopCount, 0);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId), hasLength(1));
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('steer targets are rejected before Stop or mutation', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'root',
        metadata: const {'request_id': 'root-1'},
      ),
      Message(role: MessageRole.assistant, content: 'working'),
      Message(
        role: MessageRole.user,
        content: 'nudge',
        metadata: const {'steer': true, 'request_id': 'steer-1'},
      ),
    ]);
    final stored = sessions.getMessages(sessionId);
    final steer = stored.last;
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'cmd-1',
        targetRequestId: 'steer-1',
        targetMessageId: steer.metadata?['message_id']?.toString(),
        targetTurnId: steer.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(
      envelopes.single['payload']['outcome'],
      'target_not_replayable_input',
    );
    expect(orchestrator.stopCount, 0);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId), hasLength(3));
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('embedded steer targets are rejected before Stop or mutation', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'root',
        metadata: const {'request_id': 'root-1'},
      ),
      Message(
        role: MessageRole.tool,
        content: 'result',
        toolCallId: 'call-1',
        metadata: const {
          'steer_messages': [
            {'text': 'nudge', 'request_id': 'steer-embedded'},
          ],
        },
      ),
    ]);
    final stored = sessions.getMessages(sessionId);
    final steer = Map<String, dynamic>.from(
      (stored.last.metadata?['steer_messages'] as List).single as Map,
    );
    final envelopes = <Map<String, dynamic>>[];

    await handler.handle(
      command(
        requestId: 'cmd-embedded',
        targetRequestId: 'steer-embedded',
        targetMessageId: steer['message_id']?.toString(),
        targetTurnId: steer['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );

    expect(
      envelopes.single['payload']['outcome'],
      'target_not_replayable_input',
    );
    expect(orchestrator.stopCount, 0);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId), hasLength(2));
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('steer drop confirmation is required before Stop', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'root',
        metadata: const {'request_id': 'root-1'},
      ),
      Message(role: MessageRole.assistant, content: 'working'),
      Message(
        role: MessageRole.user,
        content: 'nudge',
        metadata: const {'steer': true, 'request_id': 'steer-1'},
      ),
    ]);
    final root = sessions.getMessages(sessionId).first;
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'cmd-1',
        targetRequestId: 'root-1',
        targetMessageId: root.metadata?['message_id']?.toString(),
        targetTurnId: root.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(
      envelopes.single['payload']['outcome'],
      'steer_reinjection_confirmation_required',
    );
    expect(orchestrator.stopCount, 0);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('unconfirmed unsafe replay does not Stop or mutate history', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'change the file',
        metadata: const {'request_id': 'root-1'},
      ),
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(id: 'tool-1', name: 'file_edit', arguments: const {}),
        ],
      ),
    ]);
    final now = DateTime.now().toUtc();
    runtime.workItems.insertWorkItem(
      SessionWorkItem(
        workItemId: 'work-1',
        sessionId: sessionId,
        requestId: 'root-1',
        sequence: 1,
        attempt: 0,
        state: SessionWorkState.completed,
        continuationMetadata: const {
          'tool_replay_safety': {'tool-1': false},
        },
        createdAt: now,
        updatedAt: now,
      ),
    );
    final target = sessions.getMessages(sessionId).first;
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'cmd-1',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'confirmation_required');
    expect(orchestrator.stopCount, 0);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId).first.content, 'change the file');
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('non-idle snapshot yields session_not_idle without mutation', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    runtime.executionState.enqueueWorkItem(
      workItemId: 'work-running',
      sessionId: sessionId,
      requestId: 'root-1',
      state: SessionWorkState.running,
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'cmd-1',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'session_not_idle');
    expect(orchestrator.stopCount, 1);
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId).single.content, 'hello');
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('running work that reaches idle is admitted after the wait', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    runtime.executionState.enqueueWorkItem(
      workItemId: 'work-running',
      sessionId: sessionId,
      requestId: 'root-1',
      state: SessionWorkState.running,
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 25), () {
        runtime.executionSnapshots.updateSnapshot(
          sessionId: sessionId,
          state: SessionExecutionState.idle,
        );
      }),
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'cmd-running-idle',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'accepted');
    expect(orchestrator.stopCount, 1);
    expect(orchestrator.events, hasLength(1));
  });

  test('non-stopping non-idle snapshots are not dispatch authority', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final otherId = sessions.createSession('model').sessionId;
    expect(otherId, isNot(sessionId));
    sessions.saveSessionHistory(otherId, [
      Message(
        role: MessageRole.user,
        content: 'other',
        metadata: const {'request_id': 'other-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    for (final executionState in [
      SessionExecutionState.queued,
      SessionExecutionState.waiting,
      SessionExecutionState.blocked,
      SessionExecutionState.resuming,
    ]) {
      runtime.executionSnapshots.updateSnapshot(
        sessionId: sessionId,
        state: executionState,
      );
      final envelopes = <Map<String, dynamic>>[];
      await handler.handle(
        command(
          requestId: 'cmd-${executionState.name}',
          targetRequestId: 'root-1',
          targetMessageId: target.metadata?['message_id']?.toString(),
          targetTurnId: target.metadata?['turn_id']?.toString(),
        ),
        (envelope) async => envelopes.add(envelope),
      );
      expect(
        envelopes.single['payload']['outcome'],
        'session_not_idle',
        reason: executionState.name,
      );
      expect(orchestrator.events, isEmpty);
    }
    expect(sessions.getMessages(sessionId).single.content, 'hello');
    expect(sessions.getMessages(otherId).single.content, 'other');
    expect(sessions.getSession(otherId)!.historyRevision, 1);
  });

  test('missing execution snapshot state is not dispatch authority', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    final isolated = SessionTurnReplayCommandHandler(
      orchestrator: orchestrator,
      sessionManager: sessions,
      persistedState: null,
      bridge: _EnvelopeBridge(),
    );
    final envelopes = <Map<String, dynamic>>[];
    await isolated.handle(
      command(
        requestId: 'cmd-no-snapshot',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'session_not_idle');
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId).single.content, 'hello');
  });

  test(
    'transaction failure returns failed and leaves original active',
    () async {
      sessions.saveSessionHistory(sessionId, [
        Message(
          role: MessageRole.user,
          content: 'hello',
          metadata: const {'request_id': 'root-1'},
        ),
        Message(role: MessageRole.assistant, content: 'answer'),
      ]);
      final target = sessions.getMessages(sessionId).first;
      state.db.execute('''
      CREATE TRIGGER reject_handler_replay_supersession
      BEFORE UPDATE OF history_status ON messages
      WHEN NEW.history_status = 'superseded'
      BEGIN
        SELECT RAISE(ABORT, 'forced handler rollback');
      END;
    ''');
      final envelopes = <Map<String, dynamic>>[];

      await handler.handle(
        command(
          requestId: 'replacement-failed',
          targetRequestId: 'root-1',
          targetMessageId: target.metadata?['message_id']?.toString(),
          targetTurnId: target.metadata?['turn_id']?.toString(),
        ),
        (envelope) async => envelopes.add(envelope),
      );

      expect(envelopes.single['payload']['outcome'], 'failed');
      expect(orchestrator.events, isEmpty);
      expect(sessions.getSession(sessionId)!.historyRevision, 1);
      expect(
        sessions.getMessages(sessionId).map((message) => message.content),
        ['hello', 'answer'],
      );
      expect(
        sessions.getMessages(sessionId, includeSuperseded: true),
        hasLength(2),
      );
    },
  );

  test(
    'accepted admission dispatches once and keeps superseded rows',
    () async {
      sessions.saveSessionHistory(sessionId, [
        Message(
          role: MessageRole.user,
          content: 'hello',
          metadata: const {'request_id': 'root-1'},
        ),
        Message(role: MessageRole.assistant, content: 'answer'),
      ]);
      final target = sessions.getMessages(sessionId).first;
      final envelopes = <Map<String, dynamic>>[];
      await handler.handle(
        command(
          requestId: 'replacement-1',
          targetRequestId: 'root-1',
          targetMessageId: target.metadata?['message_id']?.toString(),
          targetTurnId: target.metadata?['turn_id']?.toString(),
        ),
        (envelope) async => envelopes.add(envelope),
      );
      expect(envelopes.single['payload']['outcome'], 'accepted');
      expect(envelopes.single['payload']['history_revision'], 2);
      expect(orchestrator.events, hasLength(1));
      expect(
        orchestrator.events.single.turnRequest?.requestId,
        'replacement-1',
      );
      expect(
        orchestrator.events.single.message.metadata?['message_id'],
        isNotEmpty,
      );
      expect(
        orchestrator.events.single.message.metadata?['turn_id'],
        isNotEmpty,
      );
      expect(
        orchestrator.events.single.message.metadata?['message_id'],
        isNot(target.metadata?['message_id']),
      );
      final active = sessions.getMessages(sessionId);
      expect(active, hasLength(1));
      expect(active.single.content, 'hello');
      expect(active.single.metadata?['request_id'], 'replacement-1');
      expect(
        sessions.getMessages(sessionId, includeSuperseded: true),
        hasLength(3),
      );
    },
  );

  test('accepted dispatch uses the final command route', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'replacement-route',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
        providerInstanceId: 'provider-live',
        modelId: 'model-live',
        thinkingMode: 'deep',
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'accepted');
    final request = orchestrator.events.single.turnRequest;
    expect(request?.providerInstanceId, 'provider-live');
    expect(request?.model, 'model-live');
    expect(request?.thinkingMode, 'deep');
  });

  test('serialized replay commands return already_in_progress', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    orchestrator.holdStop = Completer<void>();
    final firstEnvelopes = <Map<String, dynamic>>[];
    final secondEnvelopes = <Map<String, dynamic>>[];
    final first = handler.handle(
      command(
        requestId: 'replacement-1',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => firstEnvelopes.add(envelope),
    );
    await orchestrator.stopStarted.future;
    await handler.handle(
      command(
        requestId: 'replacement-2',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => secondEnvelopes.add(envelope),
    );
    expect(secondEnvelopes.single['payload']['outcome'], 'already_in_progress');
    orchestrator.holdStop!.complete();
    await first;
    expect(firstEnvelopes.single['payload']['outcome'], 'accepted');
    expect(orchestrator.events, hasLength(1));
  });

  test('replay waits for stopping to become idle before admission', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    runtime.executionSnapshots.updateSnapshot(
      sessionId: sessionId,
      state: SessionExecutionState.stopping,
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 25), () {
        runtime.executionSnapshots.updateSnapshot(
          sessionId: sessionId,
          state: SessionExecutionState.idle,
        );
      }),
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'replacement-1',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'accepted');
    expect(orchestrator.events, hasLength(1));
  });

  test('a newer root during idle wait is stale_turn_boundary', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    runtime.executionSnapshots.updateSnapshot(
      sessionId: sessionId,
      state: SessionExecutionState.stopping,
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 25), () {
        sessions.saveSessionHistory(sessionId, [
          ...sessions.getMessages(sessionId),
          Message(
            role: MessageRole.user,
            content: 'newer',
            metadata: const {'request_id': 'root-2'},
          ),
        ]);
        runtime.executionSnapshots.updateSnapshot(
          sessionId: sessionId,
          state: SessionExecutionState.idle,
        );
      }),
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'replacement-1',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'stale_turn_boundary');
    expect(orchestrator.events, isEmpty);
    expect(sessions.getSession(sessionId)!.historyRevision, 2);
    expect(sessions.getMessages(sessionId).map((message) => message.content), [
      'hello',
      'newer',
    ]);
  });

  test('stopping timeout is session_not_idle without mutation', () async {
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'root-1'},
      ),
    ]);
    final target = sessions.getMessages(sessionId).single;
    runtime.executionSnapshots.updateSnapshot(
      sessionId: sessionId,
      state: SessionExecutionState.stopping,
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'replacement-1',
        targetRequestId: 'root-1',
        targetMessageId: target.metadata?['message_id']?.toString(),
        targetTurnId: target.metadata?['turn_id']?.toString(),
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'session_not_idle');
    expect(orchestrator.events, isEmpty);
    expect(sessions.getMessages(sessionId).single.content, 'hello');
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });
}

void _insertCompletedCompaction(
  AgentStateDatabase state, {
  required String sessionId,
  required int sourceRowId,
  required int tailRowId,
}) {
  state.db.execute(
    '''
    INSERT INTO session_compaction_operations (
      compaction_id, session_id, trigger, status,
      source_history_revision,
      source_start_message_id, source_end_message_id,
      tail_start_message_id, tail_end_message_id,
      provider_instance_id, model_id, template_id, protocol,
      normalized_base_url, config_revision, credential_revision,
      context_window_tokens, effective_input_budget_tokens,
      auto_threshold_tokens, estimated_request_tokens_before,
      estimated_request_tokens_after, retained_tail_tokens,
      internal_summary_json, started_at, completed_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      'compaction-handler-guard',
      sessionId,
      'manual',
      'completed',
      1,
      sourceRowId,
      sourceRowId,
      tailRowId,
      tailRowId,
      'provider',
      'model',
      'template',
      'test',
      'https://example.invalid',
      1,
      1,
      1000,
      900,
      800,
      700,
      200,
      100,
      '{"currentGoal":"guard replay"}',
      '2026-08-31T00:00:00Z',
      '2026-08-31T00:00:01Z',
    ],
  );
}

class _EnvelopeBridge extends SanadProtocolBridge {
  @override
  Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) {
    return {
      'event': canonicalEvent.type,
      'payload': canonicalEvent.payload,
      'session_id': canonicalEvent.sessionId,
    };
  }
}

class _RecordingOrchestrator extends SessionRunOrchestrator {
  int stopCount = 0;
  Completer<void>? holdStop;
  final stopStarted = Completer<void>();
  final events = <GatewayEvent>[];

  @override
  Future<void> requestStop(
    String sessionId, {
    bool forceEmitStopped = false,
    String? stopRequestId,
    String? recoveryOwnerToken,
  }) async {
    stopCount++;
    if (!stopStarted.isCompleted) {
      stopStarted.complete();
    }
    final hold = holdStop;
    if (hold != null) {
      await hold.future;
    }
  }

  @override
  Future<void> handleEvent(GatewayEvent event) async {
    events.add(event);
  }
}
