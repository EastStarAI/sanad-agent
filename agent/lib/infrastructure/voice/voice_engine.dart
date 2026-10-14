import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'voice_transport_channel.dart';
import 'realtime_voice_provider.dart';

/// Orchestrates a real-time duplex voice streaming session.
class VoiceEngine {
  final _logger = Logger('VoiceEngine');
  final VoiceTransportChannel channel;
  final RealtimeVoiceProvider provider;
  final String sessionId;

  StreamSubscription? _audioSubscription;
  StreamSubscription? _controlSubscription;
  StreamSubscription? _providerSubscription;

  String _currentUserText = '';
  String _currentAssistantText = '';

  VoiceEngine({
    required this.channel,
    required this.provider,
    required this.sessionId,
  });

  /// Connects to the provider and begins duplex routing of audio and control events.
  Future<void> start(Map<String, dynamic> sessionConfig) async {
    _logger.info('Starting VoiceEngine for session: $sessionId');

    final config = Map<String, dynamic>.from(sessionConfig);
    config['session_id'] = sessionId;

    try {
      // 1. Connect the provider
      await provider.connect(config);

      // 2. Route Client -> Provider (Input Audio)
      _audioSubscription = channel.inputAudioStream.listen(
        (pcmChunk) {
          provider.handleInputAudio(pcmChunk);
        },
        onError: (err) =>
            _logger.severe('Error in transport inputAudioStream: $err'),
        onDone: () {
          _logger.info(
            'Transport inputAudioStream completed. Closing VoiceEngine.',
          );
          close();
        },
      );

      // 3. Route Client -> Provider (Control Events)
      _controlSubscription = channel.controlEvents.listen(
        (eventName) {
          provider.handleControlEvent(eventName, const {});
          if (eventName == 'interrupt') {
            _logger.info('User manually interrupted agent playback');
            _flushAssistantTurn(interrupted: true);
          }
        },
        onError: (err) =>
            _logger.severe('Error in transport controlEvents: $err'),
      );

      // 4. Route Provider -> Client (Output Audio, Transcript & Interruption Events)
      _providerSubscription = provider.outputEvents.listen(
        (event) {
          if (event is AudioOutputEvent) {
            channel.sendOutputAudio(event.pcmChunk);
          } else if (event is TextResponseEvent) {
            // New assistant speech output started. Save user turn.
            _flushUserTurn();
            _currentAssistantText += event.text;
            channel.sendControlEvent('voice_text_response', {
              'text': event.text,
            });
          } else if (event is UserTranscriptionEvent) {
            // New user speech input started. Save assistant turn.
            _flushAssistantTurn();
            _currentUserText += event.text;
            channel.sendControlEvent('voice_user_transcription', {
              'text': event.text,
            });
          } else if (event is InterruptedEvent) {
            _logger.info('Provider emitted InterruptedEvent');
            _flushAssistantTurn(interrupted: true);
            channel.sendControlEvent('voice_interrupted', const {});
          }
        },
        onError: (err) =>
            _logger.severe('Error in provider outputEvents: $err'),
        onDone: () => _logger.info('Provider outputEvents completed'),
      );
    } catch (e, stack) {
      _logger.severe('Failed to start VoiceEngine', e, stack);
      rethrow;
    }
  }

  void _flushUserTurn() {
    if (_currentUserText.trim().isNotEmpty) {
      _saveMessageToHistory(MessageRole.user, _currentUserText.trim());
      _currentUserText = '';
    }
  }

  void _flushAssistantTurn({bool interrupted = false}) {
    if (_currentAssistantText.trim().isNotEmpty) {
      var content = _currentAssistantText.trim();
      if (interrupted) {
        content = '$content... [Interrupted]';
      }
      _saveMessageToHistory(MessageRole.assistant, content);
      _currentAssistantText = '';
    }
  }

  void _saveMessageToHistory(MessageRole role, String content) {
    try {
      final sessionManager = getIt<SessionManager>();
      final messages = sessionManager.getMessages(sessionId);
      messages.add(Message(role: role, content: content));
      sessionManager.saveSessionHistory(sessionId, messages);
      _logger.info('Saved voice turn to database');
    } catch (e) {
      _logger.warning('Failed to save voice turn ($role) to database: $e');
    }
  }

  /// Closes subscriptions, provider, and transport channels, and persists any pending transcriptions.
  Future<void> close() async {
    _logger.info('Closing VoiceEngine for session: $sessionId');

    _flushUserTurn();
    _flushAssistantTurn();

    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _controlSubscription?.cancel();
    _controlSubscription = null;
    await _providerSubscription?.cancel();
    _providerSubscription = null;

    await provider.close();
    await channel.close();
  }
}
