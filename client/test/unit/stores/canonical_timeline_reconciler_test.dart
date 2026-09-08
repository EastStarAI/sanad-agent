import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/canonical_timeline_reconciler.dart';

void main() {
  CanonicalEvent user({
    required String id,
    required String text,
    required DateTime at,
    String? messageId,
    String? requestId,
  }) => CanonicalEvent(
    id: id,
    kind: EventKind.userMessage,
    text: text,
    timestamp: at,
    sessionId: 'session-1',
    metadata: {
      if (messageId != null) 'message_id': messageId,
      if (requestId != null) 'request_id': requestId,
    },
  );

  test('authoritative slice removes a live duplicate and corrects its order', () {
    final at = DateTime.utc(2026, 9, 8, 10);
    final retained = [
      CanonicalEvent(
        id: 'live-tool',
        kind: EventKind.toolCall,
        timestamp: at,
        sessionId: 'session-1',
        toolCallId: 'tool-1',
      ),
      user(
        id: 'live-user',
        text: 'Restart the agent',
        at: at,
        messageId: 'message-1',
        requestId: 'request-1',
      ),
      CanonicalEvent(
        id: 'live-final',
        kind: EventKind.finalAnswer,
        text: 'Done',
        timestamp: at,
        sessionId: 'session-1',
        runId: 'run-1',
      ),
    ];
    final authoritative = [
      user(
        id: 'history-user',
        text: 'Restart the agent',
        at: at,
        messageId: 'message-1',
        requestId: 'request-1',
      ),
      CanonicalEvent(
        id: 'history-tool',
        kind: EventKind.toolCall,
        timestamp: at,
        sessionId: 'session-1',
        toolCallId: 'tool-1',
      ),
      CanonicalEvent(
        id: 'history-final',
        kind: EventKind.finalAnswer,
        text: 'Done',
        timestamp: at,
        sessionId: 'session-1',
        runId: 'run-1',
      ),
    ];

    final merged = CanonicalTimelineReconciler.mergeAuthoritativeSlice(
      retained,
      authoritative,
    );

    expect(merged.map((event) => event.id), [
      'history-user',
      'history-tool',
      'history-final',
    ]);
    expect(merged.where((event) => event.messageId == 'message-1'), hasLength(1));
  });

  test('shared transport or message identity never merges different kinds', () {
    final at = DateTime.utc(2026, 9, 8, 10);
    final merged = CanonicalTimelineReconciler.fold([
      user(
        id: 'shared-event',
        text: 'Question',
        at: at,
        messageId: 'shared-message',
      ),
      CanonicalEvent(
        id: 'shared-event',
        kind: EventKind.finalAnswer,
        text: 'Answer',
        timestamp: at,
        sessionId: 'session-1',
        metadata: const {'message_id': 'shared-message'},
      ),
    ]);

    expect(merged, hasLength(2));
  });

  test('tool use and result merge by tool call despite distinct message ids', () {
    final at = DateTime.utc(2026, 9, 8, 10);
    final merged = CanonicalTimelineReconciler.fold([
      CanonicalEvent(
        id: 'tool-use',
        kind: EventKind.toolCall,
        status: EventStatus.running,
        timestamp: at,
        sessionId: 'session-1',
        toolCallId: 'tool-1',
        tool: const {'name': 'shell_execute', 'input': 'pwd'},
        metadata: const {'message_id': 'assistant-message'},
      ),
      CanonicalEvent(
        id: 'tool-result',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        timestamp: at.add(const Duration(seconds: 1)),
        sessionId: 'session-1',
        toolCallId: 'tool-1',
        tool: const {'output': 'ok'},
        metadata: const {'message_id': 'tool-message'},
      ),
    ]);

    expect(merged, hasLength(1));
    expect(merged.single.toolInput, 'pwd');
    expect(merged.single.toolOutput, 'ok');
  });

  test('same text with different durable identities remains two messages', () {
    final at = DateTime.utc(2026, 9, 8, 10);
    final merged = CanonicalTimelineReconciler.fold([
      user(
        id: 'message-a-event',
        text: 'Repeat',
        at: at,
        messageId: 'message-a',
        requestId: 'request-a',
      ),
      user(
        id: 'message-b-event',
        text: 'Repeat',
        at: at,
        messageId: 'message-b',
        requestId: 'request-b',
      ),
    ], allowLegacyUserFallback: true);

    expect(merged, hasLength(2));
  });

  test('legacy fallback is bounded by session text and timestamp', () {
    final at = DateTime.utc(2026, 9, 8, 10);
    final merged = CanonicalTimelineReconciler.fold([
      user(
        id: 'live-legacy',
        text: 'Legacy',
        at: at,
        requestId: 'request-live',
      ),
      user(
        id: 'history-legacy',
        text: 'Legacy',
        at: at.add(const Duration(milliseconds: 500)),
      ),
      user(
        id: 'later-legacy',
        text: 'Legacy',
        at: at.add(const Duration(seconds: 2)),
      ),
    ], allowLegacyUserFallback: true);

    expect(merged.map((event) => event.id), [
      'history-legacy',
      'later-legacy',
    ]);
  });
}
