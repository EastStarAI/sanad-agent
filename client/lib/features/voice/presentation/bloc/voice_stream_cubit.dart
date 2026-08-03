import 'package:logging/logging.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:universal_io/io.dart';

import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/voice/domain/services/voice_stream_service.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_uri_policy.dart';
import 'package:sanad_client/utils/app_platform.dart';

import 'voice_stream_state.dart';

class VoiceStreamCubit extends Cubit<VoiceStreamState> {
  static final _logger = Logger('VoiceStreamCubit');

  final VoiceStreamService _voiceStreamService;
  final DeviceConnectionCoordinator _connectionCoordinator;
  final LocalGatewayCredentialProvider _localCredentialProvider;

  WebSocket? _localWs;
  StreamSubscription? _localWsSubscription;
  StreamSubscription? _cloudSocketSubscription;
  StreamSubscription? _recorderSubscription;
  int _chunkLogCount = 0;
  bool _isSpeaking = false;
  DateTime? _lastSpeechTime;

  // Pre-trigger circular buffer for Voice Activity Detection (VAD)
  final List<List<int>> _preTriggerBuffer = [];
  static const int _maxPreTriggerBytes = 12800; // ~400ms of 16kHz 16-bit mono PCM (32000 bytes/sec)
  int _preTriggerBytesCount = 0;

  VoiceStreamCubit({
    required VoiceStreamService voiceStreamService,
    required DeviceConnectionCoordinator connectionCoordinator,
    LocalGatewayCredentialProvider localCredentialProvider = const LocalGatewayCredentialProvider(),
  }) : _voiceStreamService = voiceStreamService,
       _connectionCoordinator = connectionCoordinator,
       _localCredentialProvider = localCredentialProvider,
       super(const VoiceStreamState());

  Future<void> startVoiceSession({
    required DeviceConfig agent,
    required String sessionId,
  }) async {
    _logger.info('=== [VoiceStreamCubit] startVoiceSession called ===');
    if (state.isSessionActive) {
      _logger.info('[VoiceStreamCubit] Session is already active, stopping first');
      await stopVoiceSession();
    }

    emit(
      state.copyWith(
        isSessionActive: true,
        status: VoiceSessionStatus.connecting,
        activeAgentId: agent.id,
        activeSessionId: sessionId,
        isMuted: false,
        clearError: true,
      ),
    );

    _isSpeaking = false;
    _lastSpeechTime = null;

    try {
      // 1. Resolve Connection Scope
      _logger.info('[VoiceStreamCubit] Resolving connection endpoint for agent: ${agent.id}');
      final endpoint = _connectionCoordinator.resolve(agent);
      _logger.info('[VoiceStreamCubit] Connection scope resolved: ${endpoint.scope}');
      if (endpoint.scope == ConnectionScope.local && !AppPlatform.isDesktop) {
        throw const LocalGatewayCredentialException('remote_only_platform');
      }

      // 2. Start audio services
      _logger.info('[VoiceStreamCubit] Starting audio playback...');
      await _voiceStreamService.startPlayback();
      _logger.info('[VoiceStreamCubit] Audio playback started. Starting microphone recording...');
      final recordStream = await _voiceStreamService.startRecording();
      _logger.info('[VoiceStreamCubit] Microphone recording stream obtained.');

      if (endpoint.scope == ConnectionScope.local) {
        // --- LOCAL CONNECTION SCOPE ---
        final wsUri = LocalGatewayUriPolicy.requireWebSocket(
          _toLocalWebSocketUri(
            AppConfig.localGatewayUrl,
            sessionId: sessionId,
            deviceId: agent.id,
          ),
        );

        _logger.info('[VoiceStreamCubit] Connecting local WebSocket to: $wsUri');
        _localWs = await WebSocket.connect(
          wsUri.toString(),
          headers: await _localCredentialProvider.headers(),
        );
        _logger.info('[VoiceStreamCubit] Local WebSocket connected successfully');

        // Route local WS incoming messages to player
        _localWsSubscription = _localWs!.listen(
          (message) async {
            if (message is List<int>) {
              _logger.info('[VoiceStreamCubit] Local WS: Received audio chunk of size: ${message.length}');
              _voiceStreamService.playAudioChunk(message);
            } else if (message is String) {
              _logger.info('[VoiceStreamCubit] Local WS: Received control message: $message');
              try {
                final Map<String, dynamic> decoded = jsonDecode(message);
                final type = decoded['type'];
                final event = decoded['event'];

                if (type == 'device_event') {
                  if (event == 'voice_interrupted') {
                    _logger.info('[VoiceStreamCubit] Interruption received locally. Clearing playback.');
                    await _voiceStreamService.startPlayback(); // Clear and restart playback
                  } else if (event == 'voice_text_response') {
                    emit(state.copyWith(status: VoiceSessionStatus.speaking));
                  } else if (event == 'voice_user_transcription') {
                    emit(state.copyWith(status: VoiceSessionStatus.listening));
                  }
                }
              } catch (e) {
                _logger.severe('[VoiceStreamCubit] Error parsing local voice control msg: $e');
              }
            }
          },
          onDone: () async {
            _logger.info('[VoiceStreamCubit] Local WS connection closed (onDone)');
            await stopVoiceSession();
          },
          onError: (err) async {
            _logger.severe('[VoiceStreamCubit] Local WS connection error (onError): $err');
            emit(
              state.copyWith(
                status: VoiceSessionStatus.error,
                errorMessage: 'Local connection error: $err',
              ),
            );
            await stopVoiceSession();
          },
        );

        // Route mic recording to local WS
        _recorderSubscription = recordStream.listen(
          (chunk) {
            if (state.isMuted) return;
            _handleMicChunk(
              chunk,
              sendFn: (data) {
                _localWs?.add(data);
              },
            );
          },
          onError: (err) => _logger.severe('[VoiceStreamCubit] Microphone stream error: $err'),
        );
      } else {
        // --- CLOUD CONNECTION SCOPE ---
        _logger.info('[VoiceStreamCubit] Cloud connection scope selected');
        final cloudSocket = _connectionCoordinator.cloudSocketService;
        if (!cloudSocket.isConnected) {
          _logger.info('[VoiceStreamCubit] Cloud socket not connected, attempting to connect...');
          await cloudSocket.connect();
        }

        // Start session command
        _logger.info('[VoiceStreamCubit] Emitting start_voice command to cloud...');
        cloudSocket.sendDeviceCommand(
          deviceId: agent.id,
          command: 'start_voice',
          payload: {
            'session_id': sessionId,
          },
        );

        // Listen to Socket.IO events relayed from cloud
        _cloudSocketSubscription = cloudSocket.events.listen((event) async {
          final eventName = event['event'] as String?;

          if (event['type'] == 'voice_audio_chunk_relay') {
            final audioData = event['data'];
            if (audioData is List<int>) {
              _voiceStreamService.playAudioChunk(audioData);
            } else if (audioData is List) {
              _voiceStreamService.playAudioChunk(List<int>.from(audioData));
            } else if (audioData is String) {
              _voiceStreamService.playAudioChunk(base64Decode(audioData));
            }
          } else if (event['type'] == 'device_event') {
            if (eventName == 'voice_interrupted') {
              _logger.info('[VoiceStreamCubit] Interruption received from cloud. Clearing playback.');
              await _voiceStreamService.startPlayback();
            } else if (eventName == 'voice_text_response') {
              emit(state.copyWith(status: VoiceSessionStatus.speaking));
            } else if (eventName == 'voice_user_transcription') {
              emit(state.copyWith(status: VoiceSessionStatus.listening));
            }
          }
        });

        // Route mic recording to cloud Socket.IO
        _recorderSubscription = recordStream.listen(
          (chunk) {
            if (state.isMuted) return;
            _handleMicChunk(
              chunk,
              sendFn: (data) {
                cloudSocket.emit('voice_audio_chunk', {
                  'device_id': agent.id,
                  'data': data,
                });
              },
            );
          },
          onError: (err) => _logger.severe('[VoiceStreamCubit] Microphone stream error: $err'),
        );
      }

      _logger.info('[VoiceStreamCubit] Voice session successfully initialized. Emitting status: listening.');
      emit(state.copyWith(status: VoiceSessionStatus.listening));
    } catch (e, stack) {
      _logger.severe('[VoiceStreamCubit] ERROR in startVoiceSession: $e');
      _logger.info(stack);
      emit(
        state.copyWith(
          isSessionActive: false,
          status: VoiceSessionStatus.error,
          errorMessage: 'Failed to start voice: $e',
        ),
      );
      await stopVoiceSession();
    }
  }

  /// Sends manual interrupt signal to current session
  void sendManualInterrupt() {
    if (!state.isSessionActive) return;

    final deviceId = state.activeAgentId;
    if (deviceId == null) return;

    unawaited(_voiceStreamService.startPlayback()); // Clear client speaker playback buffer

    if (_localWs != null) {
      // Local interruption
      _localWs?.add(jsonEncode({'event': 'interrupt'}));
    } else {
      // Cloud interruption
      _connectionCoordinator.cloudSocketService.sendDeviceCommand(
        deviceId: deviceId,
        command: 'voice_control',
        payload: {
          'event': 'interrupt',
        },
      );
    }
  }

  /// Toggles microphone mute state
  void toggleMute() {
    final newMute = !state.isMuted;
    _logger.info('[VoiceStreamCubit] Mute toggled: $newMute');
    emit(state.copyWith(isMuted: newMute));
  }

  Future<void> stopVoiceSession() async {
    if (!state.isSessionActive) return;

    _logger.info('[VoiceStreamCubit] stopVoiceSession() called. Stopping services...');

    // Stop audio services
    await _voiceStreamService.stopRecording();
    await _voiceStreamService.stopPlayback();

    // Cancel subscriptions
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;
    await _localWsSubscription?.cancel();
    _localWsSubscription = null;
    await _cloudSocketSubscription?.cancel();
    _cloudSocketSubscription = null;

    final wasLocal = _localWs != null;
    // Close sockets
    _logger.info('[VoiceStreamCubit] Closing WebSocket, wasLocal = $wasLocal');
    await _localWs?.close();
    _localWs = null;

    // Send stop command if cloud scope
    final deviceId = state.activeAgentId;
    if (deviceId != null && !wasLocal) {
      _logger.info('[VoiceStreamCubit] Emitting stop_voice to cloud socket...');
      _connectionCoordinator.cloudSocketService.sendDeviceCommand(
        deviceId: deviceId,
        command: 'stop_voice',
        payload: {
          'session_id': state.activeSessionId ?? 'default',
        },
      );
    }

    _preTriggerBuffer.clear();
    _preTriggerBytesCount = 0;

    emit(const VoiceStreamState());
    _logger.info('[VoiceStreamCubit] stopVoiceSession() completed. State reset.');
  }

  Uri _toLocalWebSocketUri(String rawUrl, {required String sessionId, required String deviceId}) {
    final base = Uri.parse(rawUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final path = base.path.isEmpty || base.path == '/' ? '/ws' : base.path;
    return base.replace(
      scheme: scheme,
      path: path,
      queryParameters: {
        'type': 'voice',
        'session_id': sessionId,
        'device_id': deviceId,
      },
    );
  }

  void _handleMicChunk(List<int> chunk, {required void Function(List<int>) sendFn}) {
    if (chunk.isEmpty) return;

    // Calculate RMS
    final buffer = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    final byteData = ByteData.sublistView(buffer);
    double sum = 0.0;
    final count = chunk.length ~/ 2;
    if (count == 0) return;
    for (int i = 0; i < chunk.length - 1; i += 2) {
      final sample = byteData.getInt16(i, Endian.little);
      sum += sample * sample;
    }
    final rms = sqrt(sum / count);

    _chunkLogCount++;
    if (_chunkLogCount % 20 == 0) {
      _logger.info(
        '[VoiceStreamCubit] Live Mic RMS: ${rms.toStringAsFixed(1)} (Speaking: $_isSpeaking, Buffered: $_preTriggerBytesCount bytes)',
      );
    }

    const double threshold = 120.0; // Lower threshold (AEC/comfort VAD)
    const Duration hangoverDuration = Duration(milliseconds: 800);

    if (!_isSpeaking) {
      // Not speaking yet: buffer the chunk in pre-trigger buffer
      _preTriggerBuffer.add(chunk);
      _preTriggerBytesCount += chunk.length;

      // Keep pre-trigger buffer within limit
      while (_preTriggerBytesCount > _maxPreTriggerBytes) {
        final removed = _preTriggerBuffer.removeAt(0);
        _preTriggerBytesCount -= removed.length;
      }

      // If RMS exceeds threshold, start speaking
      if (rms > threshold) {
        _isSpeaking = true;
        _lastSpeechTime = DateTime.now();
        _logger.info(
          '[VoiceStreamCubit] Speech detected (RMS: ${rms.toStringAsFixed(1)} > $threshold). Sending pre-trigger buffer (${_preTriggerBuffer.length} chunks) and current chunk.',
        );

        // Send all buffered chunks
        for (final bufferedChunk in _preTriggerBuffer) {
          sendFn(bufferedChunk);
        }
        _preTriggerBuffer.clear();
        _preTriggerBytesCount = 0;
      }
    } else {
      // Currently speaking
      if (rms > threshold) {
        _lastSpeechTime = DateTime.now();
        sendFn(chunk);
      } else {
        // Quiet chunk: check hangover
        if (_lastSpeechTime != null) {
          final elapsed = DateTime.now().difference(_lastSpeechTime!);
          if (elapsed < hangoverDuration) {
            sendFn(chunk); // Send during hangover to preserve word endings
          } else {
            // Hangover expired: stop speaking and start buffering
            _logger.info('[VoiceStreamCubit] Silence detected (Hangover expired). Muting stream.');
            _isSpeaking = false;
            _preTriggerBuffer.clear();
            _preTriggerBuffer.add(chunk);
            _preTriggerBytesCount = chunk.length;
          }
        } else {
          // Fallback
          _isSpeaking = false;
          _preTriggerBuffer.clear();
          _preTriggerBuffer.add(chunk);
          _preTriggerBytesCount = chunk.length;
        }
      }
    }
  }

  @override
  Future<void> close() async {
    await stopVoiceSession();
    return super.close();
  }
}
