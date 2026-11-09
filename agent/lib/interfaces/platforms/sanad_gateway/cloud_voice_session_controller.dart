import 'dart:async';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:sanad_agent/infrastructure/voice/gemini_voice_provider.dart';
import 'package:sanad_agent/infrastructure/voice/voice_engine.dart';
import 'package:sanad_agent/infrastructure/voice/voice_transport_channel.dart';

/// Owns the hosted realtime voice sessions of one Gateway registration.
///
/// Session identity is the transport identity: a session without one cannot be
/// routed to a single Client, and the only delivery left would be the
/// account-wide broadcast the origin-scoped relay removes. Such a session is
/// refused on its origin claim instead of degrading.
class CloudVoiceSessionController {
  CloudVoiceSessionController({
    required Logger logger,
    required Future<void> Function(Map<String, dynamic> reply) emitCommandReply,
    required Future<void> Function(Map<String, dynamic> envelope) emitDeviceEvent,
  }) : _logger = logger,
       _emitCommandReply = emitCommandReply,
       _emitDeviceEvent = emitDeviceEvent;

  final Logger _logger;
  final Future<void> Function(Map<String, dynamic> reply) _emitCommandReply;
  final Future<void> Function(Map<String, dynamic> envelope) _emitDeviceEvent;
  final _engines = <String, VoiceEngine>{};

  /// Starts one hosted session, replacing any engine still bound to the id.
  Future<void> start(
    String sessionId,
    String deviceId, {
    required String requestId,
  }) async {
    await stop(sessionId);

    if (sessionId.isEmpty ||
        sessionId == 'default' ||
        requestId.isEmpty ||
        requestId != sessionId) {
      _logger.warning('Rejected cloud voice session without session identity.');
      _emitVoiceRelayError(
        requestId: requestId.isEmpty ? sessionId : requestId,
        sessionId: sessionId,
        code: 'identity_required',
      );
      return;
    }

    try {
      final channel = CloudSocketIoTransportChannel(
        deviceId: deviceId,
        sessionId: sessionId,
        requestId: requestId,
      );
      final provider = GeminiRealtimeVoiceProvider();
      final engine = VoiceEngine(
        channel: channel,
        provider: provider,
        sessionId: sessionId,
      );
      _engines[sessionId] = engine;

      unawaited(
        engine
            .start({'session_id': sessionId, 'device_id': deviceId})
            .catchError((Object _) {
              _logger.severe('Failed to start cloud VoiceEngine');
              if (_engines[sessionId] == engine) {
                _engines.remove(sessionId);
              }
            }),
      );

      await _emitCommandReply({
        'device_id': deviceId,
        'type': 'event',
        'event': 'voice_session_started',
        'payload': {'session_id': sessionId},
      });
    } catch (_) {
      _logger.severe('Error starting cloud voice session');
    }
  }

  Future<void> stop(String sessionId) async {
    final engine = _engines.remove(sessionId);
    if (engine != null) {
      _logger.info('Closing active voice engine');
      await engine.close();
    }
  }

  /// Closes every engine this registration still owns.
  Future<void> closeAll() async {
    for (final engine in _engines.values.toList()) {
      await engine.close();
    }
    _engines.clear();
  }

  /// Answers a refused voice session on the origin claim only.
  ///
  /// The Client turns this into the localized update-required state; it never
  /// falls back to a broadcast or a degraded session.
  void _emitVoiceRelayError({
    required String requestId,
    required String sessionId,
    required String code,
  }) {
    if (requestId.isEmpty || requestId == 'default') return;
    unawaited(
      _emitDeviceEvent({
        'type': 'device_event',
        'event': 'voice_relay_error',
        'event_id': const Uuid().v4(),
        'session_id': sessionId,
        'delivery': {'scope': 'origin', 'request_id': requestId},
        'payload': {
          'version': 'v1',
          'session_id': sessionId,
          'request_id': requestId,
          'error_code': code,
        },
      }),
    );
  }
}
