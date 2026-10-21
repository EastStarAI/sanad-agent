import 'dart:convert';

import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

/// Task 117 (0P-F1): history rewrites align rows by `message_id` and keep
/// their SQLite row ids; only structural divergence re-inserts the suffix.
void main() {
  late AgentStateDatabase state;
  late SessionDB db;
  const sessionId = 's1';

  setUp(() {
    state = AgentStateDatabase.inMemory();
    db = SessionDB.fromState(state);
    final now = DateTime.utc(2026, 10, 21);
    db.saveSession(
      SessionState(
        sessionId: sessionId,
        model: 'model',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() {
    db.dispose();
    state.dispose();
  });

  List<({int id, String messageId, String status, String data})> rows({
    bool activeOnly = false,
  }) {
    return state.db
        .select(
          '''
          SELECT id, message_id, history_status, data FROM messages
          WHERE session_id = ?
          ${activeOnly ? "AND history_status = 'active'" : ''}
          ORDER BY id
          ''',
          [sessionId],
        )
        .map(
          (row) => (
            id: row['id'] as int,
            messageId: row['message_id'] as String,
            status: row['history_status'] as String,
            data: row['data'] as String,
          ),
        )
        .toList(growable: false);
  }

  int revision() => db.getSessionRecord(sessionId)!.historyRevision;

  List<Message> seedFive() {
    db.replaceMessages(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'u1',
        metadata: const {'request_id': 'r1'},
      ),
      Message(role: MessageRole.assistant, content: 'a1'),
      Message(role: MessageRole.user, content: 'u2'),
      Message(role: MessageRole.assistant, content: 'a2'),
      Message(role: MessageRole.user, content: 'u3'),
    ]);
    return db.getMessages(sessionId);
  }

  test('T1 middle-row content change keeps every row id and message_id', () {
    final loaded = seedFive();
    final before = rows();
    final revisionBefore = revision();

    final edited = List<Message>.of(loaded);
    edited[2] = edited[2].copyWith(content: 'u2 pruned');
    db.replaceMessages(sessionId, edited);

    final after = rows();
    expect(after.map((row) => row.id), before.map((row) => row.id));
    expect(
      after.map((row) => row.messageId),
      before.map((row) => row.messageId),
    );
    expect(jsonDecode(after[2].data)['content'], 'u2 pruned');
    // Untouched rows are not rewritten at all.
    for (final index in [0, 1, 3, 4]) {
      expect(after[index].data, before[index].data);
    }
    expect(revision(), revisionBefore + 1);
  });

  test('T1 in-memory rows without message_id still align by position', () {
    seedFive();
    final before = rows();

    db.replaceMessages(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'u1',
        metadata: const {'request_id': 'r1'},
      ),
      Message(role: MessageRole.assistant, content: 'a1 edited'),
      Message(role: MessageRole.user, content: 'u2'),
      Message(role: MessageRole.assistant, content: 'a2'),
      Message(role: MessageRole.user, content: 'u3'),
      Message(role: MessageRole.assistant, content: 'a3'),
    ]);

    final after = rows();
    expect(after, hasLength(6));
    expect(after.take(5).map((row) => row.id), before.map((row) => row.id));
    expect(
      after.take(5).map((row) => row.messageId),
      before.map((row) => row.messageId),
    );
  });

  test(
    'T6 provider-state clearing keeps row ids and other rows byte-identical',
    () {
      db.replaceMessages(sessionId, [
        Message(
          role: MessageRole.user,
          content: 'u1',
          metadata: const {'request_id': 'r1'},
        ),
        Message(
          role: MessageRole.assistant,
          content: 'a1',
          providerState: const LLMProviderState(
            namespace: 'openai_responses',
            issuer: 'https://api.example.com/v1',
            data: {'encrypted_content': 'opaque-1', 'keep': 'k'},
          ),
        ),
        Message(role: MessageRole.user, content: 'u2'),
        Message(
          role: MessageRole.assistant,
          content: 'a2',
          providerState: const LLMProviderState(
            namespace: 'other',
            data: {'reasoning_content': 'opaque-2'},
          ),
        ),
      ]);
      final before = rows();
      final loaded = db.getMessages(sessionId);
      final cleared = List<Message>.of(loaded);
      cleared[1] = cleared[1].copyWith(
        providerState: const LLMProviderState(
          namespace: 'openai_responses',
          issuer: 'https://api.example.com/v1',
          data: {'keep': 'k'},
        ),
      );

      db.replaceMessages(sessionId, cleared);

      final after = rows();
      expect(after.map((row) => row.id), before.map((row) => row.id));
      expect(after[3].data, before[3].data);
      expect(
        jsonDecode(after[3].data)['providerState'] ??
            jsonDecode(after[3].data)['provider_state'],
        isNotNull,
      );
      expect(after[1].data, isNot(before[1].data));
    },
  );

  test('T2 mid-history insert without message_id keeps the inserted row', () {
    final loaded = seedFive();
    final before = rows();

    final healed = List<Message>.of(loaded)
      ..insert(
        2,
        Message(
          role: MessageRole.tool,
          content: 'interrupted',
          toolCallId: 'call-1',
          metadata: const {'status': 'interrupted'},
        ),
      );
    db.replaceMessages(sessionId, healed);

    final after = rows();
    expect(after, hasLength(6));
    expect(after.map((row) => jsonDecode(row.data)['content']), [
      'u1',
      'a1',
      'interrupted',
      'u2',
      'a2',
      'u3',
    ]);
    // Prefix rows keep ids; displaced rows keep their message_id.
    expect(after[0].id, before[0].id);
    expect(after[1].id, before[1].id);
    expect(
      after.skip(3).map((row) => row.messageId),
      before.skip(2).map((row) => row.messageId),
    );
    expect(
      before.map((row) => row.messageId),
      isNot(contains(after[2].messageId)),
    );

    // A second save of the same in-memory list (the heal row still has no
    // message_id there) is identity-stable and inserts nothing.
    final reSaved = rows();
    db.replaceMessages(sessionId, healed);
    expect(rows().map((row) => row.id), reSaved.map((row) => row.id));
  });

  test('T3 duplicate message_id fails loudly and rolls back', () {
    final loaded = seedFive();
    final before = rows();
    final revisionBefore = revision();

    final duplicated = List<Message>.of(loaded)
      ..[0] = loaded[0].copyWith(content: 'u1 changed')
      ..add(loaded[3].copyWith(content: 'copy of a2'));

    expect(
      () => db.replaceMessages(sessionId, duplicated),
      throwsA(isA<StateError>()),
    );
    expect(rows(), before);
    expect(revision(), revisionBefore);
  });

  test('T4 superseded audit rows survive a replace that re-inserts', () {
    seedFive();
    final ids = rows();
    state.db.execute(
      "UPDATE messages SET history_status = 'superseded' WHERE id IN (?, ?)",
      [ids[2].id, ids[3].id],
    );
    final active = db.getMessages(sessionId);
    expect(active, hasLength(3));

    // Structural change: remove the second active row.
    db.replaceMessages(sessionId, [active[0], active[2]]);

    final after = rows();
    final superseded = after.where((row) => row.status == 'superseded');
    expect(superseded.map((row) => row.id), [ids[2].id, ids[3].id]);
    expect(
      after
          .where((row) => row.status == 'active')
          .map((row) => jsonDecode(row.data)['content']),
      ['u1', 'u3'],
    );
  });

  test('assistant tool batch edit inside history keeps ids of the batch', () {
    db.replaceMessages(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'u1',
        metadata: const {'request_id': 'r1'},
      ),
      Message(
        role: MessageRole.assistant,
        toolCalls: [ToolCall(id: 'c1', name: 'read_file', arguments: const {})],
      ),
      Message(role: MessageRole.tool, content: 'big', toolCallId: 'c1'),
      Message(role: MessageRole.assistant, content: 'done'),
    ]);
    final before = rows();
    final loaded = db.getMessages(sessionId);
    db.replaceMessages(sessionId, [
      ...loaded.take(2),
      loaded[2].copyWith(
        content: '[image data removed after model processing]',
      ),
      loaded[3],
    ]);
    expect(rows().map((row) => row.id), before.map((row) => row.id));
  });
}
