/// Compaction trigger source (Plan 53).
enum CompactionTrigger {
  manual,
  auto,
  overflow;

  String get wireValue => name;
}

/// Compaction lifecycle state. Only [started] is non-terminal.
enum CompactionStatus {
  started,
  completed,
  failed;

  String get wireValue => name;

  bool get isTerminal => this == completed || this == failed;
}

/// Typed, redactable compaction failures for persistence and protocol.
enum CompactionFailureReason {
  sessionBusy,
  compactionInProgress,
  claimLost,
  sourceRevisionStale,
  summarizationFailed,
  continuityValidationFailed,
  projectionStillOverBudget,
  persistenceFailed,
  interrupted;

  String get wireValue {
    switch (this) {
      case CompactionFailureReason.sessionBusy:
        return 'session_busy';
      case CompactionFailureReason.compactionInProgress:
        return 'compaction_in_progress';
      case CompactionFailureReason.claimLost:
        return 'claim_lost';
      case CompactionFailureReason.sourceRevisionStale:
        return 'source_revision_stale';
      case CompactionFailureReason.summarizationFailed:
        return 'summarization_failed';
      case CompactionFailureReason.continuityValidationFailed:
        return 'continuity_validation_failed';
      case CompactionFailureReason.projectionStillOverBudget:
        return 'projection_still_over_budget';
      case CompactionFailureReason.persistenceFailed:
        return 'persistence_failed';
      case CompactionFailureReason.interrupted:
        return 'interrupted';
    }
  }

  static CompactionFailureReason? fromWire(String? value) {
    if (value == null) return null;
    for (final reason in values) {
      if (reason.wireValue == value || reason.name == value) {
        return reason;
      }
    }
    return null;
  }
}

/// How request pressure was measured relative to provider-confirmed usage.
enum CompactionMeasurementKind {
  estimated,
  confirmed,
  mixed;

  String get wireValue => name;
}
