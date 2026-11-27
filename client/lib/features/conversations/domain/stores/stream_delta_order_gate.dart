import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

/// Asks the Agent for the authoritative in-flight snapshot of one session.
///
/// Returning `null` means the Agent answered `absent` (or could not answer) and
/// the Client must keep the last good text instead of inventing one.
typedef StreamRepairRequest = Future<CanonicalEvent?> Function(String sessionId);

/// Schedules the reorder window. Tests inject a manual executor so no test ever
/// waits on wall-clock time.
typedef StreamDeltaTimerFactory =
    Timer Function(Duration delay, void Function() callback);

/// Bounds of the Client-side reorder window.
///
/// These are the contract numbers of the ingestion gate, not tuning knobs
/// scattered through the code: one place states how long a stream may wait, how
/// much it may hold, and how often it may ask for a repair.
class StreamDeltaOrderLimits {
  const StreamDeltaOrderLimits._();

  /// Longest a delta waits for its predecessor before the window gives up.
  static const Duration reorderWindow = Duration(milliseconds: 500);

  /// Minimum gap between two repair requests for one session.
  static const Duration repairCooldown = Duration(seconds: 2);

  /// Most buffered deltas one stream key may hold.
  static const int maxBufferedDeltas = 32;

  /// Most buffered text one stream key may hold.
  static const int maxBufferedBytes = 64 * 1024;

  /// Most concurrent stream keys tracked for one session.
  static const int maxStreamsPerSession = 8;

  /// Most sessions the gate keeps ordering state for at once.
  ///
  /// A finished turn keeps its sealed keys so a very late delta cannot reopen
  /// it, so the number of tracked sessions is bounded like every other window.
  static const int maxTrackedSessions = 8;

  /// Most closed stream keys remembered so a late delta cannot reopen them.
  static const int maxSealedStreamsPerSession = 16;
}

/// Orders assistant stream deltas per session before they reach the timeline.
///
/// A delta stream is only replayable in order, so the gate is the single place
/// that decides whether a delta is applied now, held for a bounded window, or
/// dropped as stale. It owns no text: it returns the events the owner should
/// apply, in order, and asks for one authoritative snapshot when a gap cannot
/// be repaired by waiting.
///
/// Lifetime rules:
///
/// - An ordinal (`stream_seq`) on the delta is the evidence; a missing
///   capability declaration never drops an event.
/// - A stream whose first delta carries no ordinal is `unsequenced` for its
///   whole stream lifetime and keeps plain arrival order.
/// - A terminal event of a step seals that step's keys, so a late delta can
///   never create a ghost bubble after the final answer.
/// - Every buffer, timer, and request entry is released on a terminal, a
///   session switch, a reset, or disposal.
class StreamDeltaOrderGate {
  StreamDeltaOrderGate({
    StreamDeltaTimerFactory? timerFactory,
    DateTime Function()? now,
  }) : _timerFactory = timerFactory ?? Timer.new,
       _now = now ?? DateTime.now;

  static const List<EventKind> _streamKinds = <EventKind>[
    EventKind.thinking,
    EventKind.reasoning,
  ];

  final StreamDeltaTimerFactory _timerFactory;
  final DateTime Function() _now;
  final Map<String, _SessionOrder> _sessions = <String, _SessionOrder>{};

  StreamRepairRequest? _requestRepair;
  void Function(List<CanonicalEvent> events)? _applyAdopted;
  bool _repairEnabled = false;
  bool _disposed = false;
  int _repairRequestCount = 0;

  /// Repair requests actually dispatched. Diagnostics and test evidence only.
  int get repairRequestCount => _repairRequestCount;

  /// Sessions that still retain ordering state.
  ///
  /// A finished turn keeps its bounded line of sealed keys so a very late delta
  /// cannot reopen it, so this is not zero as soon as a turn ends; it is zero
  /// only after a reset, a session switch, or disposal.
  int get trackedSessionCount => _sessions.length;

  /// Stream keys currently holding buffered deltas.
  int get bufferedStreamCount => _sessions.values.fold<int>(
    0,
    (total, session) => total + session.streams.values.where((s) => s.pending.isNotEmpty).length,
  );

  /// True when the gate retains no ordering state at all.
  ///
  /// That includes the bounded line of sealed keys a finished turn leaves
  /// behind, so [isIdle] means "nothing is left to protect", not merely "no
  /// delta is buffered".
  bool get isIdle => _sessions.isEmpty;

  /// Installs the transport and the owner of an adopted snapshot.
  ///
  /// [repair] is the narrow `session.stream_state` query; [applyAdopted] is the
  /// owner's direct application path, used because an adopted snapshot must not
  /// re-enter the gate that produced it. A call that omits one keeps the
  /// current binding, so enabling the capability later cannot detach the
  /// transport.
  void configure({
    StreamRepairRequest? repair,
    void Function(List<CanonicalEvent> events)? applyAdopted,
  }) {
    if (repair != null) _requestRepair = repair;
    if (applyAdopted != null) _applyAdopted = applyAdopted;
  }

  /// Enables repair requests once the peer declared `stream_sequence_v1`.
  ///
  /// Ordering itself never depends on this flag: a delta that carries an
  /// ordinal is ordered anyway, and an undeclared peer simply never produces a
  /// gap the Client could repair.
  void setRepairEnabled(bool enabled) {
    _repairEnabled = enabled;
  }

  /// Returns the events the owner should apply, in order.
  ///
  /// An empty result means the delta is held in the reorder window or dropped
  /// as stale/duplicate; it must not be applied and must not emit a timeline
  /// change.
  List<CanonicalEvent> admit(CanonicalEvent event) {
    // A disposed gate belongs to a closed owner: it must never decide, hold, or
    // apply anything again, including a late delivery from a socket that is
    // still draining.
    if (_disposed) return const <CanonicalEvent>[];
    if (!_isStreamEvent(event)) return <CanonicalEvent>[event];
    final sessionId = event.sessionId;
    if (sessionId == null || sessionId.isEmpty) return <CanonicalEvent>[event];
    final key = _streamKeyFor(event);
    if (key == null) return <CanonicalEvent>[event];

    final session = _sessionFor(sessionId);
    if (session.sealed.contains(key)) return const <CanonicalEvent>[];
    if (event.isSnapshot) {
      return <CanonicalEvent>[_adoptSnapshot(session, key, event)];
    }
    if (event.status != EventStatus.running) {
      return <CanonicalEvent>[event];
    }

    final sequence = event.streamSeq;
    if (sequence == null) {
      final stream = _streamFor(session, key);
      // Only a key that never established an ordinal becomes unsequenced. Once
      // the key is sequenced, a bare delta is applied best-effort without
      // clearing the window or disabling repair: the watermark and the buffered
      // deltas are what a later repair still needs.
      if (stream.last == null && stream.pending.isEmpty) {
        stream.unsequenced = true;
        _dropPending(stream);
      }
      return <CanonicalEvent>[event];
    }

    final stream = _streamFor(session, key);
    if (stream.unsequenced) return <CanonicalEvent>[event];
    final last = stream.last;
    if (last != null && sequence <= last) return const <CanonicalEvent>[];
    if (stream.pending.containsKey(sequence)) return const <CanonicalEvent>[];
    // With no watermark yet the stream may start at 1, or one ordinal below the
    // lowest delta already waiting for its predecessor: that arrival is the
    // missing head of the window, so it starts the stream and drains the rest.
    final expectedNext = last != null
        ? last + 1
        : (stream.pending.isEmpty ? 1 : (stream.pending.firstKey() ?? 1) - 1);
    if (sequence != expectedNext) {
      _buffer(sessionId, session, key, stream, event);
      return const <CanonicalEvent>[];
    }
    stream.last = sequence;
    return <CanonicalEvent>[event, ..._drain(session, key, stream)];
  }

  /// Closes the stream keys a terminal event of [modelStepId]/[runId] owns.
  ///
  /// [turnTerminal] also closes the run-scoped keys, which is what a final
  /// answer, an explicit error, or a stop means: no delta of that turn may
  /// append after it. A turn terminal also advances the session's turn epoch,
  /// which retires any repair already in flight.
  void noteTerminal({
    required String? sessionId,
    String? modelStepId,
    String? runId,
    bool turnTerminal = false,
  }) {
    if (_disposed) return;
    if (sessionId == null || sessionId.isEmpty) return;
    final session = _sessions[sessionId];
    if (session == null) return;
    if (turnTerminal) session.turnEpoch += 1;
    final identities = <String>{
      if (modelStepId != null && modelStepId.isNotEmpty) modelStepId,
      if (turnTerminal && runId != null && runId.isNotEmpty) runId,
    };
    for (final identity in identities) {
      for (final kind in _streamKinds) {
        _seal(session, _StreamKey(kind, identity));
      }
    }
    session.repairSuspended = false;
    if (turnTerminal) {
      for (final stream in session.streams.values) {
        _dropPending(stream);
      }
    }
  }

  /// Adopts the watermarks carried by an authoritative history baseline.
  ///
  /// A hydrated in-flight projection is a whole-text snapshot, so the session's
  /// arrival-order state is replaced by its watermark instead of extending it.
  void adoptBaseline({
    required String? sessionId,
    required Iterable<CanonicalEvent> events,
  }) {
    if (_disposed) return;
    if (sessionId == null || sessionId.isEmpty) return;
    resetSession(sessionId);
    for (final event in events) {
      if (!event.isSnapshot) continue;
      final key = _streamKeyFor(event);
      final sequence = event.streamSeq;
      if (key == null || sequence == null) continue;
      final session = _sessionFor(sessionId);
      _streamFor(session, key).last = sequence;
    }
  }

  /// Releases everything tracked for one session.
  void resetSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return;
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    for (final stream in session.streams.values) {
      _dropPending(stream);
    }
    session.streams.clear();
    session.sealed.clear();
  }

  /// Releases every tracked session, buffer, and timer, and closes the gate.
  void dispose() {
    _disposed = true;
    for (final sessionId in _sessions.keys.toList(growable: false)) {
      resetSession(sessionId);
    }
    _requestRepair = null;
    _applyAdopted = null;
  }

  CanonicalEvent _adoptSnapshot(
    _SessionOrder session,
    _StreamKey key,
    CanonicalEvent event,
  ) {
    final stream = _streamFor(session, key);
    final sequence = event.streamSeq;
    if (sequence == null) {
      stream.unsequenced = true;
    } else if (stream.last == null || sequence > stream.last!) {
      stream.last = sequence;
    }
    // The snapshot is the whole text through its watermark: anything still
    // waiting for a predecessor is either contained in it or older than it.
    _dropPending(stream);
    return event;
  }

  void _buffer(
    String sessionId,
    _SessionOrder session,
    _StreamKey key,
    _StreamOrder stream,
    CanonicalEvent event,
  ) {
    final sequence = event.streamSeq!;
    if (stream.pending.containsKey(sequence)) return;
    final bytes = utf8.encode(event.text).length;
    final exceedsCount =
        stream.pending.length >= StreamDeltaOrderLimits.maxBufferedDeltas;
    final exceedsBytes =
        stream.pendingBytes + bytes > StreamDeltaOrderLimits.maxBufferedBytes;
    if (exceedsCount || exceedsBytes) {
      _abandon(session, key, stream);
      _scheduleRepair(sessionId);
      return;
    }
    stream.pending[sequence] = event;
    stream.pendingBytes += bytes;
    stream.timer ??= _timerFactory(
      StreamDeltaOrderLimits.reorderWindow,
      () => _onReorderWindowElapsed(sessionId, key),
    );
  }

  List<CanonicalEvent> _drain(
    _SessionOrder session,
    _StreamKey key,
    _StreamOrder stream,
  ) {
    final drained = <CanonicalEvent>[];
    while (true) {
      final last = stream.last;
      final next = last == null ? 1 : last + 1;
      final event = stream.pending.remove(next);
      if (event == null) break;
      stream.pendingBytes -= utf8.encode(event.text).length;
      if (stream.pendingBytes < 0) stream.pendingBytes = 0;
      stream.last = next;
      drained.add(event);
    }
    if (stream.pending.isEmpty) _cancelTimer(stream);
    return drained;
  }

  void _onReorderWindowElapsed(String sessionId, _StreamKey key) {
    final session = _sessions[sessionId];
    if (session == null) return;
    final stream = session.streams[key];
    if (stream == null || stream.pending.isEmpty) return;
    _abandon(session, key, stream);
    _scheduleRepair(sessionId);
  }

  void _abandon(_SessionOrder session, _StreamKey key, _StreamOrder stream) {
    _dropPending(stream);
    // The key keeps its watermark: the stream may still continue after the
    // missing delta, and an ordinal that resumes the sequence must apply.
    if (stream.last == null) session.streams.remove(key);
  }

  void _dropPending(_StreamOrder stream) {
    _cancelTimer(stream);
    stream.pending.clear();
    stream.pendingBytes = 0;
  }

  void _cancelTimer(_StreamOrder stream) {
    stream.timer?.cancel();
    stream.timer = null;
  }

  void _scheduleRepair(String sessionId) {
    unawaited(_requestRepairSnapshot(sessionId));
  }

  Future<void> _requestRepairSnapshot(String sessionId) async {
    if (_disposed || !_repairEnabled) return;
    final session = _sessions[sessionId];
    final repair = _requestRepair;
    if (session == null || repair == null) return;
    if (session.repairSuspended || session.repairInFlight) return;
    final now = _now();
    final lastRequestAt = session.lastRepairRequestAt;
    if (lastRequestAt != null &&
        now.difference(lastRequestAt) < StreamDeltaOrderLimits.repairCooldown) {
      return;
    }
    session.repairInFlight = true;
    session.lastRepairRequestAt = now;
    final requestedEpoch = session.turnEpoch;
    _repairRequestCount += 1;
    try {
      final snapshot = await repair(sessionId);
      // The answer belongs to the stream that asked for it. A session switch, a
      // reset, a disposal, or a turn terminal that happened while the request
      // was in flight retires it completely: applying or cleaning state here
      // would inject text into the wrong conversation.
      final current = _sessions[sessionId];
      final isCurrentOwner =
          !_disposed &&
          identical(current, session) &&
          session.turnEpoch == requestedEpoch;
      if (!isCurrentOwner) return;
      if (snapshot == null) {
        // `absent` or an error: never invent text and never reload history.
        // Keep the last good projection and wait for the terminal event.
        session.repairSuspended = true;
        return;
      }
      final key = _streamKeyFor(snapshot);
      if (key == null) {
        session.repairSuspended = true;
        return;
      }
      if (session.sealed.contains(key)) return;
      final stream = _streamFor(session, key);
      final sequence = snapshot.streamSeq;
      if (sequence != null && (stream.last == null || sequence > stream.last!)) {
        stream.last = sequence;
      }
      session.repairSuspended = false;
      final ordered = <CanonicalEvent>[snapshot, ..._drain(session, key, stream)];
      _applyAdopted?.call(ordered);
    } catch (_) {
      final current = _sessions[sessionId];
      final isCurrentOwner =
          !_disposed &&
          identical(current, session) &&
          session.turnEpoch == requestedEpoch;
      if (isCurrentOwner) session.repairSuspended = true;
    } finally {
      final current = _sessions[sessionId];
      if (!_disposed && identical(current, session)) {
        session.repairInFlight = false;
      }
    }
  }

  void _seal(_SessionOrder session, _StreamKey key) {
    final stream = session.streams.remove(key);
    if (stream != null) _dropPending(stream);
    session.sealed.remove(key);
    session.sealed.add(key);
    while (session.sealed.length > StreamDeltaOrderLimits.maxSealedStreamsPerSession) {
      session.sealed.remove(session.sealed.first);
    }
  }

  _StreamOrder _streamFor(_SessionOrder session, _StreamKey key) {
    final existing = session.streams.remove(key);
    if (existing != null) {
      // Re-insert so the map order stays least-recently-used first.
      session.streams[key] = existing;
      return existing;
    }
    session.streams[key] = _StreamOrder();
    while (session.streams.length > StreamDeltaOrderLimits.maxStreamsPerSession) {
      final evictedKey = session.streams.keys.first;
      final evicted = session.streams.remove(evictedKey);
      if (evicted != null) _dropPending(evicted);
    }
    return session.streams[key]!;
  }

  _SessionOrder _sessionFor(String sessionId) {
    final existing = _sessions.remove(sessionId);
    if (existing != null) {
      _sessions[sessionId] = existing;
      return existing;
    }
    _sessions[sessionId] = _SessionOrder();
    while (_sessions.length > StreamDeltaOrderLimits.maxTrackedSessions) {
      resetSession(_sessions.keys.first);
    }
    return _sessions[sessionId]!;
  }

  bool _isStreamEvent(CanonicalEvent event) =>
      event.kind == EventKind.thinking || event.kind == EventKind.reasoning;

  _StreamKey? _streamKeyFor(CanonicalEvent event) {
    final identity = event.modelStepId?.isNotEmpty == true
        ? event.modelStepId!
        : event.runId;
    if (identity == null || identity.isEmpty) return null;
    return _StreamKey(event.kind, identity);
  }
}

class _StreamKey {
  const _StreamKey(this.kind, this.identity);

  final EventKind kind;
  final String identity;

  @override
  bool operator ==(Object other) =>
      other is _StreamKey && other.kind == kind && other.identity == identity;

  @override
  int get hashCode => Object.hash(kind, identity);
}

class _SessionOrder {
  final Map<_StreamKey, _StreamOrder> streams = <_StreamKey, _StreamOrder>{};
  final Set<_StreamKey> sealed = <_StreamKey>{};
  bool repairInFlight = false;
  bool repairSuspended = false;
  DateTime? lastRepairRequestAt;

  /// Advances on every turn terminal, so a repair answer requested by the turn
  /// that just ended can never be applied to the next one.
  int turnEpoch = 0;
}

class _StreamOrder {
  int? last;
  bool unsequenced = false;
  final SplayTreeMap<int, CanonicalEvent> pending = SplayTreeMap<int, CanonicalEvent>();
  int pendingBytes = 0;
  Timer? timer;
}
