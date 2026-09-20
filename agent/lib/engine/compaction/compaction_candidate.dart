import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';

import 'compaction_enums.dart';
import 'compaction_identities.dart';
import 'compaction_metrics.dart';
import 'compaction_summary.dart';

/// Immutable compaction result produced by the engine before durable activation.
@immutable
class CompactionCandidate {
  final String compactionId;
  final String sessionId;
  final CompactionTrigger trigger;
  final CompactionHistoryRevision sourceRevision;
  final CompactionMessageRange sourceRange;
  final CompactionMessageRange retainedTailRange;
  final CompactionInternalSummary internalSummary;
  final CompactionContinuityResult continuityResult;
  final CompactionMetrics metrics;
  final RouteSignature routeSignature;

  CompactionCandidate({
    required this.compactionId,
    required this.sessionId,
    required this.trigger,
    required this.sourceRevision,
    required this.sourceRange,
    required this.retainedTailRange,
    required this.internalSummary,
    required this.continuityResult,
    required this.metrics,
    required this.routeSignature,
  }) : assert(compactionId.isNotEmpty, 'compactionId must be non-empty'),
       assert(sessionId.isNotEmpty, 'sessionId must be non-empty'),
       assert(
         continuityResult.passed,
         'candidate requires passed continuity validation',
       );

  /// Ensures summarized head ends before retained tail begins.
  bool get rangesAreOrdered =>
      sourceRange.end.rowId < retainedTailRange.start.rowId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionCandidate &&
          runtimeType == other.runtimeType &&
          compactionId == other.compactionId &&
          sessionId == other.sessionId &&
          trigger == other.trigger &&
          sourceRevision == other.sourceRevision &&
          sourceRange == other.sourceRange &&
          retainedTailRange == other.retainedTailRange &&
          internalSummary == other.internalSummary &&
          continuityResult == other.continuityResult &&
          metrics == other.metrics &&
          routeSignature == other.routeSignature;

  @override
  int get hashCode => Object.hash(
    compactionId,
    sessionId,
    trigger,
    sourceRevision,
    sourceRange,
    retainedTailRange,
    internalSummary,
    continuityResult,
    metrics,
    routeSignature,
  );
}
