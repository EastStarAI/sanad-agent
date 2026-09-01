import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_history_page.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionDB db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sanad-history-page-test');
    setSanadHomeOverride(tempDir.path);
    db = SessionDB();
    db.saveSession(
      SessionState(
        sessionId: 'session-1',
        model: 'model-1',
        title: 'Long conversation',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
  });

  tearDown(() async {
    db.dispose();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
  });

  List<Message> messages(int count, {int start = 1}) => [
    for (var index = start; index < start + count; index++)
      Message(role: MessageRole.user, content: 'message-$index'),
  ];

  test('returns the newest bounded page in chronological order', () {
    db.replaceMessages('session-1', messages(5));

    final page = db.getPersistedMessagePage('session-1', limit: 2);

    expect(page.messages.map((entry) => entry.message.content), [
      'message-4',
      'message-5',
    ]);
    expect(page.hasMore, isTrue);
    expect(page.nextCursor, isNotNull);
  });

  test('walks older pages without gaps or duplicates', () {
    db.replaceMessages('session-1', messages(5));

    final newest = db.getPersistedMessagePage('session-1', limit: 2);
    final middle = db.getPersistedMessagePage(
      'session-1',
      limit: 2,
      cursor: newest.nextCursor,
    );
    final oldest = db.getPersistedMessagePage(
      'session-1',
      limit: 2,
      cursor: middle.nextCursor,
    );

    expect(middle.messages.map((entry) => entry.message.content), [
      'message-2',
      'message-3',
    ]);
    expect(middle.hasMore, isTrue);
    expect(oldest.messages.single.message.content, 'message-1');
    expect(oldest.hasMore, isFalse);
    expect(oldest.nextCursor, isNull);
  });

  test('allows concurrent tail append while a stable older cursor is used', () {
    db.replaceMessages('session-1', messages(5));
    final newest = db.getPersistedMessagePage('session-1', limit: 2);

    db.replaceMessages('session-1', messages(6));
    final older = db.getPersistedMessagePage(
      'session-1',
      limit: 2,
      cursor: newest.nextCursor,
    );

    expect(older.messages.map((entry) => entry.message.content), [
      'message-2',
      'message-3',
    ]);
    expect(older.historyRevision, greaterThan(newest.historyRevision));
  });

  test('rejects cursor when its durable boundary was rewritten', () {
    db.replaceMessages('session-1', messages(5));
    final newest = db.getPersistedMessagePage('session-1', limit: 2);

    db.replaceMessages('session-1', [
      ...messages(3),
      Message(role: MessageRole.user, content: 'rewritten-4'),
      Message(role: MessageRole.user, content: 'message-5'),
    ]);

    expect(
      () => db.getPersistedMessagePage(
        'session-1',
        limit: 2,
        cursor: newest.nextCursor,
      ),
      throwsA(
        isA<SessionHistoryCursorStaleException>().having(
          (error) => error.reason,
          'reason',
          'cursor_boundary_missing',
        ),
      ),
    );
  });

  test('rejects malformed and cross-session cursors', () {
    db.replaceMessages('session-1', messages(3));
    final page = db.getPersistedMessagePage('session-1', limit: 1);
    db.saveSession(
      SessionState(
        sessionId: 'session-2',
        model: 'model-1',
        title: 'Other',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );

    expect(
      () => db.getPersistedMessagePage('session-1', cursor: 'not-a-cursor'),
      throwsA(isA<SessionHistoryCursorFormatException>()),
    );
    expect(
      () => db.getPersistedMessagePage('session-2', cursor: page.nextCursor),
      throwsA(
        isA<SessionHistoryCursorStaleException>().having(
          (error) => error.reason,
          'reason',
          'cursor_session_mismatch',
        ),
      ),
    );
  });

  test('loads a bounded page ending at a stable anchor row', () {
    db.replaceMessages('session-1', messages(6));
    final persisted = db.getPersistedMessages('session-1');
    final anchor = persisted[3];

    final page = db.getPersistedMessagePage(
      'session-1',
      limit: 2,
      anchorRowId: anchor.rowId,
    );

    expect(page.messages.map((entry) => entry.message.content), [
      'message-3',
      'message-4',
    ]);
    expect(page.hasMore, isTrue);
  });

  test('rejects a missing anchor without revealing another session', () {
    db.replaceMessages('session-1', messages(2));

    expect(
      () => db.getPersistedMessagePage('session-1', anchorRowId: 999999),
      throwsA(isA<SessionHistoryAnchorNotFoundException>()),
    );
  });

  test('byte cap retains one oversized record and advances the cursor', () {
    db.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'old'),
      Message(role: MessageRole.user, content: 'x' * 200),
    ]);

    final page = db.getPersistedMessagePage(
      'session-1',
      limit: 10,
      maxPersistedBytes: 32,
    );

    expect(page.messages, hasLength(1));
    expect(page.messages.single.message.content, 'x' * 200);
    expect(page.persistedBytes, greaterThan(32));
    expect(page.hasMore, isTrue);
    expect(page.nextCursor, isNotNull);
  });

  test('typed request validates modes and extracts a session-bound anchor', () {
    final request = SessionHistoryRequest.fromPayload({
      'limit': 25,
      'anchor_event_id': 'history:session-1:42:final_answer:0',
    });

    expect(request.limit, 25);
    expect(request.anchorRowIdForSession('session-1'), 42);
    expect(
      () => request.anchorRowIdForSession('session-2'),
      throwsA(isA<SessionHistoryAnchorNotFoundException>()),
    );
    expect(
      () => SessionHistoryRequest.fromPayload({
        'cursor': 'cursor',
        'anchor_event_id': 'history:session-1:42:user_message:0',
      }),
      throwsFormatException,
    );
  });

  test('100, 1,000, and 10,000-row initial queries remain bounded', () {
    for (final count in [100, 1000, 10000]) {
      db.replaceMessages('session-1', messages(count));
      final stopwatch = Stopwatch()..start();

      final page = db.getPersistedMessagePage('session-1');
      stopwatch.stop();

      expect(page.messages, hasLength(defaultSessionHistoryPageSize));
      expect(
        page.persistedBytes,
        lessThanOrEqualTo(defaultSessionHistoryPageBytes),
      );
      expect(page.messages.first.message.content, 'message-${count - 99}');
      expect(page.messages.last.message.content, 'message-$count');
      expect(page.hasMore, count > defaultSessionHistoryPageSize);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    }
  });

  test('rejects non-positive and oversized limits', () {
    expect(
      () => db.getPersistedMessagePage('session-1', limit: 0),
      throwsRangeError,
    );
    expect(
      () => db.getPersistedMessagePage(
        'session-1',
        limit: maxSessionHistoryPageSize + 1,
      ),
      throwsRangeError,
    );
  });
}
