import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

/// Task 110 port guard for Task 117: both live rewrite entry points
/// (`replaceMessages` and `replaceMessagesInTransaction`) must update an
/// identity-aligned row in place (`persist(sqliteId:)`) on a content
/// transform, keeping `messages.id`, instead of the pre-117 content-prefix
/// delete and re-insert.
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

  List<({int id, String messageId, String data})> activeRows() => state.db
      .select(
        '''
        SELECT id, message_id, data FROM messages
        WHERE session_id = ? AND history_status = 'active'
        ORDER BY id
        ''',
        [sessionId],
      )
      .map(
        (row) => (
          id: row['id'] as int,
          messageId: row['message_id'] as String,
          data: row['data'] as String,
        ),
      )
      .toList(growable: false);

  List<Message> seed() {
    db.replaceMessages(sessionId, [
      Message(role: MessageRole.user, content: 'u1'),
      Message(role: MessageRole.assistant, content: 'a1'),
      Message(role: MessageRole.user, content: 'u2'),
      Message(role: MessageRole.assistant, content: 'a2'),
    ]);
    return db.getMessages(sessionId);
  }

  for (final viaTransaction in [false, true]) {
    final label = viaTransaction
        ? 'replaceMessagesInTransaction'
        : 'replaceMessages';

    test('$label updates a content-transformed row in place', () {
      final loaded = seed();
      final before = activeRows();

      // A content transform on the first row (not a structural change):
      // its message_id is unchanged, so the row must be rewritten in place.
      final edited = List<Message>.of(loaded);
      edited[0] = edited[0].copyWith(
        content: 'u1 transformed',
        metadata: {...?edited[0].metadata, 'steer_stamp': 'x'},
      );
      if (viaTransaction) {
        state.transaction(
          (tx) => db.replaceMessagesInTransaction(sessionId, edited, tx),
        );
      } else {
        db.replaceMessages(sessionId, edited);
      }

      final after = activeRows();
      expect(after.map((row) => row.id), before.map((row) => row.id));
      expect(
        after.map((row) => row.messageId),
        before.map((row) => row.messageId),
      );
      final firstData = jsonDecode(after.first.data) as Map<String, dynamic>;
      expect(firstData['content'], 'u1 transformed');
      for (final index in [1, 2, 3]) {
        expect(after[index].data, before[index].data);
      }
      // No duplicate or orphaned rows were written.
      final total = state.db.select(
        'SELECT COUNT(*) AS n FROM messages WHERE session_id = ?',
        [sessionId],
      );
      expect(total.first['n'], 4);
    });
  }
}
