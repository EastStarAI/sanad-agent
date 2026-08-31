import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/llm_finish_reason.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/runtime/pending_input_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_snapshot_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/runtime/session_fork_service.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late SessionManager sessions;
  late SessionForkService fork;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    fork = SessionForkService(sessionManager: sessions);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
  });

  String seedThreeTurns() {
    final session = sessions.createSession('model');
    sessions.updateSessionTitle(session.sessionId, 'Refactor auth');
    sessions.saveSessionHistory(session.sessionId, [
      _user('m-u1', 'turn-1', 'one'),
      _assistant('m-a1', 'turn-1', 'first'),
      _user('m-u2', 'turn-2', 'two'),
      Message(
        role: MessageRole.assistant,
        content: '',
        finishReason: LLMFinishReason.toolCalls,
        toolCalls: [
          ToolCall(id: 'call-1', name: 'read', arguments: const {'path': 'a'}),
        ],
        metadata: const {'message_id': 'm-tool-ask', 'turn_id': 'turn-2'},
      ),
      Message(
        role: MessageRole.tool,
        content: 'file contents',
        toolCallId: 'call-1',
        metadata: const {'message_id': 'm-tool-res', 'turn_id': 'turn-2'},
      ),
      Message(
        role: MessageRole.assistant,
        content: 'second final',
        reasoning: 'checked the file',
        finishReason: LLMFinishReason.stop,
        providerState: const LLMProviderState(
          namespace: 'test',
          data: {'cursor': 'abc'},
        ),
        metadata: {
          'message_id': 'm-a2',
          'turn_id': 'turn-2',
          'model_step_id': 'step-2',
          'provider_blob': 'blob-' * 800,
        },
      ),
      _user('m-u3', 'turn-3', 'three'),
      _assistant('m-a3', 'turn-3', 'third'),
    ]);
    return session.sessionId;
  }

  test('copies the active prefix through the target turn only', () {
    final parentId = seedThreeTurns();
    final result = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-1',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );

    expect(result.outcome, SessionForkOutcome.accepted);
    final child = result.child!;
    expect(child.title, '(1) Refactor auth');
    expect(child.lineageId, parentId);
    expect(child.parentSessionId, parentId);
    expect(child.forkSequence, 1);
    expect(child.historyRevision, 0);
    expect(
      SessionExecutionSnapshotRepository(
        state,
      ).findPersistedSnapshot(child.sessionId),
      isNull,
    );
    expect(child.messages, hasLength(6));
    expect(child.messages.last.content, 'second final');
    expect(child.messages.last.reasoning, 'checked the file');
    expect(child.messages.last.providerState?.data['cursor'], 'abc');
    expect(child.messages.last.metadata?['model_step_id'], 'step-2');
    expect(
      (child.messages.last.metadata?['provider_blob'] as String).length,
      greaterThan(1000),
    );
    expect(
      MessageHistoryIdentity.read(child.messages.last).originMessageId,
      'm-a2',
    );
    expect(
      MessageHistoryIdentity.read(child.messages.last).messageId,
      isNot('m-a2'),
    );

    final parent = sessions.getSession(parentId)!;
    expect(parent.messages, hasLength(8));
    expect(parent.title, 'Refactor auth');

    final childTool = child.messages
        .where((message) => message.role == MessageRole.tool)
        .single;
    final childAsk = child.messages.firstWhere(
      (message) => message.toolCalls?.isNotEmpty == true,
    );
    expect(childTool.toolCallId, childAsk.toolCalls!.single.id);
    expect(childTool.toolCallId, isNot('call-1'));
  });

  test('same request_id returns the existing child', () {
    final parentId = seedThreeTurns();
    final first = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-1',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    final second = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-1',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    expect(second.outcome, SessionForkOutcome.alreadyExists);
    expect(second.child!.sessionId, first.child!.sessionId);
    expect(sessions.getAllSessions(), hasLength(2));
  });

  test('same request_id with a different target is invalid', () {
    final parentId = seedThreeTurns();
    final first = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-1',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    final conflicting = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-1',
      targetMessageId: 'm-a1',
      targetTurnId: 'turn-1',
    );

    expect(first.outcome, SessionForkOutcome.accepted);
    expect(conflicting.outcome, SessionForkOutcome.invalidRequest);
    expect(conflicting.child, isNull);
    expect(sessions.getAllSessions(), hasLength(2));
  });

  test('branch-from-branch keeps lineage and increments sequence', () {
    final parentId = seedThreeTurns();
    final child = fork
        .fork(
          sourceSessionId: parentId,
          requestId: 'fork-1',
          targetMessageId: 'm-a2',
          targetTurnId: 'turn-2',
        )
        .child!;
    final grandchild = fork.fork(
      sourceSessionId: child.sessionId,
      requestId: 'fork-2',
      targetMessageId: MessageHistoryIdentity.read(
        child.messages.last,
      ).messageId,
      targetTurnId: MessageHistoryIdentity.read(child.messages.last).turnId,
    );
    expect(grandchild.outcome, SessionForkOutcome.accepted);
    expect(grandchild.child!.lineageId, parentId);
    expect(grandchild.child!.forkSequence, 2);
    expect(grandchild.child!.title, '(2) Refactor auth');
    expect(grandchild.child!.parentSessionId, child.sessionId);
  });

  test('rejects a user row and leaves history unchanged', () {
    final parentId = seedThreeTurns();
    final result = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-bad',
      targetMessageId: 'm-u2',
      targetTurnId: 'turn-2',
    );
    expect(result.outcome, SessionForkOutcome.targetNotForkable);
    expect(result.child, isNull);
    expect(sessions.getAllSessions(), hasLength(1));
    expect(sessions.getSession(parentId)!.messages, hasLength(8));
  });

  test('rejects a superseded final answer', () {
    final parentId = seedThreeTurns();
    state.db.execute(
      "UPDATE messages SET history_status = 'superseded' WHERE message_id = ?",
      ['m-a2'],
    );
    final result = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-superseded',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    expect(result.outcome, SessionForkOutcome.targetNotForkable);
    expect(sessions.getAllSessions(), hasLength(1));
  });

  test('rejects a steer-superseded thought row', () {
    final session = sessions.createSession('model');
    sessions.saveSessionHistory(session.sessionId, [
      _user('m-u1', 'turn-1', 'one'),
      Message(
        role: MessageRole.assistant,
        content: 'pre-steer thought',
        finishReason: LLMFinishReason.stop,
        metadata: const {
          'message_id': 'm-thought',
          'turn_id': 'turn-1',
          'superseded_by_steer': true,
        },
      ),
      _assistant('m-a1', 'turn-1', 'final after steer'),
    ]);
    final result = fork.fork(
      sourceSessionId: session.sessionId,
      requestId: 'fork-thought',
      targetMessageId: 'm-thought',
      targetTurnId: 'turn-1',
    );
    expect(result.outcome, SessionForkOutcome.targetNotForkable);
    expect(sessions.getAllSessions(), hasLength(1));
  });

  test('rejects an incomplete assistant row', () {
    final session = sessions.createSession('model');
    sessions.saveSessionHistory(session.sessionId, [
      _user('m-u1', 'turn-1', 'one'),
      Message(
        role: MessageRole.assistant,
        content: 'partial',
        finishReason: LLMFinishReason.incomplete,
        metadata: const {'message_id': 'm-partial', 'turn_id': 'turn-1'},
      ),
    ]);
    final result = fork.fork(
      sourceSessionId: session.sessionId,
      requestId: 'fork-incomplete',
      targetMessageId: 'm-partial',
      targetTurnId: 'turn-1',
    );
    expect(result.outcome, SessionForkOutcome.targetNotForkable);
    expect(sessions.getAllSessions(), hasLength(1));
  });

  test('rejects unknown-finish assistant text without a terminal marker', () {
    final session = sessions.createSession('model');
    sessions.saveSessionHistory(session.sessionId, [
      _user('m-u1', 'turn-1', 'one'),
      Message(
        role: MessageRole.assistant,
        content: 'ambiguous persisted chunk',
        metadata: const {'message_id': 'm-unknown', 'turn_id': 'turn-1'},
      ),
    ]);

    final result = fork.fork(
      sourceSessionId: session.sessionId,
      requestId: 'fork-unknown',
      targetMessageId: 'm-unknown',
      targetTurnId: 'turn-1',
    );

    expect(result.outcome, SessionForkOutcome.targetNotForkable);
    expect(sessions.getAllSessions(), hasLength(1));
  });

  test('two forks in the same lineage get unique sequences and titles', () {
    final parentId = seedThreeTurns();
    final first = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-a',
      targetMessageId: 'm-a1',
      targetTurnId: 'turn-1',
    );
    final second = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-b',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    expect(first.child!.title, '(1) Refactor auth');
    expect(second.child!.title, '(2) Refactor auth');
    expect(first.child!.forkSequence, 1);
    expect(second.child!.forkSequence, 2);
    expect(first.child!.sessionId, isNot(second.child!.sessionId));
  });

  test('renaming the parent does not change later fork titles', () {
    final parentId = seedThreeTurns();
    fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-1',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    sessions.updateSessionTitle(parentId, 'Renamed later');
    final second = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-2',
      targetMessageId: 'm-a1',
      targetTurnId: 'turn-1',
    );
    expect(second.child!.title, '(2) Refactor auth');
    expect(second.child!.lineageBaseTitle, 'Refactor auth');
  });

  test('parent and child continue independently after fork', () {
    final parentId = seedThreeTurns();
    final child = fork
        .fork(
          sourceSessionId: parentId,
          requestId: 'fork-1',
          targetMessageId: 'm-a2',
          targetTurnId: 'turn-2',
        )
        .child!;

    sessions.saveSessionHistory(parentId, [
      ...sessions.getMessages(parentId),
      _user('m-u4', 'turn-4', 'parent only'),
    ]);
    sessions.saveSessionHistory(child.sessionId, [
      ...sessions.getMessages(child.sessionId),
      _user('m-u-child', 'turn-child', 'child only'),
    ]);

    expect(
      sessions.getMessages(parentId).map((message) => message.content),
      contains('parent only'),
    );
    expect(
      sessions.getMessages(parentId).map((message) => message.content),
      isNot(contains('child only')),
    );
    expect(
      sessions.getMessages(child.sessionId).map((message) => message.content),
      contains('child only'),
    );
    expect(
      sessions.getMessages(child.sessionId).map((message) => message.content),
      isNot(contains('parent only')),
    );
    expect(
      sessions.getMessages(child.sessionId).map((message) => message.content),
      isNot(contains('three')),
    );
  });

  test('does not copy queued work or pending steers onto the child', () {
    final parentId = seedThreeTurns();
    SessionWorkItemRepository(state).enqueueWorkItem(
      workItemId: 'queued-parent',
      sessionId: parentId,
      requestId: 'queued-req',
      payload: const {'message': 'later turn waiting'},
    );
    PendingInputRepository(state).insertPending(
      sessionId: parentId,
      requestId: 'steer-req',
      runId: 'run-1',
      generation: 1,
      text: 'pending steer text',
      receivedAt: DateTime.utc(2026, 8, 30),
    );

    final child = fork
        .fork(
          sourceSessionId: parentId,
          requestId: 'fork-1',
          targetMessageId: 'm-a2',
          targetTurnId: 'turn-2',
        )
        .child!;

    expect(
      SessionWorkItemRepository(state).findQueuedWorkItems(parentId),
      hasLength(1),
    );
    expect(
      SessionWorkItemRepository(state).findQueuedWorkItems(child.sessionId),
      isEmpty,
    );
    expect(
      PendingInputRepository(state).findForSession(parentId),
      hasLength(1),
    );
    expect(
      PendingInputRepository(state).findForSession(child.sessionId),
      isEmpty,
    );
    expect(
      SessionExecutionSnapshotRepository(
        state,
      ).findPersistedSnapshot(child.sessionId),
      isNull,
    );
  });

  test('reloading the database restores forked lineage and copied history', () {
    final parentId = seedThreeTurns();
    final childId = fork
        .fork(
          sourceSessionId: parentId,
          requestId: 'fork-1',
          targetMessageId: 'm-a2',
          targetTurnId: 'turn-2',
        )
        .child!
        .sessionId;

    SessionManager.resetForTesting();
    sessions = SessionManager();
    final restored = sessions.getSession(childId)!;
    expect(restored.lineageId, parentId);
    expect(restored.forkSequence, 1);
    expect(restored.messages, hasLength(6));
    expect(restored.messages.last.content, 'second final');
    expect(restored.messages.last.reasoning, 'checked the file');
    expect(restored.messages.last.providerState?.data['cursor'], 'abc');
    expect(
      MessageHistoryIdentity.read(restored.messages.last).originMessageId,
      'm-a2',
    );
  });

  test('rolls back the child when copied history cannot commit', () {
    final parentId = seedThreeTurns();
    state.db.execute('''
      CREATE TRIGGER fail_fork_copy AFTER INSERT ON messages
      WHEN NEW.session_id != '$parentId'
      BEGIN
        SELECT RAISE(ABORT, 'fork copy failed');
      END;
    ''');

    final result = fork.fork(
      sourceSessionId: parentId,
      requestId: 'fork-fail',
      targetMessageId: 'm-a2',
      targetTurnId: 'turn-2',
    );
    expect(result.outcome, SessionForkOutcome.failed);
    expect(sessions.getAllSessions(), hasLength(1));
    expect(sessions.getSession(parentId)!.messages, hasLength(8));
  });
}

Message _user(String id, String turnId, String content) {
  return Message(
    role: MessageRole.user,
    content: content,
    metadata: {
      'message_id': id,
      'turn_id': turnId,
      'request_id': 'req-$id',
      'input_kind': MessageHistoryIdentity.rootTurn,
    },
  );
}

Message _assistant(String id, String turnId, String content) {
  return Message(
    role: MessageRole.assistant,
    content: content,
    finishReason: LLMFinishReason.stop,
    metadata: {'message_id': id, 'turn_id': turnId},
  );
}
