import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/compaction_lifecycle_broadcaster.dart';

/// Late-bound sink so compaction lifecycle can reach [GatewayManager] without DI cycles.
abstract final class CompactionLifecycleRelay {
  static CompactionLifecycleSink? sink;

  static void publish(CompactionLifecycleEvent event) {
    final deliver = sink;
    if (deliver == null) {
      return;
    }
    CompactionLifecycleBroadcaster(deliver).handle(event);
  }
}
