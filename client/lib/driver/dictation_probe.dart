import 'dart:async';

import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

/// Driver-only counters over the existing authenticated connection.
///
/// An acceptance run has to distinguish "the wire leaked" from "the UI ignored
/// it". This probe subscribes to the same `events` stream every feature already
/// consumes and counts only known dictation/voice classes plus identity equality.
/// It never stores or returns audio, transcript text, or per-frame history, and
/// it detaches its own subscription on dispose.
class DriverDictationProbe {
  DriverDictationProbe(this._socket) {
    _subscription = _socket.events.listen(_onEvent);
  }

  static const Set<String> _knownClasses = {
    'dictation_event',
    'dictation_route_ack',
    'dictation_route_error',
    'voice_relay_error',
    'voice_audio_chunk_relay',
  };

  final SanadSocketService _socket;
  StreamSubscription<Map<String, dynamic>>? _subscription;

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
    'connected': _socket.isConnected,
  };

  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
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

    if (matchesDevice && matchesDictation) {
      _matched++;
    } else if (deviceId != null || dictationId != null) {
      _foreign++;
    }

    if (name == 'dictation_route_error' || name == 'voice_relay_error') {
      final code = payload['error_code']?.toString();
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
    }
  }
}
