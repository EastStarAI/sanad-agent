import 'dart:async';
import 'dart:math' as math;

import 'package:logging/logging.dart';

import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

import 'dictation_transport.dart';

/// [DictationTransport] over the already-authenticated cloud connection.
///
/// It adds no authentication, no connection, and no socket owner: it reuses the
/// [SanadSocketService] the `DeviceConnectionCoordinator` already owns, sends the
/// generic `dictation` command family, carries `stop`/`cancel` as the ordered
/// `dictation_end` route control, and reshapes origin-scoped `dictation_event`
/// payloads into the same `{event, ...fields}` maps the local channel produces.
///
/// The session, cubit, insertion, and widgets never learn which channel is in
/// use; only `DictationTransportResolver` picks one.
class HostedDictationTransport implements DictationTransport {
  HostedDictationTransport._({
    required SanadSocketService socket,
    required this.deviceId,
    required this.dictationId,
    required int maxFrameBytes,
    required int maxSessionBytes,
    required int maxSessionSeconds,
    required DateTime Function() clock,
  }) : _socket = socket,
       _maxFrameBytes = maxFrameBytes,
       _maxSessionBytes = maxSessionBytes,
       _maxSessionSeconds = maxSessionSeconds,
       _clock = clock {
    _openedAt = _clock();
    _listen();
  }

  /// Opens the origin claim, then the audio route, on the shared cloud socket.
  ///
  /// Order is contract: the claim exists before any route packet, and the route
  /// never creates authority.
  static HostedDictationTransport connect({
    required SanadSocketService socket,
    required String deviceId,
    required String dictationId,
    required int maxFrameBytes,
    int maxSessionBytes = defaultMaxSessionBytes,
    int maxSessionSeconds = defaultMaxSessionSeconds,
    DateTime Function()? clock,
  }) {
    final transport = HostedDictationTransport._(
      socket: socket,
      deviceId: deviceId,
      dictationId: dictationId,
      maxFrameBytes: maxFrameBytes,
      maxSessionBytes: maxSessionBytes,
      maxSessionSeconds: maxSessionSeconds,
      clock: clock ?? DateTime.now,
    );
    transport._openRoute();
    return transport;
  }

  /// Contract bound for one audio session (12 MiB, §6.1).
  static const int defaultMaxSessionBytes = 12582912;

  /// Contract bound for one audio session (300 s, §6.1).
  static const int defaultMaxSessionSeconds = 300;

  static final Logger _logger = Logger('HostedDictationTransport');

  final SanadSocketService _socket;
  final String deviceId;
  final String dictationId;
  final int _maxFrameBytes;
  final int _maxSessionBytes;
  final int _maxSessionSeconds;
  final DateTime Function() _clock;
  late DateTime _openedAt;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _subscription;

  int _seq = 0;
  int _sentBytes = 0;
  bool _closed = false;
  bool _routeFailed = false;
  bool _routeOpened = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get isOpen => !_closed && _socket.isConnected;

  void _openRoute() {
    if (!_socket.isConnected) {
      _fail('relay_unavailable');
      return;
    }
    _socket.emit('dictation_start', {
      'version': 'v1',
      'dictation_id': dictationId,
      'device_id': deviceId,
      'request_id': dictationId,
      'audio': {'encoding': 'pcm16le', 'sample_rate': 16000, 'channels': 1},
      'max_bytes': _maxSessionBytes,
    });
  }

  void _listen() {
    _subscription = _socket.events.listen(
      (event) {
        if (_closed) return;
        final name = event['event']?.toString() ?? event['type']?.toString();
        if (name == 'dictation_event') {
          _onRelayed(event);
          return;
        }
        if (name == 'dictation_route_error') {
          _onRouteError(event);
        }
        // `dictation_route_ack` is informational and never gates capture.
      },
      onError: (Object _) => _fail('relay_unavailable'),
    );
  }

  void _onRelayed(Map<String, dynamic> envelope) {
    final raw = envelope['payload'];
    if (raw is! Map) return;
    final payload = Map<String, dynamic>.from(raw);
    // Identity is checked again here: a relayed event for another dictation
    // session must never reach this composer.
    if (payload['dictation_id'] != dictationId) return;
    final type = payload['type']?.toString();
    if (type == null || type.isEmpty) return;
    final fields = Map<String, dynamic>.from(payload)..remove('type');
    if (!_events.isClosed) _events.add({'event': type, ...fields});
  }

  void _onRouteError(Map<String, dynamic> event) {
    final raw = event['payload'] is Map ? event['payload'] as Map : event;
    final payload = Map<String, dynamic>.from(raw);
    if (payload['dictation_id'] != null &&
        payload['dictation_id'] != dictationId) {
      return;
    }
    final errorCode = payload['error_code']?.toString() ?? '';
    final mapped = switch (errorCode) {
      'busy' => 'dictation_busy',
      'size_limit' || 'rate_limited' => 'session_limit',
      // Canonical §8: every other refusal is the same retry-later outcome. A
      // malformed request is not a version problem, so it must not be promoted
      // into "update required".
      _ => 'relay_unavailable',
    };
    _fail(mapped);
  }

  void _fail(String code) {
    if (_routeFailed) return;
    _routeFailed = true;
    _logger.info('hosted dictation route failed: code=$code');
    if (!_events.isClosed) {
      _events.add({'event': 'dictation_error', 'code': code});
    }
  }

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {
    if (_closed || _routeFailed) return;
    if (event == 'stop' || event == 'cancel') {
      // Ordered route control: it can never overtake a frame that was already
      // admitted, which is why it does not ride the command path.
      _socket.emit('dictation_end', {
        'version': 'v1',
        'dictation_id': dictationId,
        'reason': event == 'stop' ? 'stopped' : 'cancelled',
      });
      return;
    }
    final modelId = payload['model_id'];
    _socket.sendDeviceCommand(
      deviceId: deviceId,
      command: 'dictation',
      payload: {
        'version': 'v1',
        'dictation_id': dictationId,
        // The claim is client-supplied and equal to the session identity, so the
        // whole session shares one immutable origin route.
        'request_id': dictationId,
        'op': event,
        if (modelId is String && modelId.isNotEmpty) 'model_id': modelId,
      },
    );
    if (event == 'start' && !_routeOpened) {
      // Claim first, route second: the Gateway refuses a route without a claim
      // and creates none from a route packet.
      _routeOpened = true;
      _openRoute();
    }
  }

  @override
  void sendAudio(List<int> pcm16) {
    if (_closed || _routeFailed || pcm16.isEmpty) return;
    if (_clock().difference(_openedAt) >
        Duration(seconds: _maxSessionSeconds)) {
      // The declared duration bound is the peer's admission window: stop before
      // it closes so the daemon never decodes a truncated utterance.
      _fail('session_limit');
      return;
    }
    if (_sentBytes + pcm16.length > _maxSessionBytes) {
      // The session cap is a memory bound, not a hint: stop sending and let the
      // session end through the existing limit path.
      _fail('session_limit');
      return;
    }
    var offset = 0;
    while (offset < pcm16.length) {
      final end = math.min(offset + _maxFrameBytes, pcm16.length);
      final slice = pcm16.sublist(offset, end);
      _socket.emit('dictation_audio', {
        'version': 'v1',
        'dictation_id': dictationId,
        'seq': _seq++,
        // Raw signed 16-bit little-endian samples: never base64, never a string.
        'data': slice,
      });
      offset = end;
    }
    _sentBytes += pcm16.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    if (!_events.isClosed) await _events.close();
  }

  /// Frame bound this transport splits capture to.
  int get maxFrameBytes => _maxFrameBytes;

  /// Session byte bound this transport declared in `dictation_start`.
  int get maxSessionBytes => _maxSessionBytes;

  /// Session duration bound this transport enforces before sending.
  int get maxSessionSeconds => _maxSessionSeconds;

  /// The contract capability this transport requires from the Agent.
  static bool isAdvertisedBy(Capability capability) =>
      capability.supportsDictationRelay;
}
