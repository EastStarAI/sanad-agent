/// Stale live-evidence rules for cached thinking descriptors (Task 43 Gate B).
library;

import 'thinking_control_models.dart';

class ThinkingControlStaleEvidence {
  ThinkingControlStaleEvidence._();

  static const liveEvidenceTtl = Duration(minutes: 5);

  static bool isStale(ThinkingControlDescriptor descriptor) {
    if (descriptor.source == 'live_probe_failed' ||
        descriptor.source == 'cache_stale' ||
        descriptor.source == 'stale_live_evidence') {
      return true;
    }
    if (descriptor.source != 'live') {
      return false;
    }
    final observedAt = descriptor.observedAt;
    if (observedAt == null) {
      return true;
    }
    return DateTime.now().toUtc().difference(observedAt.toUtc()) > liveEvidenceTtl;
  }

  static ThinkingControlDescriptor freshUnknown({
    required String capabilityRevision,
  }) {
    return ThinkingControlDescriptor.unknown(
      capabilityRevision: capabilityRevision,
      source: 'stale_live_evidence',
    );
  }
}
