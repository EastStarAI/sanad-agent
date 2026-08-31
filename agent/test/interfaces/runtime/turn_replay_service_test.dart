import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/runtime/turn_replay_service.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late SessionManager sessions;
  late PersistedRuntimeStateRepository runtime;
  late String sessionId;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    runtime = PersistedRuntimeStateRepository.fromState(state);
    sessionId = sessions.createSession('model').sessionId;
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
  });

  Message user(String requestId, String text) => Message(
    role: MessageRole.user,
    content: text,
    metadata: {'request_id': requestId},
  );

  test(
    'safe latest turn is resolved and soft-rewound at its user boundary',
    () {
      sessions.saveSessionHistory(sessionId, [
        user('request-1', 'first'),
        Message(role: MessageRole.assistant, content: 'first answer'),
        user('request-2', 'second'),
        Message(role: MessageRole.assistant, content: 'second answer'),
      ]);
      final service = TurnReplayService(
        sessionManager: sessions,
        persistedState: runtime,
      );

      final inspection = service.inspect(
        sessionId: sessionId,
        targetRequestId: 'request-2',
      );

      expect(inspection.canReplay, isTrue);
      expect(inspection.safety, TurnReplaySafety.safe);
      expect(inspection.requiresConfirmation, isFalse);
      final admission = service.admitReplacement(
        inspection: inspection,
        replacementRequestId: 'request-3',
        replacementText: 'second',
        action: 'retry',
      );
      expect(admission, isNotNull);
      expect(
        sessions.getMessages(sessionId).map((message) => message.content),
        ['first', 'first answer', 'second'],
      );
      expect(
        sessions
            .getMessages(sessionId, includeSuperseded: true)
            .map((message) => message.content),
        ['first', 'first answer', 'second', 'second answer', 'second'],
      );
    },
  );

  test('older user turn is rejected to preserve newer user-owned turns', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'first'),
      Message(role: MessageRole.assistant, content: 'first answer'),
      user('request-2', 'second'),
    ]);
    final service = TurnReplayService(
      sessionManager: sessions,
      persistedState: runtime,
    );

    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-1',
    );

    expect(
      inspection.failure,
      TurnReplayInspectionFailure.targetIsNotLatestTurn,
    );
    expect(
      service.admitReplacement(
        inspection: inspection,
        replacementRequestId: 'request-3',
        replacementText: 'should not land',
        action: 'retry',
      ),
      isNull,
    );
    expect(sessions.getMessages(sessionId), hasLength(3));
  });

  test('unsafe tool metadata requires confirmation', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-tool', 'change the file'),
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(id: 'tool-1', name: 'file_edit', arguments: const {}),
        ],
      ),
      Message(role: MessageRole.tool, toolCallId: 'tool-1', content: 'done'),
    ]);
    final now = DateTime.now().toUtc();
    runtime.workItems.insertWorkItem(
      SessionWorkItem(
        workItemId: 'work-1',
        sessionId: sessionId,
        requestId: 'request-tool',
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
    final service = TurnReplayService(
      sessionManager: sessions,
      persistedState: runtime,
    );

    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-tool',
    );

    expect(inspection.safety, TurnReplaySafety.unsafe);
    expect(inspection.requiresConfirmation, isTrue);
  });

  test('pending steers are not replay targets', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'root'),
      Message(role: MessageRole.assistant, content: 'working'),
    ]);
    runtime.pendingInputs.insertPending(
      sessionId: sessionId,
      requestId: 'steer-pending',
      runId: 'run-1',
      generation: 1,
      text: 'nudge',
      receivedAt: DateTime.utc(2026, 8, 30),
    );
    final service = TurnReplayService(
      sessionManager: sessions,
      persistedState: runtime,
    );

    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'steer-pending',
      targetMessageId: 'missing-message',
      targetTurnId: 'missing-turn',
      expectedHistoryRevision: 1,
    );
    expect(
      inspection.failure,
      TurnReplayInspectionFailure.targetNotReplayableInput,
    );
    expect(sessions.getMessages(sessionId), hasLength(2));
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
  });

  test('steer user records are not replay targets', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'root'),
      Message(role: MessageRole.assistant, content: 'working'),
      Message(
        role: MessageRole.user,
        content: 'nudge',
        metadata: const {'steer': true, 'request_id': 'steer-1'},
      ),
    ]);
    final stored = sessions.getMessages(sessionId);
    final root = stored.first;
    final service = TurnReplayService(sessionManager: sessions);

    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'steer-1',
      targetMessageId: stored.last.metadata?['message_id']?.toString(),
      targetTurnId: stored.last.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    expect(
      inspection.failure,
      TurnReplayInspectionFailure.targetNotReplayableInput,
    );
    expect(sessions.getMessages(sessionId), hasLength(3));

    final rootInspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-1',
      targetMessageId: root.metadata?['message_id']?.toString(),
      targetTurnId: root.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    expect(rootInspection.canReplay, isTrue);
    expect(rootInspection.containsSteers, isTrue);

    final admission = service.admitReplacement(
      inspection: rootInspection,
      replacementRequestId: 'request-2',
      replacementText: 'root',
      action: 'retry',
    );
    expect(admission, isNotNull);
    final active = sessions.getMessages(sessionId);
    expect(active, hasLength(1));
    expect(active.single.content, 'root');
    expect(active.single.metadata?['request_id'], 'request-2');
    expect(active.any(MessageHistoryIdentity.isSteer), isFalse);
    final storedAll = sessions.getMessages(sessionId, includeSuperseded: true);
    expect(storedAll.where(MessageHistoryIdentity.isSteer), isNotEmpty);
    expect(
      storedAll
          .where(MessageHistoryIdentity.isSteer)
          .every(
            (message) => message.metadata?['history_status'] == 'superseded',
          ),
      isTrue,
    );
  });

  test('admitReplacement is atomic and keeps superseded rows', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'first'),
      Message(role: MessageRole.assistant, content: 'first answer'),
    ]);
    final stored = sessions.getMessages(sessionId);
    final service = TurnReplayService(sessionManager: sessions);
    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-1',
      targetMessageId: stored.first.metadata?['message_id']?.toString(),
      targetTurnId: stored.first.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    final admission = service.admitReplacement(
      inspection: inspection,
      replacementRequestId: 'request-2',
      replacementText: 'retry first',
      action: 'retry',
    );
    expect(admission, isNotNull);
    expect(admission!.historyRevision, 2);
    expect(sessions.getSession(sessionId)!.historyRevision, 2);
    final active = sessions.getMessages(sessionId);
    expect(active, hasLength(1));
    expect(active.single.content, 'retry first');
    expect(active.single.metadata?['request_id'], 'request-2');
    expect(
      active.single.metadata?['message_id'],
      isNot(stored.first.metadata?['message_id']),
    );
    expect(
      active.single.metadata?['turn_id'],
      isNot(stored.first.metadata?['turn_id']),
    );
    expect(
      sessions.getMessages(sessionId, includeSuperseded: true),
      hasLength(3),
    );
    expect(
      sessions
          .getMessages(sessionId, includeSuperseded: true)
          .where(
            (message) =>
                message.metadata?['history_status'] == 'superseded' &&
                message.content == 'first',
          ),
      isNotEmpty,
    );

    final stale = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-2',
      targetMessageId: active.single.metadata?['message_id']?.toString(),
      targetTurnId: active.single.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    expect(stale.failure, TurnReplayInspectionFailure.historyRevisionMismatch);
  });

  test('missing tool safety metadata is fail-closed as unknown', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-tool', 'use a tool'),
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(id: 'tool-1', name: 'unknown', arguments: const {}),
        ],
      ),
    ]);
    final service = TurnReplayService(
      sessionManager: sessions,
      persistedState: runtime,
    );

    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-tool',
    );

    expect(inspection.safety, TurnReplaySafety.unknown);
    expect(inspection.requiresConfirmation, isTrue);
  });

  test('embedded steer_messages require steer-drop confirmation', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-root', 'please wait'),
      Message(
        role: MessageRole.tool,
        content: 'result',
        toolCallId: 'call-1',
        metadata: const {
          'steer_messages': [
            {'text': 'keep going', 'request_id': 'steer-1'},
          ],
        },
      ),
    ]);
    final stored = sessions.getMessages(sessionId);
    final inspection = TurnReplayService(sessionManager: sessions).inspect(
      sessionId: sessionId,
      targetRequestId: 'request-root',
      targetMessageId: stored.first.metadata?['message_id']?.toString(),
      targetTurnId: stored.first.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    expect(inspection.canReplay, isTrue);
    expect(inspection.containsSteers, isTrue);
  });

  test('embedded steer identity is rejected as non-replayable input', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-root', 'please wait'),
      Message(
        role: MessageRole.tool,
        content: 'result',
        toolCallId: 'call-1',
        metadata: const {
          'steer_messages': [
            {'text': 'keep going', 'request_id': 'steer-1'},
          ],
        },
      ),
    ]);
    final stored = sessions.getMessages(sessionId);
    final steer = Map<String, dynamic>.from(
      (stored.last.metadata?['steer_messages'] as List).single as Map,
    );

    final inspection = TurnReplayService(sessionManager: sessions).inspect(
      sessionId: sessionId,
      targetRequestId: 'steer-1',
      targetMessageId: steer['message_id']?.toString(),
      targetTurnId: steer['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );

    expect(
      inspection.failure,
      TurnReplayInspectionFailure.targetNotReplayableInput,
    );
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
    expect(sessions.getMessages(sessionId), hasLength(2));
  });

  test('CAS mismatch rolls back and keeps the original turn active', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'keep me'),
      Message(role: MessageRole.assistant, content: 'answer'),
    ]);
    final original = sessions.getMessages(sessionId);
    final rejected = sessions.commitSoftRewindAdmission(
      sessionId: sessionId,
      expectedHistoryRevision: 99,
      targetMessageId: original.first.metadata?['message_id']?.toString() ?? '',
      targetTurnId: original.first.metadata?['turn_id']?.toString() ?? '',
      targetRequestId: 'request-1',
      replacement: user('request-2', 'should not land'),
    );
    expect(rejected, isNull);
    expect(sessions.getSession(sessionId)!.historyRevision, 1);
    final stillActive = sessions.getMessages(sessionId);
    expect(stillActive, hasLength(2));
    expect(stillActive.first.content, 'keep me');
    expect(
      stillActive.first.metadata?['message_id'],
      original.first.metadata?['message_id'],
    );
  });

  test('mutation failure rolls back replacement and supersession', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'keep me'),
      Message(role: MessageRole.assistant, content: 'answer'),
    ]);
    final original = sessions.getMessages(sessionId);
    final service = TurnReplayService(sessionManager: sessions);
    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-1',
      targetMessageId: original.first.metadata?['message_id']?.toString(),
      targetTurnId: original.first.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    state.db.execute('''
      CREATE TRIGGER reject_replay_supersession
      BEFORE UPDATE OF history_status ON messages
      WHEN NEW.history_status = 'superseded'
      BEGIN
        SELECT RAISE(ABORT, 'forced replay rollback');
      END;
    ''');

    expect(
      () => service.admitReplacement(
        inspection: inspection,
        replacementRequestId: 'request-2',
        replacementText: 'must roll back',
        action: 'retry',
      ),
      throwsA(anything),
    );

    expect(sessions.getSession(sessionId)!.historyRevision, 1);
    final active = sessions.getMessages(sessionId);
    expect(active.map((message) => message.content), ['keep me', 'answer']);
    expect(
      sessions.getMessages(sessionId, includeSuperseded: true),
      hasLength(2),
    );
  });

  test('in-transaction revalidation keeps a newer root active', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-1', 'first'),
      Message(role: MessageRole.assistant, content: 'first answer'),
    ]);
    final stored = sessions.getMessages(sessionId);
    final service = TurnReplayService(sessionManager: sessions);
    final inspection = service.inspect(
      sessionId: sessionId,
      targetRequestId: 'request-1',
      targetMessageId: stored.first.metadata?['message_id']?.toString(),
      targetTurnId: stored.first.metadata?['turn_id']?.toString(),
      expectedHistoryRevision: 1,
    );
    expect(inspection.canReplay, isTrue);
    sessions.saveSessionHistory(sessionId, [
      ...sessions.getMessages(sessionId),
      user('request-2', 'newer'),
    ]);
    expect(
      service.admitReplacement(
        inspection: inspection,
        replacementRequestId: 'request-3',
        replacementText: 'should not land',
        action: 'retry',
      ),
      isNull,
    );
    expect(sessions.getSession(sessionId)!.historyRevision, 2);
    expect(sessions.getMessages(sessionId).map((message) => message.content), [
      'first',
      'first answer',
      'newer',
    ]);
  });

  test('unsafe tools that precede a steer still require confirmation', () {
    sessions.saveSessionHistory(sessionId, [
      user('request-root', 'change the file then wait'),
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(id: 'tool-1', name: 'file_edit', arguments: const {}),
        ],
      ),
      Message(role: MessageRole.tool, toolCallId: 'tool-1', content: 'done'),
      Message(
        role: MessageRole.user,
        content: 'nudge',
        metadata: const {'steer': true, 'request_id': 'steer-1'},
      ),
    ]);
    final now = DateTime.now().toUtc();
    runtime.workItems.insertWorkItem(
      SessionWorkItem(
        workItemId: 'work-root',
        sessionId: sessionId,
        requestId: 'request-root',
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
    final stored = sessions.getMessages(sessionId);
    final inspection =
        TurnReplayService(
          sessionManager: sessions,
          persistedState: runtime,
        ).inspect(
          sessionId: sessionId,
          targetRequestId: 'request-root',
          targetMessageId: stored.first.metadata?['message_id']?.toString(),
          targetTurnId: stored.first.metadata?['turn_id']?.toString(),
          expectedHistoryRevision: 1,
        );
    expect(inspection.canReplay, isTrue);
    expect(inspection.containsSteers, isTrue);
    expect(inspection.safety, TurnReplaySafety.unsafe);
    expect(inspection.requiresConfirmation, isTrue);
  });
}
