import 'dart:io';
import 'package:test/test.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/core/constants.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad_test_');
    setSanadHomeOverride(tempDir.path);
  });

  tearDown(() {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('SessionManager creates and retrieves a session', () {
    final sessionManager = SessionManager();
    final session = sessionManager.createSession('test-model');

    expect(session.sessionId, isNotEmpty);
    expect(session.model, equals('test-model'));

    final retrieved = sessionManager.getSession(session.sessionId);
    expect(retrieved, isNotNull);
    expect(retrieved!.sessionId, equals(session.sessionId));
    expect(retrieved.model, equals('test-model'));
  });

  test('revision mismatch invalidates the bounded history snapshot', () {
    final sessionManager = SessionManager();
    final session = sessionManager.createSession('test-model');
    sessionManager.saveSessionHistory(session.sessionId, [
      Message(
        role: MessageRole.user,
        content: 'first',
        metadata: const {'request_id': 'request-1'},
      ),
    ]);
    expect(
      sessionManager.getSession(session.sessionId)!.messages,
      hasLength(1),
    );

    sessionManager.db.appendRootUserMessage(
      session.sessionId,
      Message(
        role: MessageRole.user,
        content: 'external mutation',
        metadata: const {'request_id': 'request-2'},
      ),
    );

    final refreshed = sessionManager.getSession(session.sessionId)!;
    expect(refreshed.messages, hasLength(2));
    expect(refreshed.messages.last.content, 'external mutation');
  });

  test('history snapshots evict the least recently used ninth session', () {
    final sessionManager = SessionManager();
    final sessions = List.generate(
      9,
      (_) => sessionManager.createSession('test-model'),
    );

    for (final session in sessions) {
      sessionManager.getSession(session.sessionId);
    }

    expect(sessionManager.historySnapshotCount, 8);
    expect(
      sessionManager.hasHistorySnapshot(sessions.first.sessionId),
      isFalse,
    );
    expect(sessionManager.hasHistorySnapshot(sessions.last.sessionId), isTrue);
  });

  test('SessionManager saves and replaces message history', () {
    final sessionManager = SessionManager();
    final session = sessionManager.createSession('test-model');

    final messages = [
      Message(role: MessageRole.system, content: 'You are an AI'),
      Message(role: MessageRole.user, content: 'Hello'),
      Message(role: MessageRole.assistant, content: 'Hi there!'),
    ];

    sessionManager.saveSessionHistory(session.sessionId, messages);

    final retrieved = sessionManager.getSession(session.sessionId);
    expect(retrieved, isNotNull);
    expect(retrieved!.messages.length, equals(3));
    expect(retrieved.messages[0].content, equals('You are an AI'));
    expect(retrieved.messages[2].content, equals('Hi there!'));

    // Replace history
    final newMessages = [
      Message(role: MessageRole.system, content: 'You are an AI'),
      Message(role: MessageRole.user, content: 'Hello'),
      Message(role: MessageRole.assistant, content: 'Hi there!'),
      Message(role: MessageRole.user, content: 'How are you?'),
      Message(role: MessageRole.assistant, content: 'I am doing well, thanks!'),
    ];

    sessionManager.saveSessionHistory(session.sessionId, newMessages);
    final retrievedUpdated = sessionManager.getSession(session.sessionId);
    expect(retrievedUpdated, isNotNull);
    expect(retrievedUpdated!.messages.length, equals(5));
    expect(
      retrievedUpdated.messages[4].content,
      equals('I am doing well, thanks!'),
    );
  });
}
