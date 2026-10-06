import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_search.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionDB db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-session-search-test',
    );
    setSanadHomeOverride(tempDir.path);
    db = SessionDB();
  });

  tearDown(() async {
    db.dispose();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
  });

  void saveSession(
    String id, {
    required String title,
    DateTime? activityAt,
    List<Message> messages = const [],
  }) {
    final timestamp = activityAt ?? DateTime.utc(2026);
    db.saveSession(
      SessionState(
        sessionId: id,
        model: 'model-1',
        title: title,
        createdAt: timestamp,
        updatedAt: timestamp,
        lastUserMessageAt: timestamp,
      ),
    );
    db.replaceMessages(id, messages);
  }

  test('normalizes ASCII case and whitespace while preserving Arabic', () {
    saveSession('english', title: 'Release   Notes');
    saveSession('arabic', title: 'خطة   الإطلاق');

    expect(
      db
          .searchSessions(SessionSearchRequest(query: '  release notes '))
          .hits
          .single
          .session
          .sessionId,
      'english',
    );
    expect(
      db
          .searchSessions(SessionSearchRequest(query: 'خطة الإطلاق'))
          .hits
          .single
          .session
          .sessionId,
      'arabic',
    );
  });

  test(
    'searches user and terminal final content but excludes hidden content',
    () {
      saveSession(
        'visible',
        title: 'Visible',
        messages: [
          Message(role: MessageRole.user, content: 'find user needle'),
          Message(
            role: MessageRole.assistant,
            content: 'find final needle',
            metadata: {'terminal_work_item_id': 'work-1'},
          ),
        ],
      );
      saveSession(
        'hidden',
        title: 'Hidden',
        messages: [
          Message(role: MessageRole.system, content: 'private needle'),
          Message(
            role: MessageRole.assistant,
            content: 'superseded needle',
            metadata: {'superseded_by_steer': true},
          ),
        ],
      );

      final result = db.searchSessions(SessionSearchRequest(query: 'needle'));

      expect(result.hits.map((hit) => hit.session.sessionId), ['visible']);
      expect(result.hits.single.snippet, contains('final needle'));
      expect(
        result.hits.single.anchorEventId,
        matches(r'^history:visible:\d+:final_answer:0$'),
      );
    },
  );

  test('searches visible assistant thought text with a thought anchor', () {
    saveSession(
      'thought-session',
      title: 'Conversation',
      messages: [
        Message(role: MessageRole.assistant, content: 'سأبحث عن الملف'),
        Message(
          role: MessageRole.assistant,
          content: 'Completed.',
          metadata: {'terminal_work_item_id': 'work-1'},
        ),
      ],
    );
    saveSession(
      'reasoning-only',
      title: 'Conversation',
      messages: [
        Message(
          role: MessageRole.assistant,
          reasoning: 'سأبحث داخليًا',
          content: 'Completed.',
          metadata: {'terminal_work_item_id': 'work-2'},
        ),
      ],
    );

    final result = db.searchSessions(SessionSearchRequest(query: 'سأبحث'));

    expect(result.hits.map((hit) => hit.session.sessionId), [
      'thought-session',
    ]);
    expect(result.hits.single.snippet, contains('سأبحث'));
    expect(
      result.hits.single.anchorEventId,
      matches(r'^history:thought-session:\d+:thought:0$'),
    );
  });

  test('returns one newest anchored content match per session', () {
    saveSession(
      'one',
      title: 'Conversation',
      messages: [
        Message(role: MessageRole.user, content: 'needle old'),
        Message(role: MessageRole.user, content: 'needle newest'),
      ],
    );

    final hit = db
        .searchSessions(SessionSearchRequest(query: 'needle'))
        .hits
        .single;

    expect(hit.snippet, contains('needle newest'));
    expect(hit.anchorEventId, matches(r'^history:one:\d+:user_message:0$'));
  });

  test('enforces request and snippet bounds', () {
    expect(() => SessionSearchRequest(query: '   '), throwsArgumentError);
    expect(
      () => SessionSearchRequest(
        query: List.filled(SessionSearchRequest.maxQueryLength + 1, 'x').join(),
      ),
      throwsArgumentError,
    );
    expect(
      () => SessionSearchRequest(
        query: 'x',
        limit: SessionSearchRequest.maxLimit + 1,
      ),
      throwsArgumentError,
    );
    saveSession(
      'bounded',
      title: 'Conversation',
      messages: [
        Message(
          role: MessageRole.user,
          content:
              '${List.filled(250, 'a').join()} needle ${List.filled(250, 'b').join()}',
        ),
      ],
    );

    final snippet = db
        .searchSessions(SessionSearchRequest(query: 'needle'))
        .hits
        .single
        .snippet!;
    expect(
      snippet.length,
      lessThanOrEqualTo(SessionSearchRequest.maxSnippetLength + 2),
    );
  });

  test(
    'paginates without duplicates and rejects a cursor for another query',
    () {
      for (var index = 0; index < 3; index++) {
        saveSession(
          'session-$index',
          title: 'needle $index',
          activityAt: DateTime.utc(2026, 1, index + 1),
        );
      }

      final first = db.searchSessions(
        SessionSearchRequest(query: 'needle', limit: 2),
      );
      final second = db.searchSessions(
        SessionSearchRequest(
          query: 'needle',
          limit: 2,
          cursor: first.nextCursor,
        ),
      );

      expect(first.hasMore, isTrue);
      expect(first.hits.map((hit) => hit.session.sessionId), [
        'session-2',
        'session-1',
      ]);
      expect(second.hits.single.session.sessionId, 'session-0');
      expect(second.hasMore, isFalse);
      expect(
        () => db.searchSessions(
          SessionSearchRequest(query: 'other', cursor: first.nextCursor),
        ),
        throwsArgumentError,
      );
    },
  );
}
