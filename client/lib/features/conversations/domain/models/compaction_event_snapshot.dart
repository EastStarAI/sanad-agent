import 'package:equatable/equatable.dart';

enum CompactionLifecycleStatus {
  started,
  completed,
  failed;

  static CompactionLifecycleStatus fromWire(Object? value) => switch (value?.toString()) {
    'started' => CompactionLifecycleStatus.started,
    'completed' => CompactionLifecycleStatus.completed,
    'failed' => CompactionLifecycleStatus.failed,
    final other => throw FormatException('Unknown compaction status: $other'),
  };
}

enum CompactionTriggerKind {
  manual,
  auto,
  overflow;

  static CompactionTriggerKind fromWire(Object? value) => switch (value?.toString()) {
    'manual' => CompactionTriggerKind.manual,
    'auto' => CompactionTriggerKind.auto,
    'overflow' => CompactionTriggerKind.overflow,
    final other => throw FormatException('Unknown compaction trigger: $other'),
  };

  bool get isAutoLike => this == auto || this == overflow;
}

class CompactionEventSnapshot extends Equatable {
  final String sessionId;
  final String compactionId;
  final CompactionLifecycleStatus status;
  final CompactionTriggerKind trigger;
  final String? failureReason;
  final int? contextWindowTokens;
  final int? effectiveInputBudgetTokens;
  final int? autoThresholdTokens;
  final int? estimatedRequestTokensBefore;
  final int? estimatedRequestTokensAfter;
  final String? beforeMeasurementKind;
  final int? providerConfirmedRequestTokensAfter;
  final int? retainedTailTokens;
  final int? durationMs;
  final DateTime? startedAt;
  final DateTime? completedAt;

  const CompactionEventSnapshot({
    required this.sessionId,
    required this.compactionId,
    required this.status,
    required this.trigger,
    this.failureReason,
    this.contextWindowTokens,
    this.effectiveInputBudgetTokens,
    this.autoThresholdTokens,
    this.estimatedRequestTokensBefore,
    this.estimatedRequestTokensAfter,
    this.beforeMeasurementKind,
    this.providerConfirmedRequestTokensAfter,
    this.retainedTailTokens,
    this.durationMs,
    this.startedAt,
    this.completedAt,
  });

  factory CompactionEventSnapshot.fromJson(
    Map<String, dynamic> json, {
    String? expectedSessionId,
    CompactionLifecycleStatus? expectedStatus,
  }) {
    final sessionId = _requiredString(json['session_id'], 'session_id');
    if (expectedSessionId != null && sessionId != expectedSessionId) {
      throw FormatException(
        'Compaction snapshot session_id $sessionId does not match $expectedSessionId.',
      );
    }
    final compactionId = _requiredString(json['compaction_id'], 'compaction_id');
    final status = CompactionLifecycleStatus.fromWire(json['status']);
    if (expectedStatus != null && status != expectedStatus) {
      throw FormatException(
        'Compaction snapshot status $status does not match $expectedStatus.',
      );
    }
    return CompactionEventSnapshot(
      sessionId: sessionId,
      compactionId: compactionId,
      status: status,
      trigger: CompactionTriggerKind.fromWire(json['trigger'] ?? 'manual'),
      failureReason: _nullableString(json['failure_reason']),
      contextWindowTokens: _nullableInt(json['context_window_tokens']),
      effectiveInputBudgetTokens: _nullableInt(
        json['effective_input_budget_tokens'],
      ),
      autoThresholdTokens: _nullableInt(json['auto_threshold_tokens']),
      estimatedRequestTokensBefore: _nullableInt(
        json['estimated_request_tokens_before'],
      ),
      estimatedRequestTokensAfter: _nullableInt(
        json['estimated_request_tokens_after'],
      ),
      beforeMeasurementKind: _nullableString(json['before_measurement_kind']),
      providerConfirmedRequestTokensAfter: _nullableInt(
        json['provider_confirmed_request_tokens_after'],
      ),
      retainedTailTokens: _nullableInt(json['retained_tail_tokens']),
      durationMs: _nullableInt(json['duration_ms']),
      startedAt: _nullableDate(json['started_at']),
      completedAt: _nullableDate(json['completed_at']),
    );
  }

  String get logicalEventId => 'compaction_$compactionId';

  String get timelineLabel => switch ((trigger.isAutoLike, status)) {
    (false, CompactionLifecycleStatus.started) => 'Context compacting',
    (true, CompactionLifecycleStatus.started) => 'Auto context compacting',
    (false, CompactionLifecycleStatus.completed) => 'Context compacted',
    (true, CompactionLifecycleStatus.completed) => 'Auto context compacted',
    (false, CompactionLifecycleStatus.failed) => 'Context compaction failed',
    (true, CompactionLifecycleStatus.failed) => 'Auto context compaction failed',
  };

  String get detailTriggerLabel => switch (trigger) {
    CompactionTriggerKind.manual => 'Manual',
    CompactionTriggerKind.auto => 'Auto',
    CompactionTriggerKind.overflow => 'Context overflow',
  };

  int? get reclaimedTokens {
    final before = estimatedRequestTokensBefore;
    final after = estimatedRequestTokensAfter;
    if (before == null || after == null || before <= after) {
      return null;
    }
    return before - after;
  }

  static String _requiredString(Object? value, String field) {
    final normalized = _nullableString(value);
    if (normalized == null) {
      throw FormatException('$field is required for compaction snapshot.');
    }
    return normalized;
  }

  static String? _nullableString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static int? _nullableInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static DateTime? _nullableDate(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  @override
  List<Object?> get props => [
    sessionId,
    compactionId,
    status,
    trigger,
    failureReason,
    contextWindowTokens,
    effectiveInputBudgetTokens,
    autoThresholdTokens,
    estimatedRequestTokensBefore,
    estimatedRequestTokensAfter,
    beforeMeasurementKind,
    providerConfirmedRequestTokensAfter,
    retainedTailTokens,
    durationMs,
    startedAt,
    completedAt,
  ];
}

class SessionCompactResult extends Equatable {
  final String outcome;
  final String? failureReason;
  final String? compactionId;

  const SessionCompactResult({
    required this.outcome,
    this.failureReason,
    this.compactionId,
  });

  factory SessionCompactResult.fromJson(Map<String, dynamic> json) {
    return SessionCompactResult(
      outcome: json['outcome']?.toString() ?? 'failed',
      failureReason: json['failure_reason']?.toString(),
      compactionId: json['compaction_id']?.toString(),
    );
  }

  bool get accepted => outcome == 'accepted';

  bool get sessionBusy => outcome == 'session_busy';

  bool get compactionInProgress => outcome == 'compaction_in_progress';

  @override
  List<Object?> get props => [outcome, failureReason, compactionId];
}
