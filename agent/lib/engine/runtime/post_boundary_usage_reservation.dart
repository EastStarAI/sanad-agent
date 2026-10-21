import '../../core/agent_runtime_service.dart';

/// One post-compaction-boundary dispatch reservation captured for a single
/// provider attempt. The reservation is finalized exactly once: by confirmed
/// provider usage, or by a typed missing-usage reason on every other exit
/// (stop, drain refusal, failure, route failover, history-preparation failure,
/// no-usage completion, or stream cancellation).
class DispatchedReservation {
  final String compactionId;
  final String requestId;
  final RouteSignature routeSignature;

  const DispatchedReservation({
    required this.compactionId,
    required this.requestId,
    required this.routeSignature,
  });
}

/// Turn-scoped holder shared between a streaming turn's cancellable wrapper
/// and its provider loop, so a consumer cancel can finalize the attempt's
/// reservation when the loop itself never reaches its own finalizer.
class StreamReservationHolder {
  DispatchedReservation? dispatchedReservation;
  bool confirmed = false;
}
