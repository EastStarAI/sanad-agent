/// Stale live-evidence rules for cached thinking descriptors (Task 43 Gate B).
library;

import 'thinking_control_models.dart';

class ThinkingControlStaleEvidence {
  ThinkingControlStaleEvidence._();

  static const liveEvidenceTtl = Duration(minutes: 5);

  static const _failureSources = {
    'live_probe_failed',
    'cache_stale',
    'stale_live_evidence',
  };

  /// Whether [descriptor] carries explicit failure or invalidation provenance
  /// (`live_probe_failed` from a failed live probe, `cache_stale` from a stale
  /// cache write, `stale_live_evidence` from an already-degraded descriptor).
  ///
  /// This evidence stays authoritative regardless of wall-clock age or of a
  /// descriptor the assembler could rebuild from persisted model metadata.
  static bool isInvalidated(ThinkingControlDescriptor descriptor) {
    return _failureSources.contains(descriptor.source);
  }

  static bool isStale(ThinkingControlDescriptor descriptor) {
    if (isInvalidated(descriptor)) {
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
