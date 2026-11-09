import 'dart:async';

/// Driver-only counters over the existing authenticated connection.
///
/// An acceptance run has to distinguish "the wire leaked" from "the UI ignored
/// it". This probe subscribes to the same `events` stream every feature already
/// consumes and counts only known dictation/voice classes plus identity equality.
/// It never stores or returns audio, transcript text, or per-frame history, and
/// it detaches its own subscription on dispose.
class DriverDictationProbe {
  /// It takes the two facts it needs instead of the whole socket service, so the
  /// probe is testable without standing up a connection.
  DriverDictationProbe({
    required Stream<Map<String, dynamic>> events,
    required bool Function() isConnected,
  }) : _isConnected = isConnected {
    _subscription = events.listen(_onEvent);
  }

  /// Subscribes to the dictation transport's own event stream.
  ///
  /// The local channel opens a separate WebSocket, so its events never appear on
  /// the main socket: a local leg reported `total: 0` for a healthy session. The
  /// cubit republishes what it consumed, which is the same vocabulary the relay
  /// reshapes into, so one counter counts both channels.
  void attachTransport(Stream<Map<String, dynamic>>? events) {
    if (identical(events, _transportEvents)) return;
    unawaited(_transportSubscription?.cancel());
    _transportSubscription = null;
    _transportEvents = events;
    if (events != null) _transportSubscription = events.listen(_onEvent);
  }

  /// Every event class a dictation leg can be evidenced by.
  ///
  /// The relay classes and the local classes are counted together: a local leg
  /// previously reported `total: 0` for a real session, so the probe could not
  /// evidence the very path it exists for. They share one vocabulary above the
  /// transport boundary, and they are counted the same way here.
  static const Set<String> _knownClasses = {
    // Hosted relay.
    'dictation_event',
    'dictation_route_ack',
    'dictation_route_error',
    'voice_relay_error',
    'voice_audio_chunk_relay',
    // Local channel.
    'stt_status',
    'dictation_ready',
    'dictation_partial',
    'dictation_final',
    'dictation_done',
    'dictation_error',
  };

  final bool Function() _isConnected;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _transportSubscription;
  Stream<Map<String, dynamic>>? _transportEvents;

  String? _expectedDeviceId;
  String? _expectedDictationId;

  int _total = 0;
  int _matched = 0;
  int _foreign = 0;
  final Map<String, int> _byClass = {
    for (final name in _knownClasses) name: 0,
  };
  final Map<String, int> _errorCodes = {};
  String _phase = 'idle';

  /// Sets the identities a leg expects. Counters reset with the expectation so
  /// one leg can never inherit another leg's totals.
  void expect({String? deviceId, String? dictationId}) {
    _expectedDeviceId = deviceId;
    _expectedDictationId = dictationId;
    reset();
  }

  void reset() {
    _total = 0;
    _matched = 0;
    _foreign = 0;
    for (final name in _byClass.keys) {
      _byClass[name] = 0;
    }
    _errorCodes.clear();
    _phase = 'idle';
  }

  /// Counters, readiness, and phase only. No identifiers, audio, or text.
  Map<String, Object?> snapshot() => {
    'status': 'ok',
    'phase': _phase,
    'total': _total,
    'matched': _matched,
    'foreign': _foreign,
    'by_class': Map<String, int>.unmodifiable(_byClass),
    'error_codes': Map<String, int>.unmodifiable(_errorCodes),
    'expects_device': _expectedDeviceId != null,
    'expects_dictation': _expectedDictationId != null,
    'connected': _isConnected(),
  };

  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_transportSubscription?.cancel());
    _transportSubscription = null;
    _transportEvents = null;
  }

  void _onEvent(Map<String, dynamic> event) {
    final name = event['event']?.toString() ?? event['type']?.toString();
    if (name == null || !_knownClasses.contains(name)) return;
    _total++;
    _byClass[name] = (_byClass[name] ?? 0) + 1;

    final payload = event['payload'] is Map
        ? Map<String, dynamic>.from(event['payload'] as Map)
        : event;

    final deviceId =
        payload['origin_device_id']?.toString() ??
        payload['device_id']?.toString();
    final dictationId = payload['dictation_id']?.toString();
    final matchesDevice =
        _expectedDeviceId == null || deviceId == _expectedDeviceId;
    final matchesDictation =
        _expectedDictationId == null || dictationId == _expectedDictationId;

    // A local-channel event carries no identity at all: it cannot belong to
    // another device or session, so it counts as matched instead of falling
    // between the two counters.
    final identified = deviceId != null || dictationId != null;
    if (!identified || (matchesDevice && matchesDictation)) {
      _matched++;
    } else {
      _foreign++;
    }

    if (name == 'dictation_route_error' ||
        name == 'voice_relay_error' ||
        name == 'dictation_error') {
      // The local channel reports `code`, the relay reports `error_code`; both
      // are counted, and neither is stored with any message text.
      final code =
          (payload['error_code'] ?? payload['code'])?.toString();
      if (code != null && code.isNotEmpty) {
        _errorCodes[code] = (_errorCodes[code] ?? 0) + 1;
      }
      _phase = 'error';
      return;
    }
    if (name == 'dictation_route_ack') {
      _phase = 'ready';
      return;
    }
    if (name == 'dictation_event') {
      final type = payload['type']?.toString();
      _phase = switch (type) {
        'final' => 'final',
        'partial' => 'listening',
        _ => 'preparing',
      };
      return;
    }
    // Local-channel lifecycle. `dictation_ready` is the moment the recognizer is
    // loaded and capture starts, so it is the local counterpart of an ack.
    switch (name) {
      case 'dictation_ready':
        _phase = 'listening';
      case 'dictation_partial':
        _phase = 'listening';
      case 'dictation_final':
        _phase = 'final';
      case 'dictation_done':
        _phase = 'done';
      case 'stt_status':
        // A status reply describes readiness, not a session: it only sets the
        // phase when no session has been observed yet.
        if (_phase == 'idle') {
          _phase = payload['ready'] == true ? 'ready' : 'not_ready';
        }
    }
  }
}
