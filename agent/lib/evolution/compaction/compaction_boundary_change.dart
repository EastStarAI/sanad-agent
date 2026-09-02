import '../models/compaction_operation_record.dart';
import '../db/session_projection_revision_repository.dart';

/// Published once after a successful compaction activation commit (53b B3).
class CompactionBoundaryActivated {
  final String sessionId;
  final CompactionOperationRecord boundary;
  final SessionProjectionRevision projectionRevision;

  const CompactionBoundaryActivated({
    required this.sessionId,
    required this.boundary,
    required this.projectionRevision,
  });
}

/// Published once after a terminal failure commit clears an in-flight claim.
class CompactionBoundaryFailed {
  final String sessionId;
  final CompactionOperationRecord boundary;

  const CompactionBoundaryFailed({
    required this.sessionId,
    required this.boundary,
  });
}

/// Single broadcast channel for compaction repository mutations (53d/53e consumers).
abstract class CompactionBoundaryChangeSink {
  void publishActivated(CompactionBoundaryActivated change);
  void publishFailed(CompactionBoundaryFailed change);
}

/// In-process notifier; orchestrator subscribes during 53d wiring.
class CompactionBoundaryChangeNotifier implements CompactionBoundaryChangeSink {
  final void Function(CompactionBoundaryActivated)? onActivated;
  final void Function(CompactionBoundaryFailed)? onFailed;

  CompactionBoundaryChangeNotifier({this.onActivated, this.onFailed});

  @override
  void publishActivated(CompactionBoundaryActivated change) {
    onActivated?.call(change);
  }

  @override
  void publishFailed(CompactionBoundaryFailed change) {
    onFailed?.call(change);
  }
}
