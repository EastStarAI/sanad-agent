import 'dart:collection';

/// Bounded LRU deduplication of canonical events by `event_id`.
///
/// The same logical event may arrive over both the local WebSocket and the
/// cloud Socket.IO transports (e.g. during a transport switch or cloud
/// fan-out to a same-device local client). The agent stamps every canonical
/// event with a single `event_id` that is preserved across all transport
/// copies; this deduplicator applies the first arriving copy only, regardless
/// of transport, as a transition-race safety net.
///
/// The cache is:
/// - bounded by [maxEntries] (LRU eviction of the oldest entry when full).
/// - bounded by [maxAge] (entries older than `maxAge` are evicted on sweep).
/// - independent of the durable conversation log (in-memory only).
/// - cleared on full logout, NOT on a transport switch for the same device.
class EventDeduplicator {
  EventDeduplicator({
    this.maxEntries = 4096,
    this.maxAge = const Duration(minutes: 10),
  });

  final int maxEntries;
  final Duration maxAge;

  // "<event_id>" → epoch microseconds when inserted.
  // LinkedHashMap preserves insertion order, so `keys.first` is the
  // least-recently-used entry after re-insertion-on-access.
  final LinkedHashMap<String, int> _seen = LinkedHashMap();
  DateTime _lastSweep = DateTime.now();

  /// Returns `true` when the event should be processed (first sighting of
  /// this `event_id` on a given transport), or `false` when it is a duplicate
  /// that must be dropped. Events without an `event_id` are always processed
  /// to preserve backward compatibility with producers that have not yet
  /// adopted the canonical envelope.
  bool shouldProcess(String? eventId, {required String transport}) {
    if (eventId == null || eventId.isEmpty) return true;
    final dedupeKey = eventId;
    _sweepIfNeeded();
    if (_seen.containsKey(dedupeKey)) {
      // LRU bump: move to most-recent.
      final ts = _seen.remove(dedupeKey)!;
      _seen[dedupeKey] = ts;
      return false;
    }
    _seen[dedupeKey] = DateTime.now().microsecondsSinceEpoch;
    if (_seen.length > maxEntries) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  void _sweepIfNeeded() {
    final now = DateTime.now();
    if (now.difference(_lastSweep) < const Duration(seconds: 30)) return;
    _lastSweep = now;
    final cutoff = now.subtract(maxAge).microsecondsSinceEpoch;
    _seen.removeWhere((_, ts) => ts < cutoff);
  }

  /// Clears the dedupe state. Called on full logout — NOT on a transport
  /// switch for the same device, since a switch may redeliver in-flight
  /// events that the new transport has not yet seen.
  void clear() {
    _seen.clear();
    _lastSweep = DateTime.now();
  }

  int get size => _seen.length;
}
