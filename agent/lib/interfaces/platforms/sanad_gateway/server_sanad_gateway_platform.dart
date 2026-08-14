import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:logging/logging.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';

import 'capabilities_loader.dart';
import 'delivery_presence_controller.dart';
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
  static const _remoteWorkspaceManagementCommands = <String>{
    CanonicalEventTypes.createWorkspace,
    CanonicalEventTypes.relocateWorkspace,
    CanonicalEventTypes.browseWorkspaceTree,
    CanonicalEventTypes.createFolder,
    CanonicalEventTypes.renameFolder,
    CanonicalEventTypes.deleteFolder,
  };
  static const _remoteWorkspaceManagementDisabledCode =
      'remote_workspace_management_disabled';
  static const _remoteWorkspaceManagementDisabledMessage =
      'Remote workspace management is disabled for security reasons.';
  static const _remoteMcpManagementCommands = <String>{
    CanonicalEventTypes.listMcpServers,
    CanonicalEventTypes.saveMcpServer,
    CanonicalEventTypes.deleteMcpServer,
    CanonicalEventTypes.replaceMcpConfig,
    CanonicalEventTypes.inspectMcpServer,
    CanonicalEventTypes.previewMcpImport,
    CanonicalEventTypes.exportMcpServers,
    CanonicalEventTypes.readAdvancedMcpServer,
    CanonicalEventTypes.previewAdvancedMcpServer,
    CanonicalEventTypes.saveAdvancedMcpServer,
    CanonicalEventTypes.startMcpOAuth,
    CanonicalEventTypes.getMcpOAuthStatus,
    CanonicalEventTypes.cancelMcpOAuth,
    CanonicalEventTypes.completeMcpOAuth,
  };
  static const _remoteMcpManagementDisabledCode =
      'remote_mcp_management_disabled';
  static const _remoteMcpManagementDisabledMessage =
      'Remote MCP management is disabled for security reasons.';

  final _logger = Logger('ServerSanadGatewayPlatform');
  final io.Socket Function(String uri, dynamic options)? socketFactory;
  final Future<DeviceKeyIdentity> Function() identityLoader;
  final http.Client _httpClient;
  final DeliveryPresenceController? deliveryPresence;
  StreamSubscription<LocalPresenceSnapshot>? _localPresenceSubscription;
  Timer? _localPresenceRenewalTimer;

  ServerSanadGatewayPlatform({
    this.socketFactory,
    Future<DeviceKeyIdentity> Function()? identityLoader,
    http.Client? httpClient,
    this.deliveryPresence,
  }) : identityLoader = identityLoader ?? DeviceKeyIdentity.loadOrCreate,
       _httpClient = httpClient ?? http.Client();

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
  StreamSubscription<void>? _authChangeSubscription;
  Future<void>? _authSynchronizationFuture;
  bool _authSynchronizationPending = false;

  io.Socket? get socket => _socket;

  @visibleForTesting
  set socketForTesting(io.Socket? s) => _socket = s;

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
    _localPresenceSubscription ??= deliveryPresence?.localChanges.listen(
      _publishLocalPresence,
    );
    if (deliveryPresence != null) {
      _localPresenceRenewalTimer ??= Timer.periodic(
        deliveryPresenceRenewalInterval,
        (_) => deliveryPresence!.renewLocalSnapshot(),
      );
    }
    final authManager = getIt<AuthManager>();
    _authChangeSubscription ??= authManager.changes.listen((_) {
      unawaited(_synchronizeAuthentication());
    });
    if (!authManager.canAuthenticateCloudAgent) {
      _logger.info('Cloud Gateway remains offline until Agent authorization.');
      return;
    }

    if (_socket == null) {
      final config = getIt<Config>();
      final gatewayUrl = config.gatewayUrl;

      _logger.info('Connecting to Sanad Gateway at $gatewayUrl...');

      final options = io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build();
      _socket =
          socketFactory?.call(gatewayUrl, options) ??
          io.io(gatewayUrl, options);
    }

    _socket!.onConnect((_) async {
      _logger.info('⚡ Connected to Sanad Gateway');
      await _register();
    });

    _socket!.on('device_challenge', (data) async {
      final nonce = toMap(data)['nonce']?.toString();
      if (nonce == null || nonce.isEmpty) return;
      await _register(challengeNonce: nonce);
    });

    _socket!.onDisconnect((reason) {
      _registeredDeviceId = null;
      deliveryPresence?.clearInterest();
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
      deliveryPresence?.renewLocalSnapshot();
    });

    _socket!.on('cloud_delivery_interest', (data) {
      final accepted = deliveryPresence?.acceptInterest(toMap(data)) ?? false;
      if (accepted) {
        _socket?.emit('cloud_delivery_interest_ack', {
          'version': deliveryPresenceVersion,
          'revision': toMap(data)['revision'],
        });
      }
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
        _logger.warning(
          'Agent credential was rejected. Reauthorize or pair this Agent.',
        );
      }
    });

    _socket!.on('execute_tool', (data) {
      final envelope = toMap(data);
      _logger.info(
        '⬇️ [socket] Received execute_tool: ${envelope['tool_name']}',
      );
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

      if (command == 'authentication_exchange') {
        _logger.warning('Blocking cloud authentication_exchange command.');
        return;
      }

      if (_isRemoteWorkspaceManagementCommand(command)) {
        await _rejectRemoteWorkspaceManagement(
          command: command!,
          requestId:
              envelope['request_id']?.toString() ??
              payload['request_id']?.toString(),
          sessionId: sessionId,
          deviceId: deviceId,
        );
        return;
      }
      if (_isRemoteMcpManagementCommand(command)) {
        await _rejectRemoteMcpManagement(
          command: command!,
          requestId:
              envelope['request_id']?.toString() ??
              payload['request_id']?.toString(),
          sessionId: sessionId,
          deviceId: deviceId,
        );
        return;
      }

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
      final sessionId =
          event.sessionId ?? envelope['session_id'] as String? ?? 'default';
      final deviceId = envelope['device_id'] as String? ?? '';

      if (event.type == 'authentication_exchange') {
        _logger.warning('Blocking cloud authentication_exchange event.');
        return;
      }

      if (_isRemoteWorkspaceManagementCommand(event.type)) {
        await _rejectRemoteWorkspaceManagement(
          command: event.type,
          requestId:
              event.payload['request_id']?.toString() ??
              envelope['request_id']?.toString(),
          sessionId: sessionId,
          deviceId: deviceId,
        );
        return;
      }
      if (_isRemoteMcpManagementCommand(event.type)) {
        await _rejectRemoteMcpManagement(
          command: event.type,
          requestId:
              event.payload['request_id']?.toString() ??
              envelope['request_id']?.toString(),
          sessionId: sessionId,
          deviceId: deviceId,
        );
        return;
      }

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

  Future<void> _synchronizeAuthentication() async {
    _authSynchronizationPending = true;
    if (_authSynchronizationFuture != null) {
      return _authSynchronizationFuture!;
    }

    final operation = () async {
      while (_authSynchronizationPending) {
        _authSynchronizationPending = false;
        await _synchronizeAuthenticationInternal();
      }
    }();
    _authSynchronizationFuture = operation;
    try {
      await operation;
    } finally {
      _authSynchronizationFuture = null;
      if (_authSynchronizationPending) {
        unawaited(_synchronizeAuthentication());
      }
    }
  }

  Future<void> _synchronizeAuthenticationInternal() async {
    final authManager = getIt<AuthManager>();
    if (!authManager.canAuthenticateCloudAgent) {
      _registeredDeviceId = null;
      _socket?.disconnect();
      _socket?.dispose();
      _socket = null;
      _logger.info('Cloud Gateway disconnected without Agent authorization.');
      return;
    }

    if (_socket == null) {
      await initialize();
      return;
    }
    if (_socket!.connected) {
      await _register();
    } else {
      _socket!.connect();
    }
  }

  bool _isRemoteWorkspaceManagementCommand(String? command) =>
      command != null && _remoteWorkspaceManagementCommands.contains(command);

  Future<void> _rejectRemoteWorkspaceManagement({
    required String command,
    required String? requestId,
    required String sessionId,
    required String deviceId,
  }) async {
    _logger.warning('Blocking remote workspace command: $command');
    await _emitAgentEvent({
      'device_id': _registeredDeviceId ?? deviceId,
      'type': 'event',
      'event': 'error',
      'payload': {
        'request_id': requestId,
        'code': _remoteWorkspaceManagementDisabledCode,
        'message': _remoteWorkspaceManagementDisabledMessage,
      },
      'session_id': sessionId,
    });
  }

  bool _isRemoteMcpManagementCommand(String? command) =>
      command != null && _remoteMcpManagementCommands.contains(command);

  Future<void> _rejectRemoteMcpManagement({
    required String command,
    required String? requestId,
    required String sessionId,
    required String deviceId,
  }) async {
    _logger.warning('Blocking remote MCP command: $command');
    await _emitAgentEvent({
      'device_id': _registeredDeviceId ?? deviceId,
      'type': 'event',
      'event': 'error',
      'payload': {
        'request_id': requestId,
        'code': _remoteMcpManagementDisabledCode,
        'message': _remoteMcpManagementDisabledMessage,
      },
      'session_id': sessionId,
    });
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

  Future<void> _calibrateIdentityTime(DeviceKeyIdentity identity) async {
    final portalUri = Uri.parse(getIt<Config>().portalUrl);
    if (portalUri.scheme != 'https') return;
    try {
      final response = await _httpClient
          .head(portalUri)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 500) return;
      final offset = DeviceAuthorizationClient.trustedServerTimeOffset(
        portalUri,
        response.headers['date'],
      );
      await identity.rememberServerTimeOffset(offset);
      if (offset.inSeconds.abs() > 300) {
        _logger.warning(
          'Local clock differs from the Portal; Gateway proofs will use the '
          'authenticated Portal time.',
        );
      }
    } on Object {
      // A missing calibration response does not replace the normal signed
      // registration failure path or authorize an untrusted time source.
    }
  }

  Future<void> _register({String? challengeNonce}) async {
    final targetSocket = _socket;
    if (targetSocket == null) return;
    final authManager = getIt<AuthManager>();
    await authManager.reload();
    final isPairing = authManager.hasPendingDevicePairing;
    final requiresKeyProof = authManager.deviceToken != null || isPairing;
    if (requiresKeyProof && challengeNonce == null) {
      targetSocket.emit('request_device_challenge');
      return;
    }
    final identity = requiresKeyProof ? await identityLoader() : null;
    if (identity != null) {
      await _calibrateIdentityTime(identity);
    }
    final deviceProof = identity != null
        ? await identity.gatewayProof(challengeNonce!)
        : null;
    final capabilities = await loadSanadCapabilities();
    if (!identical(_socket, targetSocket) || !targetSocket.connected) return;

    final payload = {
      if (isPairing) ...{
        'pairing_token': authManager.pairingToken,
        'proposed_device_token': authManager.pendingDeviceToken,
        'public_jwk': identity!.publicJwk,
        'device_proof': deviceProof,
      } else ...{
        if (authManager.deviceToken != null)
          'device_token': authManager.deviceToken,
        'device_proof': ?deviceProof,
      },
      'hardware_id': authManager.hardwareId,
      'platform': _getPlatformName(),
      ...capabilities.toJson(),
      'transport_capabilities': const [deliveryPresenceCapability],
    };

    _logger.info(
      '⬆️ [socket] Registering device with hardware_id: ${authManager.hardwareId}',
    );
    _logger.fine('⬆️ [socket] Registration fields: ${payload.keys.join(', ')}');

    targetSocket.emit('register_device', payload);
  }

  void _publishLocalPresence(LocalPresenceSnapshot? snapshot) {
    final targetSocket = _socket;
    final deviceId = _registeredDeviceId;
    if (snapshot == null ||
        targetSocket == null ||
        !targetSocket.connected ||
        deviceId == null ||
        deviceId.isEmpty) {
      return;
    }
    targetSocket.emit('agent_local_presence', {
      'protocol': deliveryPresenceProtocol,
      'version': deliveryPresenceVersion,
      'type': 'agent.local_presence',
      'device_id': deviceId,
      'revision': snapshot.revision,
      'local_clients': snapshot.members
          .map((member) => member.toJson())
          .toList(growable: false),
      'capabilities': const [deliveryPresenceCapability],
    });
  }

  Future<void> _emitAgentEvent(
    Map<String, dynamic> envelope, {
    bool egressClaimed = false,
  }) async {
    if (!egressClaimed && deliveryPresence?.claimCloudEgress() == false) return;
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
    // The interest gate precedes canonical translation/serialization.
    if (deliveryPresence?.claimCloudEgress() == false) return;
    final canonicalEvent = _protocolBridge.translateResponse(response);
    await _emitAgentEvent(
      _protocolBridge.buildAgentEventEnvelope(canonicalEvent),
      egressClaimed: true,
    );
  }

  @override
  Future<void> dispose() async {
    _localPresenceRenewalTimer?.cancel();
    _localPresenceRenewalTimer = null;
    await _localPresenceSubscription?.cancel();
    _localPresenceSubscription = null;
    await _authChangeSubscription?.cancel();
    _authChangeSubscription = null;
    await _eventController.close();
    for (final engine in _voiceEngines.values.toList()) {
      await engine.close();
    }
    _voiceEngines.clear();
    _socket?.dispose();
  }
}
