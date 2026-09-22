import 'package:sanad_agent/engine/compaction/compaction.dart';

import '../db/compaction_boundary_repository.dart';
import '../db/session_projection_revision_repository.dart';
import 'compaction_boundary_change.dart';

/// Atomic compaction activation owned by evolution (Plan 53b Gate B3).
///
/// Wraps repository terminal transitions, bumps projection revision only after
/// successful commit, and publishes one change event for interface consumers.
///
/// Queued work and active work items are not mutated here (53d owns drain).
class CompactionActivationService {
  final CompactionBoundaryRepository _boundaries;
  final SessionProjectionRevisionRepository _projectionRevisions;
  final CompactionBoundaryChangeSink _changes;

  CompactionActivationService({
    required CompactionBoundaryRepository boundaries,
    required SessionProjectionRevisionRepository projectionRevisions,
    CompactionBoundaryChangeSink? changes,
  }) : _boundaries = boundaries,
       _projectionRevisions = projectionRevisions,
       _changes = changes ?? CompactionBoundaryChangeNotifier();

  CompactionTerminalResult activateCandidate({
    required CompactionCandidate candidate,
    required DateTime startedAt,
    required DateTime completedAt,
  }) {
    final result = _boundaries.completeStarted(
      candidate: candidate,
      startedAt: startedAt,
      completedAt: completedAt,
    );
    if (result.outcome == CompactionTerminalOutcome.completed &&
        result.record != null) {
      final revision = _projectionRevisions.read(candidate.sessionId);
      if (revision != null) {
        _changes.publishActivated(
          CompactionBoundaryActivated(
            sessionId: candidate.sessionId,
            boundary: result.record!,
            projectionRevision: revision,
          ),
        );
      }
    }
    return result;
  }

  CompactionTerminalResult failOperation({
    required String compactionId,
    required CompactionFailureReason failureReason,
    required DateTime completedAt,
    Map<String, dynamic>? failureDetail,
  }) {
    final result = _boundaries.failStarted(
      compactionId: compactionId,
      failureReason: failureReason,
      completedAt: completedAt,
      failureDetail: failureDetail,
    );
    if (result.outcome == CompactionTerminalOutcome.failed &&
        result.record != null) {
      _changes.publishFailed(
        CompactionBoundaryFailed(
          sessionId: result.record!.sessionId,
          boundary: result.record!,
        ),
      );
    }
    return result;
  }
}
