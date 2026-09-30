import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-message-history-identity-',
    );
    setSanadHomeOverride(tempDir.path);
  });

  tearDown(() {
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  SessionState session(String id) {
    final now = DateTime.parse('2026-08-30T00:00:00Z');
    return SessionState(
      sessionId: id,
      model: 'model',
      createdAt: now,
      updatedAt: now,
    );
  }

  test('opening fully identified history does not rewrite message rows', () {
    final first = SessionDB();
    first.saveSession(session('normalized'));
    first.replaceMessages('normalized', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'req-normalized'},
      ),
      Message(role: MessageRole.assistant, content: 'hi'),
    ]);
    first.dispose();

    final audited = sqlite3.open('${tempDir.path}/state.db');
    audited.execute('''
      CREATE TABLE message_migration_audit (
        update_count INTEGER NOT NULL DEFAULT 0
      );
    ''');
    audited.execute(
      'INSERT INTO message_migration_audit (update_count) VALUES (0)',
    );
    audited.execute('''
      CREATE TRIGGER messages_update_audit
      AFTER UPDATE ON messages
      BEGIN
        UPDATE message_migration_audit
        SET update_count = update_count + 1;
      END;
    ''');
    audited.dispose();

    final reopened = SessionDB();
    reopened.dispose();

    final verified = sqlite3.open('${tempDir.path}/state.db');
    addTearDown(verified.dispose);
    final updateCount =
        verified
                .select('SELECT update_count FROM message_migration_audit')
                .first['update_count']
            as int;
    expect(updateCount, 0);
  });

  test('normal reads hide superseded rows and keep them in sqlite', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final db = SessionDB.fromState(state);
    db.saveSession(session('s1'));
    db.replaceMessages('s1', [
      Message(
        role: MessageRole.user,
        content: 'one',
        metadata: const {'request_id': 'r1'},
      ),
      Message(role: MessageRole.assistant, content: 'two'),
    ]);
    final active = db.getMessages('s1');
    expect(active, hasLength(2));
    final firstId = active.first.metadata?['message_id'];
    final sqliteId = state.db.select(
      'SELECT id FROM messages WHERE message_id = ?',
      [firstId],
    ).first['id'];

    state.db.execute(
      "UPDATE messages SET history_status = 'superseded' WHERE message_id = ?",
      [firstId],
    );

    expect(db.getMessages('s1'), hasLength(1));
    final all = db.getMessages('s1', includeSuperseded: true);
    expect(all, hasLength(2));
    expect(
      all.map((message) => message.metadata?['history_status']),
      containsAll(['active', 'superseded']),
    );

    db.replaceMessages('s1', db.getMessages('s1'));
    expect(db.getMessages('s1', includeSuperseded: true), hasLength(2));
    expect(
      state.db.select('SELECT id FROM messages WHERE message_id = ?', [
        firstId,
      ]).first['id'],
      sqliteId,
    );
  });

  test('rewriting the same active list keeps message_id and sqlite id', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final db = SessionDB.fromState(state);
    db.saveSession(session('s1'));
    db.replaceMessages('s1', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'r1'},
      ),
      Message(role: MessageRole.assistant, content: 'world'),
    ]);
    final first = db.getMessages('s1');
    final rows = state.db.select(
      'SELECT id, message_id FROM messages WHERE session_id = ? ORDER BY id',
      ['s1'],
    );
    db.replaceMessages('s1', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: const {'request_id': 'r1'},
      ),
      Message(role: MessageRole.assistant, content: 'world'),
    ]);
    final second = db.getMessages('s1');
    expect(second[0].metadata?['message_id'], first[0].metadata?['message_id']);
    expect(second[1].metadata?['message_id'], first[1].metadata?['message_id']);
    final rewritten = state.db.select(
      'SELECT id, message_id FROM messages WHERE session_id = ? ORDER BY id',
      ['s1'],
    );
    expect(rewritten[0]['id'], rows[0]['id']);
    expect(rewritten[1]['id'], rows[1]['id']);
    expect(rewritten[0]['message_id'], rows[0]['message_id']);
  });

  test('legacy root user without request_id is visible and not replayable', () {
    final db = SessionDB();
    addTearDown(db.dispose);
    db.saveSession(session('s1'));
    db.replaceMessages('s1', [Message(role: MessageRole.user, content: 'old')]);
    final restored = db.getMessages('s1').single;
    expect(restored.metadata?['input_kind'], 'root_turn');
    expect(restored.metadata?['replay_eligible'], isFalse);
    expect(restored.metadata?['message_id'], isNotEmpty);
  });

  test('embedded steer_messages receive durable message ids', () {
    final db = SessionDB();
    addTearDown(db.dispose);
    db.saveSession(session('s1'));
    db.replaceMessages('s1', [
      Message(
        role: MessageRole.user,
        content: 'root',
        metadata: const {'request_id': 'r1'},
      ),
      Message(
        role: MessageRole.tool,
        content: 'result',
        toolCallId: 'call-1',
        metadata: const {
          'steer_messages': [
            {'text': 'please wait', 'request_id': 'steer-1'},
          ],
        },
      ),
    ]);
    final tool = db.getMessages('s1').last;
    final steers = tool.metadata?['steer_messages'] as List;
    expect(steers, hasLength(1));
    expect(steers.first['message_id'], isNotEmpty);
    expect(steers.first['input_kind'], 'steer');
    expect(steers.first['turn_id'], tool.metadata?['turn_id']);
  });

  test('message identity cannot update a different session', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final db = SessionDB.fromState(state);
    db.saveSession(session('s1'));
    db.saveSession(session('s2'));
    db.replaceMessages('s1', [
      Message(
        role: MessageRole.user,
        content: 'session one',
        metadata: const {
          'message_id': 'shared-message-id',
          'turn_id': 'turn-s1',
          'request_id': 'request-s1',
        },
      ),
    ]);

    expect(
      () => db.replaceMessages('s2', [
        Message(
          role: MessageRole.user,
          content: 'must not overwrite session one',
          metadata: const {
            'message_id': 'shared-message-id',
            'turn_id': 'turn-s2',
            'request_id': 'request-s2',
          },
        ),
      ]),
      throwsA(isA<SqliteException>()),
    );

    expect(db.getMessages('s1').single.content, 'session one');
    expect(db.getMessages('s2'), isEmpty);
  });

  test('saveSession does not reset history_revision', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final db = SessionDB.fromState(state);
    db.saveSession(session('s1'));
    state.db.execute(
      'UPDATE sessions SET history_revision = 4 WHERE session_id = ?',
      ['s1'],
    );
    db.saveSession(session('s1'));
    expect(db.getSession('s1')!.historyRevision, 4);
  });

  test('assignIdentities groups a steer into the open root turn', () {
    final assigned = MessageHistoryIdentity.assignIdentities([
      Message(
        role: MessageRole.user,
        content: 'root',
        metadata: const {'request_id': 'r1'},
      ),
      Message(role: MessageRole.assistant, content: 'work'),
      Message(
        role: MessageRole.user,
        content: 'nudge',
        metadata: const {'steer': true, 'request_id': 's1'},
      ),
    ]);
    expect(assigned[0].metadata?['turn_id'], assigned[1].metadata?['turn_id']);
    expect(assigned[0].metadata?['turn_id'], assigned[2].metadata?['turn_id']);
    expect(assigned[2].metadata?['input_kind'], 'steer');
    expect(assigned[2].metadata?['replay_eligible'], isFalse);
  });
}
