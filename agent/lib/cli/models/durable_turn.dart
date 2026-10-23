import 'runtime_retry_state.dart';

/// How a run must treat the durable turn a session-history payload reports.
///
/// The decision belongs to the projection, not to the runner: it is the same
/// question `sanad run` asks on re-attach and on an intervention-free follow,
/// and reading the daemon's own recovery state here keeps both answers one rule.
enum DurableFollow {
  /// The daemon still owns the turn and will drive it to a terminal outcome.
  following,

  /// A durable turn is parked on an intervention a non-interactive run cannot
  /// give, with no automatic retry scheduled.
  awaitingIntervention,

  /// The session holds no turn.
  finished,

  /// The payload carried no execution snapshot, so the turn cannot be proven
  /// either way. Never treated as proof that the turn was lost.
  unknown,
}

/// The durable turn as reported by the daemon's session projection.
///
/// A reclaimed turn keeps its work item and `request_id` across a restart, so
/// the dispatched request id is the identity check that separates "my turn was
/// reclaimed" from "another turn now owns the session".
///
/// The follow decision reads the daemon's recovery state first: a retryable
/// failure the runtime is still retrying (`waiting`, `resuming`, or a `blocked`
/// notice with budget left) is followed, and only a turn with no scheduled
/// resume is parked for an operator (Task 141).
class DurableTurn {
  final DurableFollow follow;
  final String? state;
  final String? requestId;
  final String noticeMessage;
  final bool hasScheduledResume;

  const DurableTurn({
    required this.follow,
    required this.state,
    required this.requestId,
    required this.noticeMessage,
    required this.hasScheduledResume,
  });

  factory DurableTurn.fromPayload(Map<String, dynamic> payload) {
    final snapshot = payload['execution_snapshot'];
    final state = snapshot is Map ? snapshot['state']?.toString() : null;
    final requestId = snapshot is Map
        ? snapshot['request_id']?.toString()
        : null;
    final notice = payload['runtime_notice'];
    // The recovery owner decides whether the turn continues on its own; the
    // snapshot state alone cannot tell a scheduled retry from a parked turn.
    final retry = RuntimeRetryState.fromProjection(payload);
    final hasScheduledResume =
        retry.schedulesResume ||
        retry.retryAfterMs != null ||
        (notice is Map && notice['resume_at'] != null);
    final noticeMessage = notice is Map
        ? (notice['message']?.toString() ?? '')
        : '';
    final inFlight = payload['in_flight'];

    final DurableFollow follow;
    if (retry.isAutoRetrying) {
      // `blocked` with budget left, `waiting`, or `resuming`: the daemon keeps
      // driving this turn, so re-attaching means following, not intervening.
      follow = DurableFollow.following;
    } else if (state == null) {
      follow = inFlight is Map && inFlight.isNotEmpty
          ? DurableFollow.following
          : DurableFollow.unknown;
    } else {
      follow = switch (state) {
        'running' || 'resuming' || 'waiting' || 'stopping' || 'queued' =>
          DurableFollow.following,
        // `blocked` is never transient without a scheduled retry: the daemon
        // resumes a blocked turn only through an explicit Retry, Change
        // Provider, or an automatic attempt this projection would have
        // carried.
        'blocked' => DurableFollow.awaitingIntervention,
        'idle' => DurableFollow.finished,
        _ => DurableFollow.unknown,
      };
    }

    return DurableTurn(
      follow: follow,
      state: state,
      requestId: requestId,
      noticeMessage: noticeMessage,
      hasScheduledResume: hasScheduledResume,
    );
  }

  /// Whether a turn is in flight for the session, so a new dispatch must be
  /// refused. A queued turn is followable but does not own the session yet, so
  /// it never blocks a new dispatch.
  bool get blocksNewDispatch =>
      follow == DurableFollow.following && state != 'queued';
}
