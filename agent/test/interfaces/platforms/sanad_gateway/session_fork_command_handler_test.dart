import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/llm_finish_reason.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_snapshot_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_fork_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late SessionManager sessions;
  late SessionForkCommandHandler handler;
  late String sessionId;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    handler = SessionForkCommandHandler(
      sessionManager: sessions,
      bridge: _EnvelopeBridge(),
    );
    final session = sessions.createSession('model');
    sessionId = session.sessionId;
    sessions.updateSessionTitle(sessionId, 'Refactor auth');
    sessions.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {
          'message_id': 'm-user',
          'turn_id': 'turn-1',
          'request_id': 'req-1',
          'input_kind': MessageHistoryIdentity.rootTurn,
        },
      ),
      Message(
        role: MessageRole.assistant,
        content: 'hi',
        finishReason: LLMFinishReason.stop,
        metadata: const {'message_id': 'm-final', 'turn_id': 'turn-1'},
      ),
    ]);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
  });

  CanonicalEvent command({
    String? requestId,
    String? targetMessageId,
    String? targetTurnId,
    String? sourceSessionId,
  }) {
    return CanonicalEvent(
      type: CanonicalEventTypes.sessionFork,
      sessionId: sourceSessionId ?? sessionId,
      payload: {
        'session_id': sourceSessionId ?? sessionId,
        'request_id': ?requestId,
        'target_message_id': ?targetMessageId,
        'target_turn_id': ?targetTurnId,
      },
    );
  }

  test(
    'omitted identity is invalid_request and does not create a session',
    () async {
      final envelopes = <Map<String, dynamic>>[];
      await handler.handle(command(requestId: 'fork-1'), (envelope) async {
        envelopes.add(envelope);
      });
      expect(envelopes.single['payload']['outcome'], 'invalid_request');
      expect(sessions.getAllSessions(), hasLength(1));
    },
  );

  test('accepted fork returns an idle child summary', () async {
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'fork-1',
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
      ),
      (envelope) async {
        envelopes.add(envelope);
      },
    );
    final payload = envelopes.single['payload'] as Map<String, dynamic>;
    expect(payload['outcome'], 'accepted');
    expect(payload['fork_sequence'], 1);
    expect((payload['child'] as Map)['title'], '(1) Refactor auth');
    expect((payload['child'] as Map)['history_revision'], 0);
    expect(sessions.getAllSessions(), hasLength(2));
    final childId = (payload['child'] as Map)['session_id'] as String;
    expect(
      sessions.getAllSessions().first.sessionId,
      childId,
      reason: 'a newly created fork must lead the authoritative session list',
    );
    expect(
      SessionExecutionSnapshotRepository(state).findPersistedSnapshot(childId),
      isNull,
    );

    final historyEnvelope =
        SessionQueryHandler(
          sessionManager: sessions,
          bridge: _EnvelopeBridge(),
        ).buildHistoryEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: childId,
            payload: const {'request_id': 'history-1'},
          ),
        );
    final historyRows = (historyEnvelope['payload']['messages'] as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final forkRows = historyRows
        .where((row) => row['type'] == CanonicalEventTypes.sessionForked)
        .toList();
    expect(forkRows, hasLength(1));
    expect(forkRows.single['event_id'], 'fork_$childId');
    expect(forkRows.single['content'], 'Conversation forked');
    expect(historyRows.last, forkRows.single);
    expect(
      sessions
          .getMessages(childId)
          .where((message) => message.role == MessageRole.system),
      isEmpty,
      reason: 'the history-only fork marker must never enter model messages',
    );
  });

  test('missing source session is session_not_found', () async {
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'fork-missing-session',
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
        sourceSessionId: 'missing-session',
      ),
      (envelope) async {
        envelopes.add(envelope);
      },
    );
    expect(envelopes.single['payload']['outcome'], 'session_not_found');
    expect(sessions.getAllSessions(), hasLength(1));
  });

  test('repeating the same request_id is already_exists', () async {
    Future<Map<String, dynamic>> send() async {
      final envelopes = <Map<String, dynamic>>[];
      await handler.handle(
        command(
          requestId: 'fork-1',
          targetMessageId: 'm-final',
          targetTurnId: 'turn-1',
        ),
        (envelope) async => envelopes.add(envelope),
      );
      return envelopes.single['payload'] as Map<String, dynamic>;
    }

    final first = await send();
    final second = await send();
    expect(first['outcome'], 'accepted');
    expect(second['outcome'], 'already_exists');
    expect(
      (second['child'] as Map)['session_id'],
      (first['child'] as Map)['session_id'],
    );
    expect(sessions.getAllSessions(), hasLength(2));
  });

  test('superseded target is target_not_forkable', () async {
    state.db.execute(
      "UPDATE messages SET history_status = 'superseded' WHERE message_id = ?",
      ['m-final'],
    );
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'fork-superseded',
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'target_not_forkable');
    expect(sessions.getAllSessions(), hasLength(1));
  });

  test('missing target is target_not_found', () async {
    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      command(
        requestId: 'fork-missing',
        targetMessageId: 'missing',
        targetTurnId: 'turn-1',
      ),
      (envelope) async => envelopes.add(envelope),
    );
    expect(envelopes.single['payload']['outcome'], 'target_not_found');
    expect(sessions.getAllSessions(), hasLength(1));
  });
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
