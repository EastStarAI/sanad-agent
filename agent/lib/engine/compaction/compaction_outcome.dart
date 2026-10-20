import 'package:meta/meta.dart';

import 'compaction_candidate.dart';
import 'compaction_enums.dart';

/// Terminal compaction result consumed by orchestration and protocol mappers.
@immutable
class CompactionOutcome {
  final String compactionId;
  final CompactionStatus status;
  final CompactionTrigger trigger;
  final CompactionFailureReason? failureReason;
  final String? failureStage;
  final String? failureCause;
  final Map<String, dynamic>? failureDetail;
  final CompactionCandidate? candidate;
  final int queuedMessagesAccepted;

  CompactionOutcome({
    required this.compactionId,
    required this.status,
    required this.trigger,
    this.failureReason,
    this.failureStage,
    this.failureCause,
    this.failureDetail,
    this.candidate,
    this.queuedMessagesAccepted = 0,
  }) : assert(compactionId.isNotEmpty, 'compactionId must be non-empty'),
       assert(status.isTerminal, 'outcome requires terminal status'),
       assert(
         status == CompactionStatus.failed
             ? failureReason != null && candidate == null
             : failureReason == null,
         'failed outcomes require failureReason; completed outcomes forbid it',
       ),
       assert(
         status == CompactionStatus.completed
             ? candidate != null
             : candidate == null,
         'completed outcomes require candidate; failed outcomes forbid it',
       ),
       assert(
         queuedMessagesAccepted >= 0,
         'queuedMessagesAccepted must be non-negative',
       );

  factory CompactionOutcome.completed({
    required CompactionCandidate candidate,
    int queuedMessagesAccepted = 0,
  }) {
    return CompactionOutcome(
      compactionId: candidate.compactionId,
      status: CompactionStatus.completed,
      trigger: candidate.trigger,
      candidate: candidate,
      queuedMessagesAccepted: queuedMessagesAccepted,
    );
  }

  factory CompactionOutcome.failed({
    required String compactionId,
    required CompactionTrigger trigger,
    required CompactionFailureReason failureReason,
    String? failureStage,
    String? failureCause,
    Map<String, dynamic>? failureDetail,
    int queuedMessagesAccepted = 0,
  }) {
    return CompactionOutcome(
      compactionId: compactionId,
      status: CompactionStatus.failed,
      trigger: trigger,
      failureReason: failureReason,
      failureStage: failureStage,
      failureCause: failureCause,
      failureDetail: failureDetail,
      queuedMessagesAccepted: queuedMessagesAccepted,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionOutcome &&
          runtimeType == other.runtimeType &&
          compactionId == other.compactionId &&
          status == other.status &&
          trigger == other.trigger &&
          failureReason == other.failureReason &&
          failureStage == other.failureStage &&
          failureCause == other.failureCause &&
          candidate == other.candidate &&
          queuedMessagesAccepted == other.queuedMessagesAccepted;

  @override
  int get hashCode => Object.hash(
    compactionId,
    status,
    trigger,
    failureReason,
    failureStage,
    failureCause,
    candidate,
    queuedMessagesAccepted,
  );
}
