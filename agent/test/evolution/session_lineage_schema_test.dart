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
    tempDir = await Directory.systemTemp.createTemp('sanad-session-lineage-');
    setSanadHomeOverride(tempDir.path);
  });

  tearDown(() {
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  SessionState session({
    required String id,
    String? lineageId,
    String? parentSessionId,
    String? forkedFromMessageId,
    String? forkedFromTurnId,
    int forkSequence = 0,
    String? lineageBaseTitle,
    String? forkRequestId,
    String? title,
  }) {
    final now = DateTime.parse('2026-08-30T00:00:00Z');
    return SessionState(
      sessionId: id,
      model: 'model',
      title: title,
      createdAt: now,
      updatedAt: now,
      lineageId: lineageId,
      parentSessionId: parentSessionId,
      forkedFromMessageId: forkedFromMessageId,
      forkedFromTurnId: forkedFromTurnId,
      forkSequence: forkSequence,
      lineageBaseTitle: lineageBaseTitle,
      forkRequestId: forkRequestId,
    );
  }

  test('existing sessions backfill as independent lineage roots', () {
    final raw = sqlite3.open('${tempDir.path}/state.db');
    raw.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    raw.execute(
      'INSERT INTO sessions (session_id, model, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      ['legacy', 'model', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'],
    );
    raw.dispose();

    final db = SessionDB();
    addTearDown(db.dispose);
    final restored = db.getSession('legacy');
    expect(restored, isNotNull);
    expect(restored!.lineageId, 'legacy');
    expect(restored.forkSequence, 0);
    expect(restored.parentSessionId, isNull);
  });

  test('existing forks backfill ordering recency to fork creation', () {
    final initialState = AgentStateDatabase();
    final initialDb = SessionDB.fromState(initialState);
    initialDb.saveSession(session(id: 'parent', title: 'Project'));
    initialDb.saveSession(
      session(
        id: 'child',
        title: '(1) Project',
        lineageId: 'parent',
        parentSessionId: 'parent',
        forkSequence: 1,
      ),
    );
    initialState.db.execute(
      '''
      UPDATE sessions
      SET created_at = ?, updated_at = ?, last_user_message_at = ?
      WHERE session_id = ?
      ''',
      [
        '2026-08-31T12:00:00.000Z',
        '2026-08-31T12:00:00.000Z',
        '2026-08-01T12:00:00.000Z',
        'child',
      ],
    );
    initialDb.dispose();
    initialState.dispose();

    final reopenedState = AgentStateDatabase();
    final reopened = SessionDB.fromState(reopenedState);
    addTearDown(reopenedState.dispose);
    addTearDown(reopened.dispose);

    final child = reopened.getSession('child')!;
    expect(child.lastUserMessageAt, DateTime.parse('2026-08-31T12:00:00.000Z'));
    expect(reopened.getAllSessions().first.sessionId, 'child');
  });

  test('deleting a parent leaves the child readable and continuable', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    db.saveSession(session(id: 'parent', title: 'Refactor auth'));
    db.replaceMessages('parent', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: {'request_id': 'req-1', 'message_id': 'm-user'},
      ),
      Message(
        role: MessageRole.assistant,
        content: 'hi',
        metadata: {'message_id': 'm-final', 'turn_id': 'turn-1'},
      ),
    ]);
    db.saveSession(
      session(
        id: 'child',
        title: '(1) Refactor auth',
        lineageId: 'parent',
        parentSessionId: 'parent',
        forkedFromMessageId: 'm-final',
        forkedFromTurnId: 'turn-1',
        forkSequence: 1,
        lineageBaseTitle: 'Refactor auth',
      ),
    );
    db.replaceMessages('child', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: {
          'request_id': 'req-1',
          'message_id': 'child-user',
          'origin_message_id': 'm-user',
        },
      ),
      Message(
        role: MessageRole.assistant,
        content: 'hi',
        metadata: {
          'message_id': 'child-final',
          'turn_id': 'child-turn',
          'origin_message_id': 'm-final',
        },
      ),
    ]);

    db.deleteSession('parent');

    expect(db.getSession('parent'), isNull);
    final child = db.getSession('child');
    expect(child, isNotNull);
    expect(child!.lineageId, 'parent');
    expect(child.parentSessionId, isNull);
    expect(child.forkedFromMessageId, 'm-final');
    expect(child.forkSequence, 1);
    expect(child.messages, hasLength(2));
    expect(
      MessageHistoryIdentity.read(child.messages.last).originMessageId,
      'm-final',
    );

    db.replaceMessages('child', [
      ...child.messages,
      Message(
        role: MessageRole.user,
        content: 'continue',
        metadata: {'request_id': 'req-2'},
      ),
    ]);
    expect(db.getMessages('child'), hasLength(3));
  });

  test('failed parent deletion preserves the child parent link', () {
    final state = AgentStateDatabase();
    addTearDown(state.dispose);
    final db = SessionDB.fromState(state);

    db.saveSession(session(id: 'parent', title: 'Refactor auth'));
    db.saveSession(
      session(
        id: 'child',
        lineageId: 'parent',
        parentSessionId: 'parent',
        forkSequence: 1,
        lineageBaseTitle: 'Refactor auth',
      ),
    );
    state.db.execute('''
      CREATE TRIGGER reject_parent_delete
      BEFORE DELETE ON sessions
      WHEN OLD.session_id = 'parent'
      BEGIN
        SELECT RAISE(ABORT, 'parent deletion rejected');
      END;
    ''');

    expect(() => db.deleteSession('parent'), throwsA(isA<SqliteException>()));

    expect(db.getSession('parent'), isNotNull);
    expect(db.getSession('child')!.parentSessionId, 'parent');
  });

  test('deleting a child leaves the parent unchanged', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    db.saveSession(session(id: 'parent', title: 'Refactor auth'));
    db.replaceMessages('parent', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: {'request_id': 'req-1', 'message_id': 'm-user'},
      ),
    ]);
    db.saveSession(
      session(
        id: 'child',
        title: '(1) Refactor auth',
        lineageId: 'parent',
        parentSessionId: 'parent',
        forkSequence: 1,
        lineageBaseTitle: 'Refactor auth',
      ),
    );
    db.replaceMessages('child', [
      Message(
        role: MessageRole.user,
        content: 'hello',
        metadata: {
          'request_id': 'req-1',
          'message_id': 'child-user',
          'origin_message_id': 'm-user',
        },
      ),
    ]);

    db.deleteSession('child');

    expect(db.getSession('child'), isNull);
    final parent = db.getSession('parent');
    expect(parent, isNotNull);
    expect(parent!.title, 'Refactor auth');
    expect(parent.messages, hasLength(1));
    expect(parent.forkSequence, 0);
  });

  test('branch-from-branch keeps lineage and unique sequence', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    db.saveSession(session(id: 'root', title: 'Refactor auth'));
    db.saveSession(
      session(
        id: 'child-1',
        lineageId: 'root',
        parentSessionId: 'root',
        forkSequence: 1,
        lineageBaseTitle: 'Refactor auth',
      ),
    );
    db.saveSession(
      session(
        id: 'child-2',
        lineageId: 'root',
        parentSessionId: 'child-1',
        forkSequence: 2,
        lineageBaseTitle: 'Refactor auth',
      ),
    );

    final grandchild = db.getSession('child-2');
    expect(grandchild!.lineageId, 'root');
    expect(grandchild.parentSessionId, 'child-1');
    expect(grandchild.forkSequence, 2);

    expect(
      () => db.saveSession(
        session(
          id: 'dup',
          lineageId: 'root',
          parentSessionId: 'child-1',
          forkSequence: 2,
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('live saveSession does not wipe lineage metadata', () {
    final db = SessionDB();
    addTearDown(db.dispose);
    db.saveSession(
      session(
        id: 'child',
        lineageId: 'root',
        parentSessionId: 'root',
        forkedFromMessageId: 'm-final',
        forkedFromTurnId: 'turn-1',
        forkSequence: 1,
        lineageBaseTitle: 'Refactor auth',
        forkRequestId: 'fork-req-1',
        title: '(1) Refactor auth',
      ),
    );

    db.saveSession(
      SessionState(
        sessionId: 'child',
        model: 'other-model',
        title: '(1) Refactor auth',
        createdAt: DateTime.parse('2026-08-30T00:00:00Z'),
        updatedAt: DateTime.parse('2026-08-30T01:00:00Z'),
      ),
    );

    final restored = db.getSession('child');
    expect(restored!.model, 'other-model');
    expect(restored.lineageId, 'root');
    expect(restored.parentSessionId, 'root');
    expect(restored.forkedFromMessageId, 'm-final');
    expect(restored.forkSequence, 1);
    expect(restored.forkRequestId, 'fork-req-1');
  });
}
