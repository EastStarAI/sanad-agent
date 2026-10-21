// Task 111 G1/G3: history hydration classifies terminal replies with session
// scope, never by their position inside the fetched page.

import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

Message _user(String id, String turn, String content) => Message(
  role: MessageRole.user,
  content: content,
  metadata: {'message_id': id, 'turn_id': turn, 'request_id': 'req-$id'},
);

/// An unstamped reply as history rewrites left it on existing Homes: full
/// statistics and identity, but no `terminal_work_item_id`.
Message _reply(String id, String turn, String content) => Message(
  role: MessageRole.assistant,
  content: content,
  metadata: {
    'message_id': id,
    'turn_id': turn,
    'run_id': 'run-$id',
    'model': 'gpt-test',
    'model_display': 'GPT Test',
    'provider': 'openai',
    'runtime_ms': 1200,
    'context_tokens': 900,
    'usage': const {'input_tokens': 10, 'output_tokens': 20},
  },
);

void main() {
  late Directory tempDir;
  late SessionManager sessions;
  late SanadProtocolBridge bridge;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-111-history');
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.registerSingleton<AuthManager>(AuthManager());
    sessions = SessionManager();
    getIt.registerSingleton<SessionManager>(sessions);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
      ),
    );
    bridge = SanadProtocolBridge();
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
    await getIt.reset();
  });

  void seed(String sessionId, List<Message> history) {
    sessions.db.saveSession(
      SessionState(
        sessionId: sessionId,
        model: 'gpt-test',
        createdAt: DateTime.parse('2026-10-01T10:00:00Z'),
        updatedAt: DateTime.parse('2026-10-01T10:10:00Z'),
      ),
    );
    sessions.saveSessionHistory(sessionId, history);
  }

  Future<Map<String, dynamic>> history(
    String sessionId, {
    int? limit,
    String? cursor,
  }) async {
    Map<String, dynamic>? emitted;
    await bridge.handleCommand({
      'command': 'get_session_history',
      'payload': {
        'request_id': 'req-history-${cursor ?? 'tail'}',
        'session_id': sessionId,
        'limit': ?limit,
        'cursor': ?cursor,
      },
    }, (envelope) async => emitted = envelope);
    return Map<String, dynamic>.from(emitted!['payload'] as Map);
  }

  Map<String, dynamic> rowWithContent(Map<String, dynamic> payload, String c) =>
      Map<String, dynamic>.from(
        (payload['messages'] as List).singleWhere(
              (row) => (row as Map)['content'] == c,
            )
            as Map,
      );

  test('every unstamped reply that ends its turn hydrates as a final answer '
      'with its footer fields', () async {
    const sessionId = 'session-111-full-page';
    seed(sessionId, [
      _user('m-u1', 'turn-1', 'first question'),
      _reply('m-a1', 'turn-1', 'first answer'),
      _user('m-u2', 'turn-2', 'second question'),
      _reply('m-a2', 'turn-2', 'second answer'),
    ]);

    final payload = await history(sessionId);

    for (final content in ['first answer', 'second answer']) {
      final row = rowWithContent(payload, content);
      expect(row['type'], 'final_answer', reason: content);
      expect(row['message_id'], isNotNull, reason: content);
      expect(row['turn_id'], isNotNull, reason: content);
      expect(row['usage'], {'input_tokens': 10, 'output_tokens': 20});
      expect(row['model'], 'gpt-test');
      expect(row['model_display'], 'GPT Test');
      expect(row['provider'], 'openai');
      expect(row['runtime_ms'], 1200);
      expect(row['context_tokens'], 900);
    }
  });

  test('page boundaries do not decide terminality', () async {
    const sessionId = 'session-111-page-boundary';
    seed(sessionId, [
      _user('m-u1', 'turn-1', 'question'),
      _reply('m-c1', 'turn-1', 'let me look'),
      _reply('m-a1', 'turn-1', 'final answer'),
    ]);

    final tail = await history(sessionId, limit: 1);
    expect(rowWithContent(tail, 'final answer')['type'], 'final_answer');

    // The older page ends on commentary whose successor (outside the page) is
    // more assistant output in the same turn: it must stay a thought.
    final older = await history(
      sessionId,
      limit: 2,
      cursor: tail['next_cursor'] as String,
    );
    final commentary = rowWithContent(older, 'let me look');
    expect(commentary['type'], 'thought');
    expect(commentary.containsKey('usage'), isFalse);
  });

  test(
    'an older page keeps a terminal reply that is not its newest row',
    () async {
      const sessionId = 'session-111-older-page';
      seed(sessionId, [
        _user('m-u1', 'turn-1', 'q1'),
        _reply('m-a1', 'turn-1', 'a1'),
        _user('m-u2', 'turn-2', 'q2'),
        _reply('m-a2', 'turn-2', 'a2'),
        _user('m-u3', 'turn-3', 'q3'),
        _reply('m-a3', 'turn-3', 'a3'),
      ]);

      final tail = await history(sessionId, limit: 2);
      final older = await history(
        sessionId,
        limit: 4,
        cursor: tail['next_cursor'] as String,
      );

      expect(rowWithContent(older, 'a1')['type'], 'final_answer');
      expect(rowWithContent(older, 'a2')['type'], 'final_answer');
      expect(rowWithContent(tail, 'a3')['type'], 'final_answer');
    },
  );

  test(
    'assistant text followed by a steer stays on the Thoughts surface',
    () async {
      const sessionId = 'session-111-steer-row';
      seed(sessionId, [
        _user('m-u1', 'turn-1', 'question'),
        _reply('m-d1', 'turn-1', 'draft'),
        Message(
          role: MessageRole.user,
          content: 'shorter please',
          metadata: const {
            'message_id': 'm-s1',
            'turn_id': 'turn-1',
            'steer': true,
            'request_id': 'steer-1',
          },
        ),
        _reply('m-a1', 'turn-1', 'short answer'),
      ]);

      final payload = await history(sessionId);

      expect(rowWithContent(payload, 'draft')['type'], 'thought');
      expect(rowWithContent(payload, 'short answer')['type'], 'final_answer');
    },
  );
}
