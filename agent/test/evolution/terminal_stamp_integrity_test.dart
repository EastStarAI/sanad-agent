// Task 111 G2: a committed terminal stamp survives later session-history
// rewrites made from a runner's in-memory (or cached) copy of the history.

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late SessionManager sessions;
  late PersistedRuntimeStateRepository repo;

  setUp(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    repo = PersistedRuntimeStateRepository(state.db);
  });

  tearDown(() {
    SessionManager.resetForTesting();
    GetIt.I.reset();
  });

  /// Runs one turn through the same order the turn executor uses: the runner
  /// saves the reply with its statistics, then the owner commits the terminal.
  String commitTurn(String sessionId, {required String suffix}) {
    final item = repo.admitWorkItem(
      workItemId: 'w-$suffix',
      sessionId: sessionId,
      requestId: 'req-$suffix',
    );
    expect(
      repo.bindRunOwnership(
        sessionId: sessionId,
        workItemId: item.workItemId,
        runId: 'run-$suffix',
        generation: 1,
      ),
      isTrue,
    );
    final history = sessions.getSession(sessionId)!.messages.toList()
      ..add(
        Message(
          role: MessageRole.user,
          content: 'question $suffix',
          metadata: {'request_id': 'req-$suffix'},
        ),
      )
      ..add(
        Message(
          role: MessageRole.assistant,
          content: 'answer $suffix',
          metadata: {
            'run_id': 'run-$suffix',
            'usage': const {'input_tokens': 3, 'output_tokens': 5},
          },
        ),
      );
    sessions.saveSessionHistory(sessionId, history);
    final outcome = repo.commitTerminal(
      sessionId: sessionId,
      workItemId: item.workItemId,
      runId: 'run-$suffix',
      generation: 1,
      assistantResult: Message(
        role: MessageRole.assistant,
        content: 'answer $suffix',
        metadata: {'run_id': 'run-$suffix'},
      ),
    );
    expect(outcome, TerminalCommitOutcome.committed);
    return item.workItemId;
  }

  Message durableAnswer(String sessionId, String suffix) => sessions.db
      .getMessages(sessionId)
      .singleWhere(
        (m) => m.role == MessageRole.assistant && m.content == 'answer $suffix',
      );

  test('a reload after the terminal commit observes the stamp', () {
    final sessionId = sessions.createSession('test-model').sessionId;
    final workItemId = commitTurn(sessionId, suffix: 'a');

    final reloaded = sessions
        .getSession(sessionId)!
        .messages
        .singleWhere((m) => m.role == MessageRole.assistant);
    expect(reloaded.metadata?['terminal_work_item_id'], workItemId);
  });

  test('the next turn history rewrite keeps the previous terminal stamp', () {
    final sessionId = sessions.createSession('test-model').sessionId;
    final firstWorkItem = commitTurn(sessionId, suffix: 'a');
    final secondWorkItem = commitTurn(sessionId, suffix: 'b');

    final first = durableAnswer(sessionId, 'a');
    expect(first.metadata?['terminal_work_item_id'], firstWorkItem);
    expect(first.metadata?['terminal_generation'], 1);
    expect(first.metadata?['usage'], isNotNull);
    expect(
      durableAnswer(sessionId, 'b').metadata?['terminal_work_item_id'],
      secondWorkItem,
    );
  });

  test('a rewrite from a stale in-memory copy cannot erase the stamp', () {
    final sessionId = sessions.createSession('test-model').sessionId;
    // A runner that captured history before the commit still holds the
    // unstamped copy of the reply.
    final staleCopy = sessions.getSession(sessionId)!.messages.toList();
    final workItemId = commitTurn(sessionId, suffix: 'a');
    final unstampedRunnerHistory = sessions.db
        .getMessages(sessionId)
        .map(
          (m) => m.role == MessageRole.assistant
              ? m.copyWith(
                  metadata: Map<String, dynamic>.of(m.metadata!)
                    ..remove('terminal_work_item_id')
                    ..remove('terminal_generation'),
                )
              : m,
        )
        .toList();
    expect(staleCopy, isEmpty);

    sessions.saveSessionHistory(sessionId, unstampedRunnerHistory);

    final answer = durableAnswer(sessionId, 'a');
    expect(answer.metadata?['terminal_work_item_id'], workItemId);
    expect(answer.metadata?['terminal_generation'], 1);
  });
}
