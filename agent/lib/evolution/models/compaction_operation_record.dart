import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

/// Durable compaction operation row shape (Plan 53b).
///
/// Maps to `session_compaction_operations` rows.
/// [CompactionBoundaryRepository] owns SQL persistence.
class CompactionOperationRecord {
  final String compactionId;
  final String sessionId;
  final CompactionTrigger trigger;
  final CompactionStatus status;
  final CompactionHistoryRevision sourceHistoryRevision;
  final CompactionMessageRange sourceRange;
  final CompactionMessageRange retainedTailRange;
  final RouteSignature routeSignature;
  final CompactionMetrics? metrics;
  final CompactionInternalSummary? internalSummary;
  final CompactionFailureReason? failureReason;
  final String? failureDetailJson;
  final DateTime startedAt;
  final DateTime? completedAt;

  CompactionOperationRecord({
    required this.compactionId,
    required this.sessionId,
    required this.trigger,
    required this.status,
    required this.sourceHistoryRevision,
    required this.sourceRange,
    required this.retainedTailRange,
    required this.routeSignature,
    this.metrics,
    this.internalSummary,
    this.failureReason,
    this.failureDetailJson,
    required this.startedAt,
    this.completedAt,
  }) : assert(compactionId.isNotEmpty),
       assert(sessionId.isNotEmpty),
       assert(
         status == CompactionStatus.started
             ? completedAt == null &&
                   internalSummary == null &&
                   metrics == null &&
                   failureReason == null
             : completedAt != null,
       ),
       assert(
         status == CompactionStatus.completed
             ? internalSummary != null &&
                   metrics != null &&
                   failureReason == null
             : true,
       ),
       assert(
         status == CompactionStatus.failed
             ? failureReason != null && internalSummary == null
             : true,
       ),
       assert(sourceRange.end.rowId < retainedTailRange.start.rowId);

  bool get isTerminal => status.isTerminal;

  bool get isAuthoritativeProjection =>
      status == CompactionStatus.completed && internalSummary != null;

  /// Converts a validated engine candidate into a completed durable row.
  factory CompactionOperationRecord.fromCandidate({
    required CompactionCandidate candidate,
    required DateTime startedAt,
    required DateTime completedAt,
  }) {
    return CompactionOperationRecord(
      compactionId: candidate.compactionId,
      sessionId: candidate.sessionId,
      trigger: candidate.trigger,
      status: CompactionStatus.completed,
      sourceHistoryRevision: candidate.sourceRevision,
      sourceRange: candidate.sourceRange,
      retainedTailRange: candidate.retainedTailRange,
      routeSignature: candidate.routeSignature,
      metrics: candidate.metrics,
      internalSummary: candidate.internalSummary,
      startedAt: startedAt,
      completedAt: completedAt,
    );
  }

  CompactionOperationRecord copyWithTerminalFailure({
    required CompactionFailureReason failureReason,
    required DateTime completedAt,
    String? failureDetailJson,
  }) {
    assert(status == CompactionStatus.started);
    return CompactionOperationRecord(
      compactionId: compactionId,
      sessionId: sessionId,
      trigger: trigger,
      status: CompactionStatus.failed,
      sourceHistoryRevision: sourceHistoryRevision,
      sourceRange: sourceRange,
      retainedTailRange: retainedTailRange,
      routeSignature: routeSignature,
      failureReason: failureReason,
      failureDetailJson: failureDetailJson,
      startedAt: startedAt,
      completedAt: completedAt,
    );
  }
}

/// Monotonic session history revision used for compaction CAS (B1).
///
/// Bumped atomically whenever canonical message rows are inserted, deleted, or
/// replaced through evolution-owned writers (`session_execution_state_coordinator`,
/// `SessionDB.replaceMessages`). Compaction snapshots store the revision at claim
/// time; activation succeeds only when the live revision still matches.
class SessionHistoryRevision {
  final int value;

  const SessionHistoryRevision(this.value)
    : assert(value >= 0, 'history revision must be non-negative');

  SessionHistoryRevision next() => SessionHistoryRevision(value + 1);

  CompactionHistoryRevision toCompactionRevision() =>
      CompactionHistoryRevision(value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionHistoryRevision &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// Rules for whether a completed boundary may still drive model projection.
abstract final class CompactionBoundaryValidity {
  CompactionBoundaryValidity._();

  /// Returns false when canonical history no longer contains the referenced rows
  /// or when [currentRevision] proves the snapshot head was superseded.
  static bool isProjectionEligible({
    required CompactionOperationRecord boundary,
    required Set<int> existingMessageRowIds,
    required SessionHistoryRevision currentRevision,
  }) {
    if (!boundary.isAuthoritativeProjection) {
      return false;
    }
    if (hasConflictingMessageRowIds(
      boundary: boundary,
      existingMessageRowIds: existingMessageRowIds,
    )) {
      return false;
    }
    if (_hasMissingRows(
      boundary: boundary,
      existingMessageRowIds: existingMessageRowIds,
    )) {
      return false;
    }
    return boundary.sourceHistoryRevision.value <= currentRevision.value;
  }

  /// True when exactly one durable endpoint of a boundary range remains.
  ///
  /// `messages.id` is globally AUTOINCREMENT and edit/retry may leave numeric
  /// gaps, so integers between the endpoints are not expected identities.
  /// Both endpoints missing is treated as superseded history (skip to an older
  /// boundary or canonical fallback).
  static bool hasConflictingMessageRowIds({
    required CompactionOperationRecord boundary,
    required Set<int> existingMessageRowIds,
  }) {
    for (final range in [boundary.sourceRange, boundary.retainedTailRange]) {
      final startPresent = existingMessageRowIds.contains(range.start.rowId);
      final endPresent = existingMessageRowIds.contains(range.end.rowId);
      if (startPresent != endPresent) {
        return true;
      }
    }
    return false;
  }

  static bool _rangeRowsMissing(
    CompactionMessageRange range,
    Set<int> existingMessageRowIds,
  ) {
    return !existingMessageRowIds.contains(range.start.rowId) ||
        !existingMessageRowIds.contains(range.end.rowId);
  }

  static bool _hasMissingRows({
    required CompactionOperationRecord boundary,
    required Set<int> existingMessageRowIds,
  }) {
    return _rangeRowsMissing(boundary.sourceRange, existingMessageRowIds) ||
        _rangeRowsMissing(boundary.retainedTailRange, existingMessageRowIds);
  }
}
