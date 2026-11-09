import 'dart:async';
import 'dart:convert';

import 'package:universal_io/io.dart';

/// Transport contract for one dictation session.
///
/// The rest of the client never sees which transport is in use: only
/// [DictationTransportResolver] chooses one.
abstract class DictationTransport {
  /// Decoded daemon events (`stt_status`, `dictation_ready`, `dictation_final`,
  /// `dictation_error`, ...). Payload keeps the `event` key.
  Stream<Map<String, dynamic>> get events;

  /// True while the underlying connection is usable.
  bool get isOpen;

  void sendCommand(String event, [Map<String, dynamic> payload = const {}]);

  void sendAudio(List<int> pcm16);

  Future<void> close();
}

/// Raised when the resolved scope has no dictation transport yet.
class DictationTransportUnavailable implements Exception {
  const DictationTransportUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'DictationTransportUnavailable($reason)';
}

/// Local daemon WebSocket transport (`/ws?type=dictation`).
class LocalDictationTransport implements DictationTransport {
  LocalDictationTransport._(this._socket);

  final WebSocket _socket;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  late final StreamSubscription _subscription;
  bool _open = true;

  static Future<LocalDictationTransport> connect({
    required Uri localGatewayUrl,
    required String sessionId,
    required String deviceId,
    required Future<Map<String, String>> Function() headers,
  }) async {
    final socket = await WebSocket.connect(
      _webSocketUri(localGatewayUrl, sessionId, deviceId).toString(),
      headers: await headers(),
    );
    return LocalDictationTransport._(socket).._listen();
  }

  void _listen() {
    _subscription = _socket.listen(
      (message) {
        if (message is! String) return; // dictation never receives audio
        try {
          final decoded = jsonDecode(message);
          if (decoded is Map) {
            _events.add(Map<String, dynamic>.from(decoded));
          }
        } on FormatException {
          // Ignore malformed frames rather than kill the session.
        }
      },
      onDone: () {
        _open = false;
        unawaited(_events.close());
      },
      onError: (Object error) {
        _open = false;
        _events.addError(error);
        unawaited(_events.close());
      },
    );
  }

  static Uri _webSocketUri(
    Uri base,
    String sessionId,
    String deviceId,
  ) {
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final path = base.path.isEmpty || base.path == '/' ? '/ws' : base.path;
    return base.replace(
      scheme: scheme,
      path: path,
      queryParameters: {
        'type': 'dictation',
        'session_id': sessionId,
        'device_id': deviceId,
      },
    );
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get isOpen => _open;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {
    if (!_open) return;
    _socket.add(jsonEncode({'event': event, ...payload}));
  }

  @override
  void sendAudio(List<int> pcm16) {
    if (!_open || pcm16.isEmpty) return;
    _socket.add(pcm16);
  }

  @override
  Future<void> close() async {
    _open = false;
    await _subscription.cancel();
    if (!_events.isClosed) await _events.close();
    try {
      await _socket.close();
    } on Object {
      // Peer may already be gone.
    }
  }
}
