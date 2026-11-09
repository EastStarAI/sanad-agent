import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';

/// Abstract class representing a generic transport channel for voice audio and control signals.
abstract class VoiceTransportChannel {
  /// Stream of incoming audio chunks (microphone PCM 16kHz).
  Stream<List<int>> get inputAudioStream;

  /// Stream of control events (e.g. "interrupt", "stop_voice").
  Stream<String> get controlEvents;

  /// Send output audio back to the client (speaker PCM 24kHz).
  void sendOutputAudio(List<int> pcmChunk);

  /// Send control signals or transcription text back to the client.
  void sendControlEvent(String eventName, Map<String, dynamic> payload);

  /// Close the transport channel.
  Future<void> close();
}

/// Local WebSocket implementation of [VoiceTransportChannel].
class LocalWebSocketTransportChannel extends VoiceTransportChannel {
  final _logger = Logger('LocalWebSocketTransportChannel');
  final WebSocket _webSocket;
  final _audioController = StreamController<List<int>>.broadcast();
  final _controlController = StreamController<String>.broadcast();
  late final StreamSubscription _subscription;
  int _audioChunkCount = 0;

  LocalWebSocketTransportChannel(this._webSocket) {
    _subscription = _webSocket.listen(
      (message) {
        if (message is List<int>) {
          _audioChunkCount++;
          if (_audioChunkCount == 1 || _audioChunkCount % 50 == 0) {
            _logger.info(
              '🎙️ Audio chunk #$_audioChunkCount from Flutter: ${message.length} bytes → Gemini',
            );
          }
          _audioController.add(message);
        } else if (message is String) {
          try {
            final Map<String, dynamic> decoded = jsonDecode(message);
            final eventName = decoded['event'] as String?;
            if (eventName != null) {
              _logger.info('🎮 Control event from Flutter: $eventName');
              _controlController.add(eventName);
            }
          } catch (e) {
            _logger.warning(
              'Failed to decode websocket text message: $message, error: $e',
            );
          }
        } else {
          _logger.warning('Unexpected message type: ${message.runtimeType}');
        }
      },
      onDone: () {
        _logger.info('Local WebSocket channel done.');
        close();
      },
      onError: (err) {
        _logger.severe('Local WebSocket channel error: $err');
        close();
      },
    );
  }

  @override
  Stream<List<int>> get inputAudioStream => _audioController.stream;

  @override
  Stream<String> get controlEvents => _controlController.stream;

  int _outputChunkCount = 0;

  @override
  void sendOutputAudio(List<int> pcmChunk) {
    try {
      _outputChunkCount++;
      if (_outputChunkCount == 1 || _outputChunkCount % 50 == 0) {
        _logger.info(
          '🔊 Audio chunk #$_outputChunkCount from Gemini → Flutter: ${pcmChunk.length} bytes',
        );
      }
      _webSocket.add(pcmChunk);
    } catch (e) {
      _logger.warning('Failed to send output audio: $e');
    }
  }

  @override
  void sendControlEvent(String eventName, Map<String, dynamic> payload) {
    try {
      final message = jsonEncode({
        'type': 'device_event',
        'event': eventName,
        'payload': payload,
      });
      _webSocket.add(message);
    } catch (e) {
      _logger.warning('Failed to send control event: $e');
    }
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _audioController.close();
    await _controlController.close();
    await _webSocket.close();
  }
}

/// Cloud Socket.IO implementation of [VoiceTransportChannel].
///
/// One instance serves exactly one voice session: it carries the session and
/// request identity on every outbound frame and drops relayed traffic that
/// belongs to another session, so a daemon serving two sessions can never
/// cross-wire audio, transcript, or interruption state.
class CloudSocketIoTransportChannel extends VoiceTransportChannel {
  final _logger = Logger('CloudSocketIoTransportChannel');
  final String deviceId;

  /// One voice session identity (`session_id`), minted by the Client.
  final String sessionId;

  /// Origin correlation identity; the contract makes it equal to [sessionId].
  final String requestId;

  late final io.Socket _socket;
  final _audioController = StreamController<List<int>>.broadcast();
  final _controlController = StreamController<String>.broadcast();

  CloudSocketIoTransportChannel({
    required this.deviceId,
    required this.sessionId,
    required this.requestId,
  }) {
    final gatewayPlatform = getIt<ServerSanadGatewayPlatform>();
    final socket = gatewayPlatform.socket;
    if (socket == null) {
      throw StateError(
        'Socket.IO is not initialized on ServerSanadGatewayPlatform',
      );
    }
    _socket = socket;

    _socket.on('voice_audio_chunk_relay', _onAudioChunk);
    _socket.on('voice_control_relay', _onControlEvent);
  }

  /// True only for a frame carrying this exact session/request identity.
  ///
  /// A frame without identity is foreign by definition: there is no account-wide
  /// or per-device fallback, because the only thing that fallback can do is
  /// deliver another client's speech into this session.
  bool _isOwnIdentity(Map data) {
    final frameSession = data['session_id'];
    final frameRequest = data['request_id'];
    return frameSession == sessionId && frameRequest == requestId;
  }

  void _onAudioChunk(dynamic data) {
    if (data is! Map || !_isOwnIdentity(data)) return;
    final audioData = data['data'];
    if (audioData is List<int>) {
      _audioController.add(audioData);
    } else if (audioData is List) {
      _audioController.add(List<int>.from(audioData));
    }
  }

  void _onControlEvent(dynamic data) {
    if (data is! Map || !_isOwnIdentity(data)) return;
    final eventName = data['event'] as String?;
    if (eventName != null) {
      _controlController.add(eventName);
    }
  }

  @override
  Stream<List<int>> get inputAudioStream => _audioController.stream;

  @override
  Stream<String> get controlEvents => _controlController.stream;

  @override
  void sendOutputAudio(List<int> pcmChunk) {
    if (!_socket.connected) {
      _logger.warning('Cannot send output audio: Socket.IO is disconnected');
      return;
    }
    // Identity is mandatory: without it the Gateway can only broadcast, and a
    // broadcast of synthesized speech reaches every Client in the account.
    _socket.emit('device_voice_audio_chunk', {
      'device_id': deviceId,
      'session_id': sessionId,
      'request_id': requestId,
      'data': pcmChunk,
    });
  }

  @override
  void sendControlEvent(String eventName, Map<String, dynamic> payload) {
    if (!_socket.connected) {
      _logger.warning('Cannot send control event: Socket.IO is disconnected');
      return;
    }
    _socket.emit('device_event', {
      'device_id': deviceId,
      'type': 'device_event',
      'event': eventName,
      'event_id': const Uuid().v4(),
      'session_id': sessionId,
      'delivery': {'scope': 'origin', 'request_id': requestId},
      'payload': payload,
    });
  }

  @override
  Future<void> close() async {
    // Detach only this session's listeners: the socket is shared with commands,
    // relay media, and presence, and is never disposed here.
    _socket.off('voice_audio_chunk_relay', _onAudioChunk);
    _socket.off('voice_control_relay', _onControlEvent);
    if (!_audioController.isClosed) await _audioController.close();
    if (!_controlController.isClosed) await _controlController.close();
  }
}
