import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Allocates the monotonic `stream_seq` every assistant stream delta carries.
///
/// One instance belongs to exactly one run (`ActiveRun`), so the run identity
/// is implicit: a new run starts every stream key at `1` again, while the wire
/// key a consumer derives (`kind` + `model_step_id ?? run_id`) can never
/// collide across runs.
///
/// The key mixes both stream kinds so provider reasoning can never consume the
/// ordinals of ordinary assistant text, even when one model step streams both.
/// Counters are in-memory run state only: nothing here is durable, and nothing
/// here decides ownership, admission, or terminal commit. A run that restarts
/// therefore starts every key at `1` again, which is safe only because a
/// suspended-resume continuation begins a new model step first (proved in
/// `agent/test/interfaces/suspended_resume_stream_delta_test.dart`), so it never
/// re-derives a key a consumer already advanced.
class StreamDeltaSequencer {
  StreamDeltaSequencer({required this.runId});

  /// Immutable execution identity this sequencer's counters belong to.
  final String runId;

  final Map<String, int> _lastByKey = <String, int>{};

  /// Sequence of the next delta published as [kind] within [modelStepId].
  ///
  /// Starts at `1` and increases by exactly `1` for that stream key. Callers
  /// allocate before writing the in-flight projection and before emitting, so
  /// the projection and the delivered delta always agree on one number.
  int next({required String kind, required String? modelStepId}) {
    final last = _lastByKey[_key(kind: kind, modelStepId: modelStepId)] ?? 0;
    final next = last + 1;
    _lastByKey[_key(kind: kind, modelStepId: modelStepId)] = next;
    return next;
  }

  /// Highest sequence already allocated for [kind] in [modelStepId], or `0`.
  int lastAllocated({required String kind, required String? modelStepId}) =>
      _lastByKey[_key(kind: kind, modelStepId: modelStepId)] ?? 0;

  /// The stream key a consumer derives from the same two identities.
  String keyFor({required String kind, required String? modelStepId}) =>
      _key(kind: kind, modelStepId: modelStepId);

  String _key({required String kind, required String? modelStepId}) {
    final step = modelStepId == null || modelStepId.isEmpty
        ? runId
        : modelStepId;
    return '$kind|$step';
  }

  /// The stream kind carried by ordinary assistant text deltas.
  static const String thoughtKind = CanonicalEventTypes.thoughtStream;

  /// The stream kind carried by visible provider reasoning deltas.
  static const String reasoningKind = CanonicalEventTypes.reasoningStream;
}
