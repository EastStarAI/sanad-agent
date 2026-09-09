import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';

void main() {
  group('CompactionEventSnapshot', () {
    test('timeline labels distinguish manual and auto triggers', () {
      const manualStarted = CompactionEventSnapshot(
        sessionId: 's1',
        compactionId: 'c1',
        status: CompactionLifecycleStatus.started,
        trigger: CompactionTriggerKind.manual,
      );
      const autoCompleted = CompactionEventSnapshot(
        sessionId: 's1',
        compactionId: 'c1',
        status: CompactionLifecycleStatus.completed,
        trigger: CompactionTriggerKind.auto,
      );
      const overflowFailed = CompactionEventSnapshot(
        sessionId: 's1',
        compactionId: 'c2',
        status: CompactionLifecycleStatus.failed,
        trigger: CompactionTriggerKind.overflow,
      );

      expect(manualStarted.timelineLabel, 'Context compacting');
      expect(autoCompleted.timelineLabel, 'Auto context compacted');
      expect(overflowFailed.timelineLabel, 'Auto context compaction failed');
      expect(overflowFailed.detailTriggerLabel, 'Context overflow');
    });

    test('logicalEventId is stable per compaction and status', () {
      final started = CompactionEventSnapshot.fromJson(const {
        'session_id': 'session-1',
        'compaction_id': 'cmp-42',
        'status': 'started',
        'trigger': 'manual',
      });
      final completed = CompactionEventSnapshot.fromJson(const {
        'session_id': 'session-1',
        'compaction_id': 'cmp-42',
        'status': 'completed',
        'trigger': 'manual',
      });

      expect(started.logicalEventId, 'compaction_cmp-42');
      expect(completed.logicalEventId, 'compaction_cmp-42');
      expect(started.logicalEventId, completed.logicalEventId);
    });

    test('rejects session mismatch for hydration safety', () {
      expect(
        () => CompactionEventSnapshot.fromJson(
          const {
            'session_id': 'session-a',
            'compaction_id': 'cmp-1',
            'status': 'started',
          },
          expectedSessionId: 'session-b',
        ),
        throwsFormatException,
      );
    });

    test('computes reclaimed tokens only when after is lower', () {
      const withSavings = CompactionEventSnapshot(
        sessionId: 's1',
        compactionId: 'c1',
        status: CompactionLifecycleStatus.completed,
        trigger: CompactionTriggerKind.manual,
        estimatedRequestTokensBefore: 80_000,
        estimatedRequestTokensAfter: 20_000,
      );
      const noSavings = CompactionEventSnapshot(
        sessionId: 's1',
        compactionId: 'c2',
        status: CompactionLifecycleStatus.completed,
        trigger: CompactionTriggerKind.manual,
        estimatedRequestTokensBefore: 20_000,
        estimatedRequestTokensAfter: 25_000,
      );

      expect(withSavings.reclaimedTokens, 60_000);
      expect(noSavings.reclaimedTokens, isNull);
    });
  });
}
