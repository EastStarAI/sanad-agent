import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

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

  /// Builds the transport over the shared cloud socket.
  ///
  /// Construction only. `dictation_start` is emitted by `sendCommand('start')`
  /// **after** the `dictation` claim command (§5.1), because order is contract:
  /// the claim exists before any route packet, and a route never creates
  /// authority. Opening the route here — before anything had minted the claim —
  /// made the Gateway refuse the first packet with `forbidden` while the claim
  /// command it raced had already started a daemon session, and the Client then
  /// abandoned that session with no audio.
  static HostedDictationTransport connect({
    required SanadSocketService socket,
    required String deviceId,
    required String dictationId,
    required int maxFrameBytes,
    int maxSessionBytes = defaultMaxSessionBytes,
    int maxSessionSeconds = defaultMaxSessionSeconds,
    DateTime Function()? clock,
  }) {
    return HostedDictationTransport._(
      socket: socket,
      deviceId: deviceId,
      dictationId: dictationId,
      maxFrameBytes: maxFrameBytes,
      maxSessionBytes: maxSessionBytes,
      maxSessionSeconds: maxSessionSeconds,
      clock: clock ?? DateTime.now,
    );
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

  /// True once the ordered `dictation_end` control left for this route.
  bool _endSent = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// A route that already failed is not a usable transport, even on a healthy
  /// socket: every write is refused from that moment, so reusing it made the
  /// cloud path look permanently wedged (each press talked into a dead
  /// transport instead of building a new one).
  @override
  bool get isOpen => !_closed && !_routeFailed && _socket.isConnected;

  /// Opens the origin route, at most once per session.
  ///
  /// Idempotent by itself: the route carries the session identity, so a second
  /// packet with the same `dictation_id` can only be a duplicate for the Gateway
  /// to referee.
  void _openRoute() {
    if (_routeOpened) return;
    _routeOpened = true;
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
      // Canonical §8: the frame this Client just built was refused as
      // malformed, which is diagnosable rather than retry-later, so it keeps its
      // own code. It is still not a version problem, so it must never be
      // promoted into "update required".
      'invalid_request' => 'relay_invalid_request',
      // Canonical §8: no claim for this route/order, or an id already bound to
      // another producer. That is a refusal of **authority**, not an outage —
      // folding it into `relay_unavailable` told the owner the relay was
      // unreachable when the request itself had never been authorized.
      'forbidden' || 'origin_conflict' => 'relay_forbidden',
      // A version mismatch never clears by retrying the same build, so it is the
      // one refusal that is actionable: update.
      'incompatible' => 'update_required',
      // `offline`, `expired`, `unavailable` and any undeclared future code share
      // the one retry-later verdict.
      _ => 'relay_unavailable',
    };
    _fail(mapped, gatewayCode: errorCode);
  }

  void _fail(String code, {String? gatewayCode}) {
    if (_routeFailed) return;
    _routeFailed = true;
    // Codes only, never text: the raw Gateway code is what separates a
    // misordered route (`forbidden`) from a real outage in a support log.
    _logger.info(
      'hosted dictation route failed: code=$code'
      '${gatewayCode == null ? '' : ' gateway=$gatewayCode'}',
    );
    if (!_events.isClosed) {
      _events.add({'event': 'dictation_error', 'code': code});
    }
  }

  /// Sends the ordered `dictation_end` control for this route, at most once.
  ///
  /// It is the **only** carrier that ends a hosted session: the Agent relay
  /// answers a `dictation` command `op: cancel` with `invalid_request` by design
  /// ("stop and cancel travel on the ordered `dictation_end` control"), so the
  /// command path never ends anything.
  void _sendEnd(String reason) {
    if (_endSent) return;
    _endSent = true;
    _socket.emit('dictation_end', {
      'version': 'v1',
      'dictation_id': dictationId,
      'reason': reason,
    });
  }

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {
    if (_closed || _routeFailed) return;
    if (event == 'stop' || event == 'cancel') {
      // Ordered route control: it can never overtake a frame that was already
      // admitted, which is why it does not ride the command path.
      _sendEnd(event == 'stop' ? 'stopped' : 'cancelled');
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
    if (event == 'start') {
      // Claim first, route second: the Gateway refuses a route without a claim
      // and creates none from a route packet. `_openRoute` is idempotent, so a
      // repeated start cannot send a second route packet.
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
    // The wire contract is a binary attachment, and the socket.io encoder only
    // produces one for a typed buffer: a plain `List<int>` is JSON-encoded as an
    // array of integers, which the Gateway refuses with `invalid_request`. The
    // container capture hands over is not a wire fact, so normalize once here;
    // `Uint8List.sublist` then copies each frame into its own typed buffer, so a
    // reused capture buffer can never rewrite a queued packet.
    final pcm = pcm16 is Uint8List ? pcm16 : Uint8List.fromList(pcm16);
    var offset = 0;
    while (offset < pcm.length) {
      final end = math.min(offset + _maxFrameBytes, pcm.length);
      _socket.emit('dictation_audio', {
        'version': 'v1',
        'dictation_id': dictationId,
        'seq': _seq++,
        // Raw signed 16-bit little-endian samples: never base64, never a string,
        // never an int array.
        'data': pcm.sublist(offset, end),
      });
      offset = end;
    }
    _sentBytes += pcm16.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // A session the daemon started must not outlive the transport that owned it.
    // The ordered `dictation_end` is the one carrier that ends it, so an abort
    // that never asked for a stop still ends its route here — otherwise the
    // Gateway held the device occupied until its idle route TTL and every press
    // on every client was refused `busy` (5 m 35 s after one aborted press).
    // A failed route admits nothing, so it is sent nothing: the Agent's
    // `firstAudioTimeout` watchdog releases the daemon, and the Gateway retires
    // the route on its own.
    if (_routeOpened && !_routeFailed && _socket.isConnected) {
      _sendEnd('cancelled');
    }
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
