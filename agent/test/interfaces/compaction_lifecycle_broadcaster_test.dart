import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/compaction_lifecycle_broadcaster.dart';
import 'package:test/test.dart';

void main() {
  test('lifecycle transitions use distinct transport event ids', () {
    final responses = <GatewayResponse>[];
    final broadcaster = CompactionLifecycleBroadcaster(responses.add);
    final startedAt = DateTime.utc(2026, 8, 30);

    broadcaster.handle(
      CompactionLifecycleEvent(
        compactionId: 'cmp-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        status: CompactionStatus.started,
        startedAt: startedAt,
      ),
    );
    broadcaster.handle(
      CompactionLifecycleEvent(
        compactionId: 'cmp-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        status: CompactionStatus.completed,
        startedAt: startedAt,
        completedAt: startedAt.add(const Duration(seconds: 1)),
      ),
    );
    broadcaster.handle(
      CompactionLifecycleEvent(
        compactionId: 'cmp-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        status: CompactionStatus.failed,
        failureReason: CompactionFailureReason.summarizationFailed,
        startedAt: startedAt,
        completedAt: startedAt.add(const Duration(seconds: 2)),
      ),
    );

    expect(responses, hasLength(3));
    expect(responses.map((response) => response.eventId), [
      'context_compaction:cmp-1:started',
      'context_compaction:cmp-1:completed',
      'context_compaction:cmp-1:failed',
    ]);
    for (final response in responses) {
      final payload = response.message.metadata?['canonical_payload'] as Map;
      expect(payload['compaction_id'], 'cmp-1');
    }
  });
}
