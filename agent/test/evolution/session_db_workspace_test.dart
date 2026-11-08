import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/session_query.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-agent-session-db-test',
    );
    setSanadHomeOverride(tempDir.path);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists workspace_id for sessions', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    final session = SessionState(
      sessionId: 'session-1',
      model: 'sanad-agent',
      title: 'Workspace Session',
      workspaceId: '/repo/workspace-a',
      thinkingMode: 'deep',
      createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
    );

    db.saveSession(session);

    final restored = db.getSession('session-1');
    expect(restored, isNotNull);
    expect(restored!.workspaceId, '/repo/workspace-a');
    expect(restored.thinkingMode, 'deep');
  });

  test('migrates older sessions table and reads workspace_id afterwards', () {
    final rawDb = sqlite3.open('${tempDir.path}/state.db');
    rawDb.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    rawDb.execute(
      '''
      INSERT INTO sessions (
        session_id,
        model,
        title,
        metadata,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    ''',
      [
        'legacy-session',
        'sanad-agent',
        'Legacy',
        null,
        '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z',
      ],
    );
    rawDb.dispose();

    final db = SessionDB();
    addTearDown(db.dispose);

    final migratedSession = SessionState(
      sessionId: 'legacy-session',
      model: 'sanad-agent',
      title: 'Legacy',
      workspaceId: '/repo/workspace-b',
      createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      updatedAt: DateTime.parse('2026-01-02T00:00:00Z'),
    );

    db.saveSession(migratedSession);

    final restored = db.getSession('legacy-session');
    expect(restored, isNotNull);
    expect(restored!.workspaceId, '/repo/workspace-b');
  });

  test('migrates path workspace identity to a stable UUID', () {
    final rawDb = sqlite3.open('${tempDir.path}/state.db');
    rawDb.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        workspace_id TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_user_message_at TEXT
      );
    ''');
    rawDb.execute('''
      CREATE TABLE workspaces (
        path TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    rawDb.execute('''
      CREATE TABLE session_work_items (
        work_item_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        request_id TEXT,
        sequence INTEGER NOT NULL,
        provider_instance_id TEXT,
        model_id TEXT,
        workspace_id TEXT,
        payload_json TEXT NOT NULL DEFAULT '{}',
        attempt INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        continuation_metadata TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE (session_id, request_id)
      );
    ''');
    rawDb.execute(
      'INSERT INTO workspaces (path, source, updated_at) VALUES (?, ?, ?)',
      ['/repo/legacy-workspace', 'created', '2026-01-01T00:00:00Z'],
    );
    rawDb.execute(
      '''INSERT INTO sessions (
        session_id, model, title, workspace_id, metadata,
        created_at, updated_at, last_user_message_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        'legacy-workspace-session',
        'sanad-agent',
        'Legacy workspace',
        '/repo/legacy-workspace',
        null,
        '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z',
      ],
    );
    rawDb.execute(
      '''INSERT INTO session_work_items (
        work_item_id, session_id, request_id, sequence, workspace_id,
        payload_json, attempt, state, continuation_metadata, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        'legacy-work-item',
        'legacy-workspace-session',
        'legacy-request',
        1,
        '/repo/legacy-workspace',
        '{"workspace_id":"/repo/legacy-workspace","workspace":{"id":"/repo/legacy-workspace","path":"/repo/legacy-workspace"}}',
        0,
        'queued',
        '{}',
        '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z',
      ],
    );
    rawDb.dispose();

    final db = SessionDB();
    addTearDown(db.dispose);
    final workspace = db.getStoredWorkspaces().single;
    final workspaceId = workspace['id'] as String;

    expect(workspaceId, isNot('/repo/legacy-workspace'));
    expect(workspace['display_name'], 'legacy-workspace');
    expect(workspace['path'], '/repo/legacy-workspace');
    expect(db.getSession('legacy-workspace-session')!.workspaceId, workspaceId);

    final auditDb = sqlite3.open('${tempDir.path}/state.db');
    final workItem = auditDb.select(
      'SELECT workspace_id, payload_json FROM session_work_items '
      'WHERE work_item_id = ?',
      ['legacy-work-item'],
    ).single;
    final payload = jsonDecode(workItem['payload_json'] as String) as Map;
    expect(workItem['workspace_id'], workspaceId);
    expect(payload['workspace_id'], workspaceId);
    expect((payload['workspace'] as Map)['id'], workspaceId);
    expect((payload['workspace'] as Map)['path'], '/repo/legacy-workspace');
    auditDb.dispose();
  });

  test('persists and retrieves workspaces', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    db.saveWorkspace(
      path: '/repo/workspace-1',
      source: 'created',
      updatedAt: '2026-01-01T00:00:00Z',
    );
    db.saveWorkspace(
      path: '/repo/workspace-2',
      source: 'stored',
      updatedAt: '2026-01-02T00:00:00Z',
    );

    final stored = db.getStoredWorkspaces();
    expect(stored, hasLength(2));

    expect(stored[0]['path'], '/repo/workspace-2');
    expect(stored[0]['source'], 'stored');

    expect(stored[1]['path'], '/repo/workspace-1');
    expect(stored[1]['source'], 'created');
  });

  test('migrates last_user_message_at from messages table or fallbacks', () {
    final rawDb = sqlite3.open('${tempDir.path}/state.db');
    rawDb.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    rawDb.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        data TEXT NOT NULL
      );
    ''');

    // session-legacy-msg has a user message
    rawDb.execute('''
      INSERT INTO sessions (session_id, model, title, created_at, updated_at)
      VALUES ('legacy-msg', 'sanad-agent', 'Legacy Msg', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z')
    ''');
    rawDb.execute('''
      INSERT INTO messages (session_id, data)
      VALUES ('legacy-msg', '{"role":"user","content":"hello","timestamp":"2026-01-01T12:00:00Z"}')
    ''');

    // session-legacy-no-msg has no user messages
    rawDb.execute('''
      INSERT INTO sessions (session_id, model, title, created_at, updated_at)
      VALUES ('legacy-no-msg', 'sanad-agent', 'Legacy No Msg', '2026-01-01T00:00:00Z', '2026-01-03T00:00:00Z')
    ''');

    rawDb.dispose();

    final db = SessionDB();
    addTearDown(db.dispose);

    final restoredMsg = db.getSession('legacy-msg');
    expect(restoredMsg, isNotNull);
    expect(
      restoredMsg!.lastUserMessageAt,
      equals(DateTime.parse('2026-01-01T12:00:00Z')),
    );

    final restoredNoMsg = db.getSession('legacy-no-msg');
    expect(restoredNoMsg, isNotNull);
    expect(
      restoredNoMsg!.lastUserMessageAt,
      equals(DateTime.parse('2026-01-03T00:00:00Z')),
    );
  });

  test('unscoped list includes execution-root sessions', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    SessionState session(String id, String? workspaceId, String at) =>
        SessionState(
          sessionId: id,
          model: 'sanad-agent',
          title: id,
          workspaceId: workspaceId,
          createdAt: DateTime.parse(at),
          updatedAt: DateTime.parse(at),
          lastUserMessageAt: DateTime.parse(at),
        );

    db.saveSession(session('plain', null, '2026-01-01T00:00:01Z'));
    db.saveSession(
      session('run', 'exec_root:/work/root', '2026-01-01T00:00:02Z'),
    );
    db.saveSession(session('scoped', 'workspace-a', '2026-01-01T00:00:03Z'));

    // A run session belongs to the unscoped list: no registered workspace can
    // ever own it, so the alternative is a session in no list at all.
    final unscoped = db.getSessions(
      SessionQueryRequest(unscopedOnly: true, limit: 10),
    );
    expect(
      unscoped.sessions.map((row) => row.sessionId),
      ['run', 'plain'],
    );

    // It stays addressable by its own execution-root identity too.
    final byExecRoot = db.getSessions(
      SessionQueryRequest(workspaceId: 'exec_root:/work/root', limit: 10),
    );
    expect(byExecRoot.sessions.map((row) => row.sessionId), ['run']);

    // A registered workspace keeps its own section.
    final scoped = db.getSessions(
      SessionQueryRequest(workspaceId: 'workspace-a', limit: 10),
    );
    expect(scoped.sessions.map((row) => row.sessionId), ['scoped']);
  });

  test('keyset pagination and workspace filtering in getSessions', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    // Save sessions with workspace A
    for (int i = 1; i <= 5; i++) {
      db.saveSession(
        SessionState(
          sessionId: 'session-a-$i',
          model: 'sanad-agent',
          title: 'Session A $i',
          workspaceId: 'workspace-a',
          createdAt: DateTime.parse('2026-01-01T00:00:0${i}Z'),
          updatedAt: DateTime.parse('2026-01-01T00:00:0${i}Z'),
          lastUserMessageAt: DateTime.parse('2026-01-01T00:00:0${i}Z'),
        ),
      );
    }

    // Save unscoped sessions
    for (int i = 1; i <= 5; i++) {
      db.saveSession(
        SessionState(
          sessionId: 'session-unscoped-$i',
          model: 'sanad-agent',
          title: 'Session Unscoped $i',
          createdAt: DateTime.parse('2026-01-02T00:00:0${i}Z'),
          updatedAt: DateTime.parse('2026-01-02T00:00:0${i}Z'),
          lastUserMessageAt: DateTime.parse('2026-01-02T00:00:0${i}Z'),
        ),
      );
    }

    // Query workspace-a sessions with limit 2
    final queryA1 = SessionQueryRequest(workspaceId: 'workspace-a', limit: 2);
    final resultA1 = db.getSessions(queryA1);
    expect(resultA1.sessions, hasLength(2));
    expect(resultA1.sessions[0].sessionId, 'session-a-5');
    expect(resultA1.sessions[1].sessionId, 'session-a-4');
    expect(resultA1.hasMore, isTrue);
    expect(resultA1.nextCursor, isNotNull);

    // Query next page using cursor
    final queryA2 = SessionQueryRequest(
      workspaceId: 'workspace-a',
      limit: 2,
      cursor: resultA1.nextCursor,
    );
    final resultA2 = db.getSessions(queryA2);
    expect(resultA2.sessions, hasLength(2));
    expect(resultA2.sessions[0].sessionId, 'session-a-3');
    expect(resultA2.sessions[1].sessionId, 'session-a-2');
    expect(resultA2.hasMore, isTrue);

    // Query third page
    final queryA3 = SessionQueryRequest(
      workspaceId: 'workspace-a',
      limit: 2,
      cursor: resultA2.nextCursor,
    );
    final resultA3 = db.getSessions(queryA3);
    expect(resultA3.sessions, hasLength(1));
    expect(resultA3.sessions[0].sessionId, 'session-a-1');
    expect(resultA3.hasMore, isFalse);
    expect(resultA3.nextCursor, isNull);

    // Query unscoped sessions
    final queryUnscoped = SessionQueryRequest(unscopedOnly: true, limit: 10);
    final resultUnscoped = db.getSessions(queryUnscoped);
    expect(resultUnscoped.sessions, hasLength(5));
    expect(resultUnscoped.sessions[0].sessionId, 'session-unscoped-5');
    expect(resultUnscoped.hasMore, isFalse);
  });

  test(
    'normalizes legacy timestamps so equal instants do not break pagination',
    () {
      final rawDb = sqlite3.open('${tempDir.path}/state.db');
      rawDb.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        workspace_id TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_user_message_at TEXT
      );
    ''');
      rawDb.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        data TEXT NOT NULL
      );
    ''');
      rawDb.execute('''
      INSERT INTO sessions (
        session_id, model, title, created_at, updated_at, last_user_message_at
      ) VALUES
      ('session-a', 'sanad-agent', 'A', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
      ('session-b', 'sanad-agent', 'B', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00.000Z'),
      ('session-c', 'sanad-agent', 'C', '2026-01-01T00:00:01Z', '2026-01-01T00:00:01Z', '2026-01-01T00:00:01Z')
    ''');
      rawDb.dispose();

      final db = SessionDB();
      addTearDown(db.dispose);

      final firstPage = db.getSessions(SessionQueryRequest(limit: 2));
      expect(firstPage.sessions.map((session) => session.sessionId), [
        'session-c',
        'session-b',
      ]);
      expect(firstPage.hasMore, isTrue);

      final secondPage = db.getSessions(
        SessionQueryRequest(limit: 2, cursor: firstPage.nextCursor),
      );
      expect(secondPage.sessions.map((session) => session.sessionId), [
        'session-a',
      ]);
      expect(secondPage.hasMore, isFalse);
    },
  );

  test('rejects invalid query parameters and cursor payloads', () {
    final db = SessionDB();
    addTearDown(db.dispose);

    expect(
      () => SessionQueryRequest.fromMap({'limit': 'abc'}),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => SessionQueryRequest.fromMap({'limit': 0}),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => db.getSessions(SessionQueryRequest(cursor: 'bm90LWpzb24=')),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => db.getSessions(
        SessionQueryRequest(
          cursor: base64Url.encode(
            utf8.encode(
              '{"last_user_message_at":"not-a-date","session_id":"session-1"}',
            ),
          ),
        ),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'saveSession preserves stored last_user_message_at during non-user updates',
    () {
      final db = SessionDB();
      addTearDown(db.dispose);

      final originalTimestamp = DateTime.parse('2026-01-01T10:00:00Z');
      db.saveSession(
        SessionState(
          sessionId: 'session-preserve',
          model: 'model-a',
          providerId: 'provider-a',
          thinkingMode: 'medium',
          title: 'Original',
          workspaceId: 'workspace-a',
          createdAt: DateTime.parse('2026-01-01T09:00:00Z'),
          updatedAt: DateTime.parse('2026-01-01T09:00:00Z'),
          lastUserMessageAt: originalTimestamp,
        ),
      );

      db.saveSession(
        SessionState(
          sessionId: 'session-preserve',
          model: 'model-b',
          providerId: 'provider-b',
          thinkingMode: 'high',
          title: 'Updated',
          workspaceId: 'workspace-b',
          createdAt: DateTime.parse('2026-01-01T09:00:00Z'),
          updatedAt: DateTime.parse('2026-01-01T11:00:00Z'),
        ),
      );

      final restored = db.getSession('session-preserve');
      expect(restored, isNotNull);
      expect(restored!.model, 'model-b');
      expect(restored.providerId, 'provider-b');
      expect(restored.thinkingMode, 'high');
      expect(restored.workspaceId, 'workspace-b');
      expect(restored.lastUserMessageAt, originalTimestamp);
    },
  );

  test(
    'session manager updates and assistant-only history do not reorder sessions, but canonical user acceptance does',
    () {
      final manager = SessionManager();

      manager.db.saveSession(
        SessionState(
          sessionId: 'older-session',
          model: 'model-a',
          providerId: 'provider-a',
          thinkingMode: 'low',
          workspaceId: 'workspace-a',
          createdAt: DateTime.parse('2026-01-01T08:00:00Z'),
          updatedAt: DateTime.parse('2026-01-01T08:00:00Z'),
          lastUserMessageAt: DateTime.parse('2026-01-01T08:00:00Z'),
        ),
      );
      manager.db.saveSession(
        SessionState(
          sessionId: 'newer-session',
          model: 'model-b',
          providerId: 'provider-b',
          thinkingMode: 'high',
          workspaceId: 'workspace-b',
          createdAt: DateTime.parse('2026-01-01T09:00:00Z'),
          updatedAt: DateTime.parse('2026-01-01T09:00:00Z'),
          lastUserMessageAt: DateTime.parse('2026-01-01T09:00:00Z'),
        ),
      );

      manager.updateSessionModeling(
        'older-session',
        providerId: 'provider-c',
        model: 'model-c',
        thinkingMode: 'max',
      );
      final afterModeling = manager.getSession('older-session')!;
      expect(
        afterModeling.lastUserMessageAt,
        DateTime.parse('2026-01-01T08:00:00Z'),
      );

      manager.db.saveSession(
        SessionState(
          sessionId: afterModeling.sessionId,
          model: afterModeling.model,
          providerId: afterModeling.providerId,
          thinkingMode: afterModeling.thinkingMode,
          title: afterModeling.title,
          workspaceId: 'workspace-c',
          createdAt: afterModeling.createdAt,
          updatedAt: DateTime.parse('2026-01-01T10:00:00Z'),
          lastUserMessageAt: afterModeling.lastUserMessageAt,
        ),
      );

      manager.saveSessionHistory('older-session', [
        Message(role: MessageRole.assistant, content: 'assistant only'),
        Message(role: MessageRole.tool, content: 'tool only'),
      ]);

      final afterAssistantOnly = manager.getAllSessions();
      expect(afterAssistantOnly.first.sessionId, 'newer-session');

      manager.recordCanonicalUserMessageAccepted(
        'older-session',
        DateTime.parse('2026-01-01T12:00:00Z'),
      );

      final afterUserMessage = manager.getAllSessions();
      expect(afterUserMessage.first.sessionId, 'older-session');
      expect(
        afterUserMessage.first.lastUserMessageAt,
        DateTime.parse('2026-01-01T12:00:00Z'),
      );
    },
  );

  test(
    'migration batches large session sets without exceeding SQLite variable limit',
    () {
      final rawDb = sqlite3.open('${tempDir.path}/state.db');
      rawDb.execute('''
        CREATE TABLE sessions (
          session_id TEXT PRIMARY KEY,
          model TEXT NOT NULL,
          title TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_user_message_at TEXT,
          workspace_id TEXT
        );
      ''');
      rawDb.execute('''
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          data TEXT NOT NULL
        );
      ''');

      for (var i = 0; i < 1200; i++) {
        rawDb.execute(
          '''
          INSERT INTO sessions (
            session_id, model, title, created_at, updated_at, last_user_message_at, workspace_id
          ) VALUES (?, 'sanad-agent', 'Legacy', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL, '')
          ''',
          ['legacy-$i'],
        );
        rawDb.execute('INSERT INTO messages (session_id, data) VALUES (?, ?)', [
          'legacy-$i',
          '{"role":"user","content":"hello","timestamp":"2026-01-01T00:00:00Z"}',
        ]);
      }
      rawDb.dispose();

      final db = SessionDB();
      addTearDown(db.dispose);

      final restored = db.getSession('legacy-1199');
      expect(restored, isNotNull);
      expect(
        restored!.lastUserMessageAt,
        DateTime.parse('2026-01-01T00:00:00Z'),
      );
      expect(restored.workspaceId, isNull);
    },
  );

  test(
    'migration is idempotent and does not rewrite already normalized rows',
    () {
      final rawDb = sqlite3.open('${tempDir.path}/state.db');
      rawDb.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_user_message_at TEXT,
        workspace_id TEXT
      );
    ''');
      rawDb.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        data TEXT NOT NULL
      );
    ''');
      rawDb.execute('''
      CREATE TABLE migration_audit (
        update_count INTEGER NOT NULL DEFAULT 0
      );
    ''');
      rawDb.execute('INSERT INTO migration_audit (update_count) VALUES (0)');
      rawDb.execute('''
      CREATE TRIGGER sessions_update_audit
      AFTER UPDATE ON sessions
      BEGIN
        UPDATE migration_audit SET update_count = update_count + 1;
      END;
    ''');
      rawDb.execute('''
      INSERT INTO sessions (
        session_id, model, title, created_at, updated_at, last_user_message_at, workspace_id
      ) VALUES (
        'legacy-one', 'sanad-agent', 'Legacy', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL, ''
      )
    ''');
      rawDb.execute('''
      INSERT INTO messages (session_id, data)
      VALUES ('legacy-one', '{"role":"user","content":"hello","timestamp":"2026-01-01T12:00:00Z"}')
    ''');
      rawDb.dispose();

      final first = SessionDB();
      first.dispose();

      final afterFirst = sqlite3.open('${tempDir.path}/state.db');
      final firstCount =
          afterFirst
                  .select('SELECT update_count FROM migration_audit')
                  .first['update_count']
              as int;
      afterFirst.dispose();
      expect(firstCount, greaterThan(0));

      final second = SessionDB();
      second.dispose();

      final afterSecond = sqlite3.open('${tempDir.path}/state.db');
      final secondCount =
          afterSecond
                  .select('SELECT update_count FROM migration_audit')
                  .first['update_count']
              as int;
      afterSecond.dispose();
      expect(secondCount, firstCount);
    },
  );
}
