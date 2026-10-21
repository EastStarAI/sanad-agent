import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart' show SessionDB;
import 'package:sanad_agent/evolution/db/session_fork_commit_repository.dart';
import 'package:sanad_agent/evolution/db/session_message_repository.dart';
import 'package:sanad_agent/evolution/db/session_repository.dart';
import 'package:sanad_agent/evolution/db/suspended_checkpoint_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-session-repo-decomp-test',
    );
    setSanadHomeOverride(tempDir.path);
    state = AgentStateDatabase();
  });

  tearDown(() async {
    state.dispose();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
  });

  test('SessionRepository performs session lifecycle and metadata ownership directly', () {
    final messages = SessionMessageRepository(state);
    final repo = SessionRepository(state, messages);

    final session = SessionState(
      sessionId: 'decomp-sess-1',
      model: 'model-decomp',
      title: 'Decomp Title',
      titleStatus: SessionTitleStatus.pending,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    repo.saveSession(session);

    final record = repo.getSessionRecord('decomp-sess-1');
    expect(record, isNotNull);
    expect(record!.sessionId, 'decomp-sess-1');
    expect(record.model, 'model-decomp');

    final updated = repo.finalizePendingSessionTitle(
      'decomp-sess-1',
      expectedTitle: 'Decomp Title',
      title: 'Finalized Title',
    );
    expect(updated, isTrue);

    final afterTitle = repo.getSessionRecord('decomp-sess-1');
    expect(afterTitle!.title, 'Finalized Title');
    expect(afterTitle.titleStatus, SessionTitleStatus.finalized);

    repo.saveSessionMetadata('decomp-sess-1', {'key': 'val-123'});
    final meta = repo.getSessionMetadata('decomp-sess-1');
    expect(meta, {'key': 'val-123'});

    final ws = repo.createOrGetWorkspace(
      path: '/path/to/decomp',
      source: 'local',
      displayName: 'DecompWS',
    );
    expect(ws['display_name'], 'DecompWS');
    expect(repo.getWorkspaceByPath('/path/to/decomp')?['id'], ws['id']);
  });

  test('SessionMessageRepository performs message append, history projection, and tool call lookup directly', () {
    final repo = SessionMessageRepository(state);
    final sessions = SessionRepository(state, repo);
    sessions.saveSession(
      SessionState(
        sessionId: 'decomp-sess-2',
        model: 'model-decomp',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final toolCall = ToolCall(
      id: 'call-decomp-99',
      name: 'fetch_data',
      arguments: {'query': 'status'},
    );
    final messages = [
      Message(role: MessageRole.user, content: 'run tool'),
      Message(
        role: MessageRole.assistant,
        content: 'calling tool',
        toolCalls: [toolCall],
      ),
    ];
    repo.replaceMessages('decomp-sess-2', messages);

    final active = repo.getMessages('decomp-sess-2');
    expect(active.length, 2);
    expect(active.first.content, 'run tool');
    expect(active.last.toolCalls!.single.id, 'call-decomp-99');

    final page = repo.getPersistedMessagePage('decomp-sess-2', limit: 10);
    expect(page.messages.length, 2);
    expect(page.hasMore, isFalse);

    final foundTool = repo.findOriginatingToolCall(
      'decomp-sess-2',
      toolCallId: 'call-decomp-99',
    );
    expect(foundTool, isNotNull);
    expect(foundTool!.toolCall.name, 'fetch_data');
    expect(foundTool.toolCall.arguments, {'query': 'status'});
  });

  test('ScheduledTaskRepository manages scheduled tasks directly', () {
    final repo = ScheduledTaskRepository(state);

    final runAt = DateTime.utc(2026, 5, 1, 12, 0, 0);
    repo.saveScheduledTask(
      'task-decomp-1',
      'maintenance_run',
      runAt,
      'decomp-sess-3',
    );

    final tasks = repo.getAllScheduledTasks();
    expect(tasks.any((t) => t['id'] == 'task-decomp-1'), isTrue);
    final match = tasks.firstWhere((t) => t['id'] == 'task-decomp-1');
    expect(match['task'], 'maintenance_run');
    expect(match['session_id'], 'decomp-sess-3');

    repo.deleteScheduledTask('task-decomp-1');
    final afterDelete = repo.getAllScheduledTasks();
    expect(afterDelete.any((t) => t['id'] == 'task-decomp-1'), isFalse);
  });

  test('SuspendedCheckpointRepository manages suspended checkpoints and decision claims directly', () {
    final repo = SuspendedCheckpointRepository(state);

    final checkpoint = SuspendedCheckpoint(
      checkpointId: 'ckpt-decomp-1',
      sessionId: 'decomp-sess-4',
      requestId: 'req-decomp-1',
      toolCallId: 'tool-call-decomp-1',
      toolName: 'shell_exec',
      status: 'awaiting_permission',
      toolArguments: {'command': 'ls'},
      permissionPayload: {'type': 'shell'},
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    repo.saveSuspendedCheckpoint(checkpoint);

    final fetched = repo.getSuspendedCheckpointByRequestId('req-decomp-1');
    expect(fetched, isNotNull);
    expect(fetched!.toolName, 'shell_exec');
    expect(fetched.status, 'awaiting_permission');

    final claimed = repo.claimSuspendedCheckpointDecision(
      requestId: 'req-decomp-1',
      status: 'approved',
    );
    expect(claimed, isTrue);

    final afterClaim = repo.getSuspendedCheckpointByRequestId('req-decomp-1');
    expect(afterClaim!.status, 'approved');

    repo.deleteSuspendedCheckpointByRequestId('req-decomp-1');
    expect(repo.getSuspendedCheckpointByRequestId('req-decomp-1'), isNull);
  });

  test('SessionForkCommitRepository manages root-user, soft-rewind, and fork commits directly', () {
    final messages = SessionMessageRepository(state);
    final sessions = SessionRepository(state, messages);
    final forkCommits = SessionForkCommitRepository(
      state: state,
      sessions: sessions,
      messages: messages,
    );

    sessions.saveSession(
      SessionState(
        sessionId: 'decomp-parent',
        model: 'model-1',
        title: 'Parent Session',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final rootMsg = Message(
      role: MessageRole.user,
      content: 'Hello initial root',
      metadata: {'request_id': 'req-root-1'},
    );
    final rootCommit = forkCommits.appendRootUserMessage('decomp-parent', rootMsg);
    expect(rootCommit.inserted, isTrue);
    expect(rootCommit.historyRevision, greaterThanOrEqualTo(1));

    final assistantMsg = Message(
      role: MessageRole.assistant,
      content: 'Here is the answer',
      metadata: {'terminal_work_item_id': 'work-1'},
    );
    messages.replaceMessages('decomp-parent', [
      rootCommit.message,
      assistantMsg,
    ]);

    final parentMsgs = messages.getMessages('decomp-parent');
    final rootIdentity = MessageHistoryIdentity.read(parentMsgs.first);
    final assistantIdentity = MessageHistoryIdentity.read(parentMsgs.last);

    final forkResult = forkCommits.commitFork(
      sourceSessionId: 'decomp-parent',
      requestId: 'fork-req-1',
      targetMessageId: assistantIdentity.messageId,
      targetTurnId: assistantIdentity.turnId,
    );
    expect(forkResult.outcome, SessionForkOutcome.accepted);
    expect(forkResult.child, isNotNull);
    expect(forkResult.child!.parentSessionId, 'decomp-parent');

    final replacementUser = Message(
      role: MessageRole.user,
      content: 'Rewritten root turn',
      metadata: {'request_id': 'req-root-replacement'},
    );
    final parentState = sessions.getSessionRecord('decomp-parent')!;
    final rewindCommit = forkCommits.commitSoftRewindAdmission(
      sessionId: 'decomp-parent',
      expectedHistoryRevision: parentState.historyRevision,
      targetMessageId: rootIdentity.messageId,
      targetTurnId: rootIdentity.turnId,
      targetRequestId: 'req-root-1',
      replacement: replacementUser,
    );
    expect(rewindCommit, isNotNull);
    expect(rewindCommit!.historyRevision, parentState.historyRevision + 1);
  });

  test('SessionDB facade wires one owner per responsibility over one shared connection', () {
    final facade = SessionDB.fromState(state);

    // A bypassed or replaced owner would break these identity bindings.
    expect(facade.sessionRepository, same(facade.sessions));
    expect(facade.messageRepository, same(facade.messages));
    expect(facade.scheduledTaskRepository, same(facade.scheduledTasks));
    expect(
      facade.suspendedCheckpointRepository,
      same(facade.suspendedCheckpoints),
    );
    expect(facade.forkCommitRepository, same(facade.forkCommits));

    // Ownership is real: a write through one owner is visible through the
    // facade and through an independently constructed owner on the same
    // injected connection.
    facade.sessions.saveSession(
      SessionState(
        sessionId: 'decomp-facade',
        model: 'model-facade',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    expect(facade.getSessionRecord('decomp-facade'), isNotNull);
    expect(
      SessionRepository(state, facade.messages).getSessionRecord(
        'decomp-facade',
      ),
      isNotNull,
    );

    // `fromState` borrows the caller's connection and must never close it.
    facade.dispose();
    expect(state.db.select('SELECT 1').isNotEmpty, isTrue);
  });
}
