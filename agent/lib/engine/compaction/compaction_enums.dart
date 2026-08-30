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

  String get wireValue => name;
}

/// How request pressure was measured relative to provider-confirmed usage.
enum CompactionMeasurementKind {
  estimated,
  confirmed,
  mixed;

  String get wireValue => name;
}
