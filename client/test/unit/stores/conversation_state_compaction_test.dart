import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_state.dart';

CanonicalEvent _compactionEvent({
  required String compactionId,
  required String status,
  required String text,
  EventStatus eventStatus = EventStatus.running,
}) {
  return CanonicalEvent(
    id: 'compaction_$compactionId',
    kind: EventKind.informational,
    status: eventStatus,
    text: text,
    timestamp: DateTime.utc(2026, 8, 29),
    sessionId: 'session-1',
    metadata: {
      'compaction_event': true,
      'compaction_id': compactionId,
      'compaction_status': status,
      'compaction_trigger': 'manual',
    },
  );
}

void main() {
  group('ConversationState compaction lifecycle', () {
    test('completed replaces started for the same compaction id', () {
      final state = ConversationState();
      state.apply(
        _compactionEvent(
          compactionId: 'cmp-1',
          status: 'started',
          text: 'Context compacting',
        ),
      );
      state.apply(
        _compactionEvent(
          compactionId: 'cmp-1',
          status: 'completed',
          text: 'Context compacted',
          eventStatus: EventStatus.done,
        ),
      );

      expect(state.events, hasLength(1));
      expect(state.events.single.text, 'Context compacted');
      expect(state.events.single.status, EventStatus.done);
      expect(state.events.single.metadata?['compaction_status'], 'completed');
    });

    test('rejects terminal regression when completed already applied', () {
      final state = ConversationState();
      state.apply(
        _compactionEvent(
          compactionId: 'cmp-2',
          status: 'completed',
          text: 'Context compacted',
          eventStatus: EventStatus.done,
        ),
      );
      state.apply(
        _compactionEvent(
          compactionId: 'cmp-2',
          status: 'started',
          text: 'Context compacting',
        ),
      );

      expect(state.events, hasLength(1));
      expect(state.events.single.metadata?['compaction_status'], 'completed');
    });

    test('history hydration folds started then completed into one tile', () {
      final state = ConversationState();
      state.setHistory([
        _compactionEvent(
          compactionId: 'cmp-3',
          status: 'started',
          text: 'Auto context compacting',
        ),
        _compactionEvent(
          compactionId: 'cmp-3',
          status: 'completed',
          text: 'Auto context compacted',
          eventStatus: EventStatus.done,
        ),
      ]);

      expect(state.events, hasLength(1));
      expect(state.events.single.text, 'Auto context compacted');
    });
  });
}
