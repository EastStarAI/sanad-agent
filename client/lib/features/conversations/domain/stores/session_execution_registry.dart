import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';

enum SessionExecutionApplyDisposition {
  applied,
  refreshedObservation,
  idempotent,
  rejectedStaleRevision,
  rejectedConflictingRevision,
}

class SessionExecutionApplyResult extends Equatable {
  final SessionExecutionApplyDisposition disposition;
  final SessionExecutionSnapshot current;
  final SessionExecutionSnapshot incoming;
  final String diagnostic;

  const SessionExecutionApplyResult({
    required this.disposition,
    required this.current,
    required this.incoming,
    required this.diagnostic,
  });

  bool get accepted =>
      disposition == SessionExecutionApplyDisposition.applied ||
      disposition == SessionExecutionApplyDisposition.refreshedObservation ||
      disposition == SessionExecutionApplyDisposition.idempotent;
  bool get changed =>
      disposition == SessionExecutionApplyDisposition.applied ||
      disposition == SessionExecutionApplyDisposition.refreshedObservation;

  @override
  List<Object?> get props => [disposition, current, incoming, diagnostic];
}

class SessionExecutionRegistry {
  final Map<String, SessionExecutionSnapshot> _snapshotsBySessionId = {};

  Map<String, SessionExecutionSnapshot> get snapshotsBySessionId => Map.unmodifiable(_snapshotsBySessionId);

  SessionExecutionSnapshot snapshotFor(String sessionId) =>
      _snapshotsBySessionId[sessionId] ?? SessionExecutionSnapshot.virtualIdle(sessionId);

  SessionExecutionApplyResult apply(SessionExecutionSnapshot incoming) {
    final current = snapshotFor(incoming.sessionId);
    if (incoming.revision < current.revision) {
      return SessionExecutionApplyResult(
        disposition: SessionExecutionApplyDisposition.rejectedStaleRevision,
        current: current,
        incoming: incoming,
        diagnostic:
            'Rejected stale execution revision ${incoming.revision} for ${incoming.sessionId}; current revision is ${current.revision}.',
      );
    }

    if (incoming.revision == current.revision) {
      if (incoming == current) {
        return SessionExecutionApplyResult(
          disposition: SessionExecutionApplyDisposition.idempotent,
          current: current,
          incoming: incoming,
          diagnostic: 'Execution revision ${incoming.revision} for ${incoming.sessionId} is an identical replay.',
        );
      }
      if (incoming.hasSameAuthorityAs(current) && (incoming.elapsedMs ?? -1) >= (current.elapsedMs ?? -1)) {
        _snapshotsBySessionId[incoming.sessionId] = incoming;
        return SessionExecutionApplyResult(
          disposition: SessionExecutionApplyDisposition.refreshedObservation,
          current: incoming,
          incoming: incoming,
          diagnostic:
              'Refreshed elapsed observation for execution revision ${incoming.revision} of ${incoming.sessionId}.',
        );
      }
      return SessionExecutionApplyResult(
        disposition: SessionExecutionApplyDisposition.rejectedConflictingRevision,
        current: current,
        incoming: incoming,
        diagnostic:
            'Rejected conflicting execution payload at revision ${incoming.revision} for ${incoming.sessionId}.',
      );
    }

    _snapshotsBySessionId[incoming.sessionId] = incoming;
    return SessionExecutionApplyResult(
      disposition: SessionExecutionApplyDisposition.applied,
      current: incoming,
      incoming: incoming,
      diagnostic: 'Applied execution revision ${incoming.revision} for ${incoming.sessionId}.',
    );
  }

  SessionExecutionApplyResult applyPayload(
    Map<String, dynamic> payload, {
    String? expectedSessionId,
  }) {
    return apply(
      SessionExecutionSnapshot.fromJson(
        payload,
        expectedSessionId: expectedSessionId,
      ),
    );
  }
}
