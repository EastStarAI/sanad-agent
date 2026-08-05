import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';

import 'capabilities_loader.dart';
import 'sanad_protocol_bridge.dart';
import 'protocol/canonical_events.dart';
import 'channels/cloud_session_channel.dart';
import 'sanad_gateway_behavior.dart';
import 'package:sanad_agent/infrastructure/voice/gemini_voice_provider.dart';
import 'package:sanad_agent/infrastructure/voice/voice_engine.dart';
import 'package:sanad_agent/infrastructure/voice/voice_transport_channel.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';

class ServerSanadGatewayPlatform extends BasePlatform
    with SanadGatewayBehavior {
  final _logger = Logger('ServerSanadGatewayPlatform');

  @override
  Logger get logger => _logger;

  @override
  SanadProtocolBridge get protocolBridge => _protocolBridge;

  @override
  String get transportName => 'socket';
  final _eventController = StreamController<GatewayEvent>.broadcast();
  final _voiceEngines = <String, VoiceEngine>{};

  io.Socket? _socket;
  String? _registeredDeviceId;

  io.Socket? get socket => _socket;

  @override
  String get platformId => 'sanad_gateway';

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor.sanadClient(
    transport: PlatformTransport.cloud,
    platformInstanceId: 'sanad-gateway',
  );

  @override
  bool get receivesMirroredResponses => true;

  @override
  bool get shouldReceiveUserEcho => true;

  @override
  Stream<GatewayEvent> get eventStream => _eventController.stream;

  SanadProtocolBridge get _protocolBridge => getIt<SanadProtocolBridge>();

  @override
  Future<void> initialize() async {
    final authManager = getIt<AuthManager>();
    if (!authManager.isAuthenticated) {
      _logger.warning(
        'AuthManager not authenticated. Gateway connection skipped.',
      );
      return;
    }

    final config = getIt<Config>();
    final gatewayUrl = config.gatewayUrl;

    _logger.info('Connecting to Sanad Gateway at $gatewayUrl...');

    _socket = io.io(
      gatewayUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) async {
      _logger.info('⚡ Connected to Sanad Gateway');
      await _register();
    });

    _socket!.onDisconnect((reason) {
      _registeredDeviceId = null;
      _logger.info('🔌 Disconnected from Sanad Gateway (reason: $reason)');
    });

    _socket!.onConnectError(
      (err) => _logger.severe('❌ Connection Error: $err'),
    );
    _socket!.onError((err) => _logger.severe('❌ Socket Error: $err'));

    _socket!.on('register_success', (data) async {
      final envelope = toMap(data);
      final authManager = getIt<AuthManager>();
      if (authManager.hasPendingDevicePairing) {
        await authManager.completeDevicePairing();
      }
      _registeredDeviceId = envelope['device_id']?.toString();
      _logger.info(
        '⚡ Successfully registered with Sanad Gateway as device $_registeredDeviceId',
      );
    });

    _socket!.on('register_failed', (data) async {
      final envelope = toMap(data);
      final message = envelope['error'] as String? ?? 'Registration failed';
      final code = envelope['code'] as String? ?? '';
      _logger.severe('❌ Registration failed: $message (code: $code)');

      final authManager = getIt<AuthManager>();
      if (authManager.hasPendingDevicePairing) {
        _logger.severe(
          'Device pairing was rejected. Create a new device token and retry.',
        );
        return;
      }

      if (code == 'AUTH_INVALID_TOKEN' ||
          message.toLowerCase().contains('token')) {
        _logger.info('Attempting to refresh token...');
        final config = getIt<Config>();
        final success = await authManager.refreshAccessToken(config.portalUrl);

        if (success) {
          _logger.info('Token refreshed successfully. Reconnecting...');
          if (_socket!.disconnected) {
            _socket!.connect();
          } else {
            await _register();
          }
        } else {
          _logger.severe('❌ Failed to refresh token. Please login again.');
        }
      }
    });

    _socket!.on('execute_tool', (data) {
      final envelope = toMap(data);
      _logger.info(
        '⬇️ [socket] Received execute_tool: ${envelope['tool_name']}',
      );
      _logger.fine('⬇️ [socket] execute_tool payload: $envelope');
      // TODO: Implement tool execution mapping to agent tools
    });

    _socket!.on('execute_command', (data) async {
      final envelope = toMap(data);
      final command = envelope['command'] as String?;
      final payload = toMap(envelope['payload']);
      final sessionId = payload['session_id'] as String? ?? 'default';
      final deviceId =
          (envelope['device_id'] as String?) ??
          (payload['device_id'] as String?) ??
          '';

      final bridge = getIt<PlatformRuntimeBridge>();
      bridge.registerSessionClient(
        sessionId,
        CloudSessionChannel(onSend: _emitAgentEvent, deviceId: deviceId),
        deviceId: deviceId,
      );

      if (command == 'start_voice') {
        _logger.info(
          'Starting cloud voice session for session $sessionId, device $deviceId',
        );
        await _startVoiceSession(sessionId, deviceId);
        return;
      } else if (command == 'stop_voice') {
        _logger.info('Stopping cloud voice session for session $sessionId');
        await _stopVoiceSession(sessionId);
        return;
      }

      final handled = await handleIncomingCommand(
        envelope: envelope,
        runtimeBridge: bridge,
        onResponse: _emitAgentEvent,
      );
      if (handled) {
        return;
      }
      final gatewayEvent = _protocolBridge.translateCommand(
        envelope,
        platformId,
      );
      if (gatewayEvent == null) {
        _logger.warning('Unknown or unhandled command: $command');
        return;
      }
      _eventController.add(gatewayEvent);
    });

    _socket!.on('protocol_event', (data) async {
      final envelope = toMap(data);
      final event = CanonicalEvent.fromJson(envelope);
      final bridge = getIt<PlatformRuntimeBridge>();
      await handleIncomingProtocolEvent(
        event: event,
        runtimeBridge: bridge,
        onResponse: _emitAgentEvent,
        envelope: envelope,
      );
    });

    _socket!.connect();
  }

  Future<void> _startVoiceSession(String sessionId, String deviceId) async {
    await _stopVoiceSession(sessionId);

    try {
      final channel = CloudSocketIoTransportChannel(deviceId);
      final provider = GeminiRealtimeVoiceProvider();
      final engine = VoiceEngine(
        channel: channel,
        provider: provider,
        sessionId: sessionId,
      );
      _voiceEngines[sessionId] = engine;

      unawaited(
        engine
            .start({'session_id': sessionId, 'device_id': deviceId})
            .catchError((Object err) {
              _logger.severe('Failed to start cloud VoiceEngine: $err');
              if (_voiceEngines[sessionId] == engine) {
                _voiceEngines.remove(sessionId);
              }
            }),
      );

      await _emitAgentEvent({
        'device_id': deviceId,
        'type': 'event',
        'event': 'voice_session_started',
        'payload': {'session_id': sessionId},
      });
    } catch (e, stack) {
      _logger.severe('Error starting cloud voice session: $e', e, stack);
    }
  }

  Future<void> _stopVoiceSession(String sessionId) async {
    final engine = _voiceEngines.remove(sessionId);
    if (engine != null) {
      _logger.info('Closing active voice engine for session $sessionId');
      await engine.close();
    }
  }

  Future<void> _register() async {
    final authManager = getIt<AuthManager>();
    await authManager.reload();
    final capabilities = await loadSanadCapabilities();

    final isPairing = authManager.hasPendingDevicePairing;
    final payload = {
      if (isPairing) ...{
        'pairing_token': authManager.pairingToken,
        'proposed_device_token': authManager.pendingDeviceToken,
      } else ...{
        if (authManager.accessToken != null) 'token': authManager.accessToken,
        if (authManager.deviceToken != null)
          'device_token': authManager.deviceToken,
      },
      'hardware_id': authManager.hardwareId,
      'platform': _getPlatformName(),
      ...capabilities.toJson(),
    };

    _logger.info(
      '⬆️ [socket] Registering device with hardware_id: ${authManager.hardwareId}',
    );
    _logger.fine('⬆️ [socket] Registration fields: ${payload.keys.join(', ')}');

    _socket!.emit('register_device', payload);
  }

  Future<void> _emitAgentEvent(Map<String, dynamic> envelope) async {
    if (_socket == null || !_socket!.connected) {
      return;
    }

    final deviceId = _registeredDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      _logger.warning(
        'Skipping device event before gateway registration completes.',
      );
      return;
    }

    final authManager = getIt<AuthManager>();
    final canonicalEnvelope = {
      ...envelope,
      'device_id': deviceId,
      'hardware_id': authManager.hardwareId,
    };
    final eventType =
        canonicalEnvelope['event'] ?? canonicalEnvelope['type'] ?? 'unknown';
    if (eventType == 'thought_stream' || eventType == 'reasoning_stream') {
      _logger.fine('⬆️ [socket] Emitting device_event: $eventType');
    } else {
      _logger.info('⬆️ [socket] Emitting device_event: $eventType');
    }
    _logger.fine('⬆️ [socket] Device event payload: $canonicalEnvelope');

    _socket!.emit('device_event', canonicalEnvelope);
  }

  String _getPlatformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    final canonicalEvent = _protocolBridge.translateResponse(response);
    await _emitAgentEvent(
      _protocolBridge.buildAgentEventEnvelope(canonicalEvent),
    );
  }

  @override
  Future<void> dispose() async {
    await _eventController.close();
    for (final engine in _voiceEngines.values.toList()) {
      await engine.close();
    }
    _voiceEngines.clear();
    _socket?.dispose();
  }
}
