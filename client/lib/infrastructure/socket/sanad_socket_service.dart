import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import 'package:sanad_client/core/interfaces/socket_gateway.dart';
import 'package:sanad_client/core/interfaces/socket_service.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/socket/event_deduplicator.dart';
import 'package:sanad_client/infrastructure/socket/event_router.dart';
import 'package:sanad_client/infrastructure/socket/hosted_conversation_media.dart';
import 'package:sanad_client/infrastructure/socket/hosted_media_relay_client.dart';
import 'package:sanad_client/infrastructure/socket/socket_command_transport.dart';
import 'package:sanad_client/infrastructure/socket/socket_connection_controller.dart';
import 'package:sanad_client/utils/app_platform.dart';

export 'hosted_media_relay_client.dart';
export 'socket_command_transport.dart';
export 'socket_connection_controller.dart';

/// Facade preserving [ISocketService] and [ISocketGateway] contracts while delegating
/// to cohesive owners:
/// - [SocketConnectionController]: lifecycle, transport selection, auth, and reconnect/backoff.
/// - [SocketCommandTransport]: command/tool dispatch and response correlation.
/// - [HostedMediaRelayClient]: hosted attachment admission and hosted media fetch.
class SanadSocketService implements ISocketService, ISocketGateway {
  static final _logger = Logger('SanadSocket');

  final String _hardwareId;
  String get hardwareId => _hardwareId;

  late final SocketConnectionController _connectionController;
  late final SocketCommandTransport _commandTransport;
  late final HostedMediaRelayClient _mediaRelayClient;

  SocketConnectionController get connectionController => _connectionController;
  SocketCommandTransport get commandTransport => _commandTransport;
  HostedMediaRelayClient get mediaRelayClient => _mediaRelayClient;

  final EventRouter _eventRouter = EventRouter();
  EventRouter get eventRouter => _eventRouter;

  /// Phase 27 — shared cross-transport event deduplicator. When set, the
  /// service consults it for every incoming `device_event` (cloud and local)
  /// and drops duplicates by `event_id` before routing or broadcasting.
  /// The `DeviceConnectionCoordinator` injects one shared instance across
  /// both transports so a same-device client never applies the same event
  /// twice during a transport switch or cloud fan-out.
  EventDeduplicator? eventDeduplicator;

  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  final _accountLifecycleResponseController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get accountLifecycleResponses => _accountLifecycleResponseController.stream;

  final _accountLifecycleRevokeController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get accountLifecycleRevokeResults => _accountLifecycleRevokeController.stream;

  final _accountLifecycleDeleteController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get accountLifecycleDeleteResults => _accountLifecycleDeleteController.stream;

  final _accountLifecycleChangedController = StreamController<void>.broadcast();
  Stream<void> get accountLifecycleChanges => _accountLifecycleChangedController.stream;

  final _remoteToolExecutionController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get remoteToolExecutionStream => _remoteToolExecutionController.stream;

  bool _isDisposed = false;

  SanadSocketService({
    required String url,
    required String hardwareId,
    String? clientInstanceId,
    ClientDisplayMetadata? clientMetadata,
    String? startToken,
    SocketTransportMode transportMode = SocketTransportMode.cloudSocketIo,
    LocalGatewayCredentialProvider? localCredentialProvider,
    bool localTransportEnabled = true,
    Duration Function(int attempt)? localReconnectDelay,
    CloudSocketFactory cloudSocketFactory = socket_io.io,
    SocketConnectionController? connectionController,
    SocketCommandTransport? commandTransport,
    HostedMediaRelayClient? mediaRelayClient,
  }) : _hardwareId = hardwareId {
    _connectionController = connectionController ??
        SocketConnectionController(
          url: url,
          hardwareId: hardwareId,
          clientInstanceId: clientInstanceId,
          clientMetadata: clientMetadata,
          startToken: startToken,
          transportMode: transportMode,
          localCredentialProvider: localCredentialProvider,
          localTransportEnabled: localTransportEnabled,
          localReconnectDelay: localReconnectDelay,
          cloudSocketFactory: cloudSocketFactory,
        );

    _mediaRelayClient = mediaRelayClient ??
        HostedMediaRelayClient(connection: _connectionController);

    _commandTransport = commandTransport ??
        SocketCommandTransport(
          hardwareId: hardwareId,
          connection: _connectionController,
        );

    _wireConnectionHandlers();
  }

  factory SanadSocketService.local({
    required String url,
    required String hardwareId,
    String? clientInstanceId,
    ClientDisplayMetadata? clientMetadata,
    LocalGatewayCredentialProvider credentialProvider = const LocalGatewayCredentialProvider(),
    bool enabled = true,
    Duration Function(int attempt)? reconnectDelay,
  }) {
    return SanadSocketService(
      url: url,
      hardwareId: hardwareId,
      clientInstanceId: clientInstanceId,
      clientMetadata: clientMetadata,
      transportMode: SocketTransportMode.localWebSocket,
      localCredentialProvider: credentialProvider,
      localTransportEnabled: enabled,
      localReconnectDelay: reconnectDelay,
    );
  }

  void _wireConnectionHandlers() {
    _connectionController.onRelayEvent = (event, data) {
      _mediaRelayClient.handleRelayEvent(event, data);
    };
    _connectionController.onCloudEvent = _handleCloudEvent;
    _connectionController.onLocalMessage = _handleLocalMessage;
  }

  socket_io.Socket? get socket => _connectionController.socket;

  @override
  bool get isConnected => _connectionController.isConnected;
  bool get isSocketConnected => _connectionController.isSocketConnected;
  bool get isReady => _connectionController.isReady;
  SocketLifecycleState get lifecycleState => _connectionController.lifecycleState;
  bool get isLocalTransport => _connectionController.isLocalTransport;

  @override
  Stream<Map<String, dynamic>> get onAuthSuccess => _connectionController.onAuthSuccess;
  Stream<Map<String, dynamic>> get onAuthFailure => _connectionController.onAuthFailure;
  Stream<bool> get connectionStatusStream => _connectionController.connectionStatusStream;
  Stream<SocketLifecycleState> get lifecycleStateStream => _connectionController.lifecycleStateStream;

  @override
  void setAccessToken(String? token) => _connectionController.setAccessToken(token);

  @override
  Future<void> connect() => _connectionController.connect();

  Future<void> reconnect() async {
    if (_isDisposed) return;
    disconnect();
    await connect();
  }

  @override
  void disconnect() => _connectionController.disconnect();

  @override
  void emit(String event, dynamic data) => _commandTransport.emit(event, data);

  @override
  void sendDeviceCommand({
    required String deviceId,
    required String command,
    Map<String, dynamic>? payload,
  }) => _commandTransport.sendDeviceCommand(
    deviceId: deviceId,
    command: command,
    payload: payload,
  );

  @override
  void sendToolResult({
    required String runId,
    String? output,
    String? error,
    bool isError = false,
    String? deviceId,
  }) => _commandTransport.sendToolResult(
    runId: runId,
    output: output,
    error: error,
    isError: isError,
    deviceId: deviceId,
  );

  Future<void> emitWithResponse(
    String event,
    Map<String, dynamic> data,
    void Function(Map<String, dynamic>) handler,
  ) => _commandTransport.emitWithResponse(event, data, handler);

  Future<List<String>> admitHostedAttachments({
    required String deviceId,
    required String sessionId,
    required String requestId,
    required List<Map<String, dynamic>> attachments,
  }) => _mediaRelayClient.admitHostedAttachments(
    deviceId: deviceId,
    sessionId: sessionId,
    requestId: requestId,
    attachments: attachments,
  );

  Future<HostedConversationMedia> fetchHostedConversationMedia({
    required String deviceId,
    required String sessionId,
    required String mediaId,
    required String purpose,
    void Function(void Function())? registerCancel,
  }) => _mediaRelayClient.fetchHostedConversationMedia(
    deviceId: deviceId,
    sessionId: sessionId,
    mediaId: mediaId,
    purpose: purpose,
    registerCancel: registerCancel,
  );

  void _handleCloudEvent(String event, dynamic data) {
    if (_isDisposed) return;

    switch (event) {
      case 'account_lifecycle_response':
        final payload = _asMap(data);
        if (payload != null) _accountLifecycleResponseController.add(payload);
        break;
      case 'account_lifecycle_revoke_result':
        final payload = _asMap(data);
        if (payload != null) _accountLifecycleRevokeController.add(payload);
        break;
      case 'account_lifecycle_delete_result':
        final payload = _asMap(data);
        if (payload != null) _accountLifecycleDeleteController.add(payload);
        break;
      case 'account_lifecycle_changed':
        _accountLifecycleChangedController.add(null);
        break;
      case 'capabilities':
        final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
        _safeAdd({'type': 'capabilities', ...payload});
        break;
      case 'device_event':
        _handleCloudDeviceEvent(data);
        break;
      case 'voice_audio_chunk_relay':
        if (data is Map) {
          final payload = Map<String, dynamic>.from(data);
          payload['type'] = 'voice_audio_chunk_relay';
          _safeAdd(payload);
        }
        break;
      case 'command_result':
        if (data is Map<String, dynamic>) {
          _eventRouter.routeEvent(data);
          _safeAdd(data);
        }
        break;
      case 'execute_tool':
        _handleExecuteTool(data);
        break;
    }
  }

  void _handleCloudDeviceEvent(dynamic data) {
    if (_isDisposed || data is! Map<String, dynamic>) return;

    // Phase 27 — drop cross-transport duplicates by canonical event_id.
    if (!_shouldProcessEvent(data, transport: 'cloud')) return;

    _connectionController.logIncomingSocketEvent('device_event', data);
    _eventRouter.routeEvent(data);
    final payload = data['payload'] ?? {};
    if (payload is Map<String, dynamic>) {
      _safeAdd(data);
    } else {
      _logger.warning('⚠️ Received invalid device event payload shape');
    }
  }

  void _handleLocalMessage(Map<String, dynamic> payload) {
    if (_isDisposed) return;

    final type = payload['type'] as String?;
    switch (type) {
      case 'capabilities':
        _safeAdd(payload);
        return;
      case 'device_event':
        // Phase 27 — drop cross-transport duplicates by canonical event_id.
        if (!_shouldProcessEvent(payload, transport: 'local')) return;
        _connectionController.logIncomingSocketEvent('device_event', payload);
        _eventRouter.routeEvent(payload);
        _safeAdd(payload);
        return;
      case 'execute_tool':
        _handleExecuteTool(payload);
        return;
      default:
        _safeAdd(payload);
    }
  }

  void _handleExecuteTool(dynamic data) {
    if (data is! Map<String, dynamic>) {
      _logger.warning('⚠️ Invalid execute_tool data type');
      return;
    }

    final agentDeviceId = data['hardware_id'] as String?;
    if (agentDeviceId != null && agentDeviceId != _hardwareId) {
      _logger.warning(
        '⚠️ Ignoring execute_tool for different device: $agentDeviceId (Local: $_hardwareId)',
      );
      return;
    }

    final deviceId = data['device_id'] as String?;

    if (!AppPlatform.isDesktop) {
      _logger.warning(
        '⚠️ Ignoring execute_tool on non-desktop platform: ${AppPlatform.name}',
      );
      _commandTransport.sendToolResult(
        runId: data['run_id'] ?? '',
        error: 'Tool execution not supported on ${AppPlatform.name}',
        isError: true,
        deviceId: deviceId,
      );
      return;
    }

    _remoteToolExecutionController.add(data);
  }

  bool _shouldProcessEvent(
    Map<String, dynamic> event, {
    required String transport,
  }) {
    final dedup = eventDeduplicator;
    if (dedup == null) return true;
    final eventId = event['event_id'] as String?;
    if (!dedup.shouldProcess(eventId, transport: transport, payload: event)) {
      _logger.fine(
        'Dropping duplicate device_event on $transport transport.',
      );
      return false;
    }
    return true;
  }

  void _safeAdd(Map<String, dynamic> event) {
    if (!_isDisposed && !_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  void dispose() {
    _isDisposed = true;
    _connectionController.dispose();
    _mediaRelayClient.dispose();
    unawaited(_remoteToolExecutionController.close());
    unawaited(_eventsController.close());
    unawaited(_accountLifecycleResponseController.close());
    unawaited(_accountLifecycleRevokeController.close());
    unawaited(_accountLifecycleDeleteController.close());
    unawaited(_accountLifecycleChangedController.close());
    _eventRouter.dispose();
  }

  @visibleForTesting
  void debugSetSocketConnected(bool value) => _connectionController.debugSetSocketConnected(value);

  @visibleForTesting
  void debugSetLifecycleState(SocketLifecycleState value) => _connectionController.debugSetLifecycleState(value);

  @visibleForTesting
  void debugEmitAuthFailure(Map<String, dynamic> payload) => _connectionController.debugEmitAuthFailure(payload);

  @visibleForTesting
  void debugHandleAuthRevoked(dynamic payload) => _connectionController.debugHandleAuthRevoked(payload);

  @visibleForTesting
  void debugEmitEvent(Map<String, dynamic> payload, {bool route = false}) {
    if (route) {
      _eventRouter.routeEvent(payload);
    }
    _safeAdd(payload);
  }

  /// Phase 27 — test-only hook that simulates an inbound `device_event`
  /// through the real cross-transport dedup path. Used by tests to verify
  /// that the same `event_id` delivered over two transports is applied once.
  void debugEmitDeviceEvent(
    Map<String, dynamic> payload, {
    String transport = 'local',
  }) {
    if (_isDisposed) return;
    if (!_shouldProcessEvent(payload, transport: transport)) return;
    _eventRouter.routeEvent(payload);
    _safeAdd(payload);
  }

  @visibleForTesting
  void debugLogIncomingSocketEvent(String event, dynamic data) =>
      _connectionController.debugLogIncomingSocketEvent(event, data);

  @visibleForTesting
  String debugFormatData(dynamic data, {int maxLength = 500}) =>
      _connectionController.debugFormatData(data, maxLength: maxLength);

  static Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return null;
  }
}
