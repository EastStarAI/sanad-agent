import 'package:logging/logging.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_client/core/interfaces/socket_gateway.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';
import 'package:sanad_client/core/interfaces/socket_service.dart';
import 'package:sanad_client/infrastructure/socket/event_deduplicator.dart';
import 'package:sanad_client/infrastructure/socket/event_router.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_uri_policy.dart';

enum SocketLifecycleState {
  disconnected,
  connecting,
  authenticating,
  ready,
  authFailed,
  error,
}

enum SocketTransportMode { cloudSocketIo, localWebSocket }

class SanadSocketService implements ISocketService, ISocketGateway {
  static final _logger = Logger('SanadSocket');

  socket_io.Socket? _socket;
  WebSocket? _localSocket;
  final String _url;
  final String _hardwareId;
  final String? _clientInstanceId;
  final ClientDisplayMetadata? _clientMetadata;
  String get hardwareId => _hardwareId;
  String? _authToken;
  final SocketTransportMode _transportMode;
  final LocalGatewayCredentialProvider? _localCredentialProvider;
  final bool _localTransportEnabled;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _explicitDisconnect = false;

  final _authSuccessController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get onAuthSuccess => _authSuccessController.stream;

  final _authFailureController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onAuthFailure => _authFailureController.stream;

  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  final EventRouter _eventRouter = EventRouter();
  EventRouter get eventRouter => _eventRouter;

  /// Phase 27 — shared cross-transport event deduplicator. When set, the
  /// service consults it for every incoming `device_event` (cloud and local)
  /// and drops duplicates by `event_id` before routing or broadcasting.
  /// The `DeviceConnectionCoordinator` injects one shared instance across
  /// both transports so a same-device client never applies the same event
  /// twice during a transport switch or cloud fan-out.
  EventDeduplicator? eventDeduplicator;

  socket_io.Socket? get socket => _socket;

  bool _isSocketConnected = false;
  SocketLifecycleState _lifecycleState = SocketLifecycleState.disconnected;

  @override
  bool get isConnected => isReady;
  bool get isSocketConnected => _isSocketConnected;
  bool get isReady => _lifecycleState == SocketLifecycleState.ready;
  SocketLifecycleState get lifecycleState => _lifecycleState;

  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;

  final _lifecycleStateController = StreamController<SocketLifecycleState>.broadcast();
  Stream<SocketLifecycleState> get lifecycleStateStream => _lifecycleStateController.stream;

  bool _isDisposed = false;
  Future<void>? _connectFuture;
  Completer<void>? _readyCompleter;
  String? _lastIncomingEventName;
  String? _localPresenceAssertion;
  final Map<String, Completer<String?>> _presenceAssertionRequests = {};

  SanadSocketService({
    required String url,
    required String hardwareId,
    String? clientInstanceId,
    ClientDisplayMetadata? clientMetadata,
    String? startToken,
    SocketTransportMode transportMode = SocketTransportMode.cloudSocketIo,
    LocalGatewayCredentialProvider? localCredentialProvider,
    bool localTransportEnabled = true,
  }) : _url = url,
       _hardwareId = hardwareId,
       _clientInstanceId = clientInstanceId,
       _clientMetadata = clientMetadata,
       _authToken = startToken,
       _transportMode = transportMode,
       _localCredentialProvider =
           localCredentialProvider ??
           (transportMode == SocketTransportMode.localWebSocket ? const LocalGatewayCredentialProvider() : null),
       _localTransportEnabled = localTransportEnabled;

  factory SanadSocketService.local({
    required String url,
    required String hardwareId,
    String? clientInstanceId,
    ClientDisplayMetadata? clientMetadata,
    LocalGatewayCredentialProvider credentialProvider = const LocalGatewayCredentialProvider(),
    bool enabled = true,
  }) {
    return SanadSocketService(
      url: url,
      hardwareId: hardwareId,
      clientInstanceId: clientInstanceId,
      clientMetadata: clientMetadata,
      transportMode: SocketTransportMode.localWebSocket,
      localCredentialProvider: credentialProvider,
      localTransportEnabled: enabled,
    );
  }

  bool get isLocalTransport => _transportMode == SocketTransportMode.localWebSocket;

  @override
  void setAccessToken(String? token) {
    if (isLocalTransport) {
      return;
    }

    if (_authToken == token) return;

    _authToken = token;
    if (token == null && _socket != null) {
      disconnect();
    }
  }

  @override
  Future<void> connect() async {
    _explicitDisconnect = false;
    if (isReady) return;

    if (_connectFuture != null) {
      _logger.info(
        '[${hashCode}]: ⏳ Connection already in progress, waiting...',
      );
      return _connectFuture!;
    }

    _connectFuture = _connectInternal();
    try {
      await _connectFuture!;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connectInternal() async {
    _lastIncomingEventName = null;
    if (!isLocalTransport && _authToken == null) {
      _logger.warning('[${hashCode}]: ⚠️ No auth token provided. Waiting...');
      _setLifecycleState(SocketLifecycleState.disconnected);
      return;
    }
    if (isLocalTransport && !_localTransportEnabled) {
      _setLifecycleState(SocketLifecycleState.disconnected);
      return;
    }

    _readyCompleter = Completer<void>();
    _setLifecycleState(SocketLifecycleState.connecting);

    if (isLocalTransport) {
      await _connectLocalWebSocket();
    } else {
      await _connectCloudSocketIo();
    }

    try {
      await _readyCompleter!.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _logger.severe('[${hashCode}]: Connection timeout or error: $e');
      if (_lifecycleState != SocketLifecycleState.ready) {
        _setLifecycleState(SocketLifecycleState.error);
      }
      rethrow;
    } finally {
      _readyCompleter = null;
    }
  }

  Future<void> _connectCloudSocketIo() async {
    if (_socket != null) {
      _logger.info('[${hashCode}]: 🧹 Disposing stale socket before reconnect');
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
    }

    _logger.info('[${hashCode}]: Connecting to $_url');
    _socket = socket_io.io(
      _url,
      socket_io.OptionBuilder().setTransports(['websocket']).enableForceNew().disableAutoConnect().setExtraHeaders({
        'Authorization': 'Bearer $_authToken',
      }).build(),
    );

    _socket!.onAny((event, data) {
      if (_isDisposed) return;
      // device_event is logged by its handler only after cross-transport
      // deduplication accepts it.
      if (event == 'device_event') return;
      _logIncomingSocketEvent(event, data);
    });

    _socket!.onConnect((_) {
      _logger.info('[${hashCode}]: Connected');
      _setSocketConnected(true);
      _setLifecycleState(SocketLifecycleState.authenticating);

      final authData = {
        'token': _authToken,
        'hardware_id': _hardwareId,
        'platform': AppPlatform.name,
        if (_clientInstanceId != null) 'client_instance_id': _clientInstanceId,
        if (_clientMetadata != null) 'metadata': _clientMetadata.toJson(),
        if (_clientInstanceId != null)
          'capabilities': const [
            'account_sessions_v1',
            'delivery_presence_v1',
          ],
      };
      _logOutgoingSocketEvent('app_authenticate', authData);
      _socket?.emit('app_authenticate', authData);
    });

    _socket!.onDisconnect((_) {
      _logger.info('[${hashCode}]: Disconnected');
      _setSocketConnected(false);
      if (_lifecycleState != SocketLifecycleState.authFailed && _lifecycleState != SocketLifecycleState.error) {
        _setLifecycleState(SocketLifecycleState.disconnected);
      }
    });

    _socket!.on('auth_success', (data) {
      final payload = data is Map<String, dynamic> ? data : <String, dynamic>{};
      _authSuccessController.add(payload);
      _setLifecycleState(SocketLifecycleState.ready);
      _completeReady();
    });

    _socket!.on('auth_error', (data) {
      final payload = data is Map<String, dynamic> ? data : <String, dynamic>{};
      _authFailureController.add(payload);
      _setLifecycleState(SocketLifecycleState.authFailed);
      _completeReadyError(
        StateError(
          payload['message']?.toString() ?? 'Socket authentication failed',
        ),
      );
    });

    _socket!.on('error', (data) {
      _setLifecycleState(SocketLifecycleState.error);
      _completeReadyError(StateError(data?.toString() ?? 'Socket error'));
    });

    _socket!.on('capabilities', (data) {
      if (_isDisposed) return;
      final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      _safeAdd({'type': 'capabilities', ...payload});
    });

    _socket!.on('device_event', _handleCloudDeviceEvent);

    _socket!.on('local_presence_assertion', (data) {
      final payload = _asMap(data);
      final deviceId = payload?['device_id']?.toString();
      final assertion = payload?['presence_assertion']?.toString();
      final completer = deviceId == null ? null : _presenceAssertionRequests.remove(deviceId);
      if (assertion != null && assertion.isNotEmpty) {
        completer?.complete(assertion);
      } else {
        completer?.complete(null);
      }
    });
    _socket!.on('local_presence_assertion_error', (data) {
      final payload = _asMap(data);
      final deviceId = payload?['device_id']?.toString();
      if (deviceId != null) {
        _presenceAssertionRequests.remove(deviceId)?.complete(null);
      } else {
        for (final completer in _presenceAssertionRequests.values) {
          if (!completer.isCompleted) completer.complete(null);
        }
        _presenceAssertionRequests.clear();
      }
    });

    _socket!.on('voice_audio_chunk_relay', (data) {
      if (_isDisposed) return;
      if (data is Map) {
        final payload = Map<String, dynamic>.from(data);
        payload['type'] = 'voice_audio_chunk_relay';
        _safeAdd(payload);
      }
    });

    _socket!.on('command_result', (data) {
      if (_isDisposed) return;
      if (data is Map<String, dynamic>) {
        _eventRouter.routeEvent(data);
        _safeAdd(data);
      }
    });

    _socket!.on('execute_tool', (data) {
      if (_isDisposed) return;
      _handleExecuteTool(data);
    });

    _socket!.connect();
  }

  void _handleCloudDeviceEvent(dynamic data) {
    if (_isDisposed || data is! Map<String, dynamic>) return;

    // Phase 27 — drop cross-transport duplicates by canonical event_id.
    if (!_shouldProcessEvent(data, transport: 'cloud')) return;

    _logIncomingSocketEvent('device_event', data);
    _eventRouter.routeEvent(data);
    final payload = data['payload'] ?? {};
    if (payload is Map<String, dynamic>) {
      _safeAdd(data);
    } else {
      _logger.warning('⚠️ Received non-map payload: $data');
    }
  }

  Future<String?> requestLocalPresenceAssertion(String deviceId) async {
    if (isLocalTransport || !isReady || deviceId.isEmpty) return null;
    final existing = _presenceAssertionRequests[deviceId];
    if (existing != null) return existing.future;
    final completer = Completer<String?>();
    _presenceAssertionRequests[deviceId] = completer;
    _socket?.emit('request_local_presence_assertion', {'device_id': deviceId});
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      return null;
    } finally {
      _presenceAssertionRequests.remove(deviceId);
    }
  }

  void setLocalPresenceAssertion(String? assertion) {
    if (!isLocalTransport) return;
    _localPresenceAssertion = assertion;
  }

  Future<void> refreshLocalHello() async {
    if (!isLocalTransport || !isReady || _localSocket == null) return;
    _sendLocalHello();
  }

  void _sendLocalHello() {
    if (_localSocket == null || _clientInstanceId == null) return;
    _localSocket!.add(
      jsonEncode({
        'type': 'client.hello',
        'protocol': 'sanad.identity_presence',
        'version': 1,
        'client_instance_id': _clientInstanceId,
        if (_clientMetadata != null) 'metadata': _clientMetadata.toJson(),
        'capabilities': const [
          'account_sessions_v1',
          'delivery_presence_v1',
        ],
        if (_localPresenceAssertion != null) 'local_presence_assertion': _localPresenceAssertion,
      }),
    );
  }

  Future<void> _connectLocalWebSocket() async {
    if (_localSocket != null) {
      await _localSocket!.close();
      _localSocket = null;
    }

    final wsUri = LocalGatewayUriPolicy.requireWebSocket(
      _toLocalWebSocketUri(_url),
    );
    _logger.info('[${hashCode}]: Connecting locally to $wsUri');
    try {
      final headers = await _localCredentialProvider!.headers();
      _localSocket = await WebSocket.connect(
        wsUri.toString(),
        headers: headers,
      );
      _setSocketConnected(true);
      _sendLocalHello();

      _localSocket!.listen(
        _handleLocalMessage,
        onDone: () {
          _logger.info('[${hashCode}]: Local socket disconnected');
          _setSocketConnected(false);
          if (_lifecycleState != SocketLifecycleState.error) {
            _setLifecycleState(SocketLifecycleState.disconnected);
          }
          _handleLocalReconnect();
        },
        onError: (Object error) {
          _logger.severe('[${hashCode}]: Local socket error: $error');
          _setSocketConnected(false);
          _setLifecycleState(SocketLifecycleState.error);
          _completeReadyError(StateError(error.toString()));
          _handleLocalReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _logger.severe(
        '[${hashCode}]: Local socket connection failed to establish: $e',
      );
      _setSocketConnected(false);
      _setLifecycleState(SocketLifecycleState.error);
      _handleLocalReconnect();
      rethrow;
    }
  }

  Uri _toLocalWebSocketUri(String rawUrl) {
    final base = Uri.parse(rawUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final path = base.path.isEmpty || base.path == '/' ? '/ws' : base.path;
    return base.replace(scheme: scheme, path: path);
  }

  void _handleLocalMessage(dynamic data) {
    if (_isDisposed) return;

    final payload = _asMap(_decodeMessage(data));
    if (payload == null) {
      return;
    }

    final type = payload['type'] as String?;
    if (type != 'device_event') {
      _logIncomingSocketEvent(type ?? 'local_message', payload);
    }

    switch (type) {
      case 'register_success':
        _authSuccessController.add(payload);
        _setLifecycleState(SocketLifecycleState.ready);
        _completeReady();
        _reconnectAttempts = 0;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        return;
      case 'capabilities':
        _safeAdd(payload);
        return;
      case 'device_event':
        // Phase 27 — drop cross-transport duplicates by canonical event_id.
        if (!_shouldProcessEvent(payload, transport: 'local')) return;
        _logIncomingSocketEvent('device_event', payload);
        _eventRouter.routeEvent(payload);
        _safeAdd(payload);
        return;
      case 'execute_tool':
        _handleExecuteTool(payload);
        return;
      case 'error':
        _setLifecycleState(SocketLifecycleState.error);
        _completeReadyError(
          StateError(payload['message']?.toString() ?? 'Local socket error'),
        );
        return;
      default:
        _safeAdd(payload);
    }
  }

  /// Phase 27 — consults the shared cross-transport deduplicator. Returns
  /// `false` when the event's `event_id` has already been processed by the
  /// other transport, so the caller drops it before routing or broadcasting.
  bool _shouldProcessEvent(
    Map<String, dynamic> event, {
    required String transport,
  }) {
    final dedup = eventDeduplicator;
    if (dedup == null) return true;
    final eventId = event['event_id'] as String?;
    if (!dedup.shouldProcess(eventId, transport: transport)) {
      _logger.fine(
        'Dropping duplicate device_event on $transport transport.',
      );
      return false;
    }
    return true;
  }

  dynamic _decodeMessage(dynamic data) {
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    if (data is List<int>) {
      return _decodeMessage(utf8.decode(data));
    }
    return data;
  }

  Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return null;
  }

  final _remoteToolExecutionController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get remoteToolExecutionStream => _remoteToolExecutionController.stream;

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
      _sendToolResult(
        runId: data['run_id'] ?? '',
        error: 'Tool execution not supported on ${AppPlatform.name}',
        isError: true,
        deviceId: deviceId,
      );
      return;
    }

    _remoteToolExecutionController.add(data);
  }

  void _safeAdd(Map<String, dynamic> event) {
    if (!_isDisposed && !_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  @override
  void sendDeviceCommand({
    required String deviceId,
    required String command,
    Map<String, dynamic>? payload,
  }) {
    if (!isConnected) {
      _logger.severe(
        '[${hashCode}]: ❌ Cannot send command, socket is not ready.',
      );
      return;
    }

    final data = {
      'device_id': deviceId,
      'hardware_id': _hardwareId,
      'command': command,
      if (payload != null) 'payload': payload,
    };

    _logOutgoingSocketEvent('device_command', data);

    try {
      if (isLocalTransport) {
        _localSocket?.add(jsonEncode({'type': 'execute_command', ...data}));
      } else {
        _socket!.emit('device_command', data);
      }
    } catch (e) {
      _logger.severe('[${hashCode}]: ❌ Error emitting device_command: $e');
    }
  }

  @override
  void emit(String event, dynamic data) {
    if (!isConnected) {
      _logger.severe(
        '[${hashCode}]: ❌ Cannot emit $event, socket is not ready',
      );
      return;
    }
    _logOutgoingSocketEvent(event, data);
    if (isLocalTransport) {
      final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{'payload': data};
      _localSocket?.add(jsonEncode({'type': event, ...payload}));
      return;
    }
    _socket!.emit(event, data);
  }

  Future<void> reconnect() async {
    if (_isDisposed) return;
    disconnect();
    await connect();
  }

  @override
  void disconnect() {
    _explicitDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    _socket?.disconnect();
    _socket?.dispose();
    unawaited(_localSocket?.close());
    _localSocket = null;
    _socket = null;
    _setSocketConnected(false);
    _setLifecycleState(SocketLifecycleState.disconnected);
  }

  @override
  void sendToolResult({
    required String runId,
    String? output,
    String? error,
    bool isError = false,
    String? deviceId,
  }) {
    _sendToolResult(
      runId: runId,
      output: output,
      error: error,
      isError: isError,
      deviceId: deviceId,
    );
  }

  void _sendToolResult({
    required String runId,
    String? output,
    String? error,
    bool isError = false,
    String? deviceId,
  }) {
    if (!isConnected) {
      _logger.severe(
        '[${hashCode}]: ❌ Cannot send tool result, socket is not ready',
      );
      return;
    }

    final payload = {
      'run_id': runId,
      'status': isError ? 'error' : 'success',
      'output': isError ? (error ?? output ?? 'Tool execution failed') : (output ?? ''),
      'isError': isError,
      'hardware_id': _hardwareId,
    };

    final commandData = {
      'device_id': deviceId ?? '',
      'hardware_id': _hardwareId,
      'command': 'tool_result',
      'payload': payload,
    };

    _logOutgoingSocketEvent('device_command', commandData);

    try {
      if (isLocalTransport) {
        _localSocket?.add(
          jsonEncode({'type': 'execute_command', ...commandData}),
        );
      } else {
        _socket!.emit('device_command', commandData);
      }
    } catch (e) {
      _logger.severe('[${hashCode}]: ❌ Error sending tool_result: $e');
    }
  }

  Future<void> emitWithResponse(
    String event,
    Map<String, dynamic> data,
    void Function(Map<String, dynamic>) handler,
  ) async {
    if (_socket == null || !_socket!.connected || !isReady || isLocalTransport) {
      return;
    }

    final completer = Completer<void>();
    final responseEvent = '${event}_response';

    void cleanup() {
      _socket?.off(responseEvent);
    }

    _socket?.on(responseEvent, (response) {
      handler(Map<String, dynamic>.from(response));
      cleanup();
      completer.complete();
    });

    _logOutgoingSocketEvent(event, data);
    _socket?.emit(event, data);

    try {
      await completer.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      cleanup();
    }
  }

  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _socket?.dispose();
    unawaited(_localSocket?.close());
    unawaited(_remoteToolExecutionController.close());
    unawaited(_connectionStatusController.close());
    unawaited(_lifecycleStateController.close());
    unawaited(_eventsController.close());
    _eventRouter.dispose();
    unawaited(_authSuccessController.close());
    unawaited(_authFailureController.close());
  }

  void _setSocketConnected(bool value) {
    _isSocketConnected = value;
    if (!_isDisposed && !_connectionStatusController.isClosed) {
      _connectionStatusController.add(isConnected);
    }
  }

  void _setLifecycleState(SocketLifecycleState value) {
    _lifecycleState = value;
    if (!_isDisposed && !_lifecycleStateController.isClosed) {
      _lifecycleStateController.add(value);
    }
    if (!_isDisposed && !_connectionStatusController.isClosed) {
      _connectionStatusController.add(isConnected);
    }
  }

  void _completeReady() {
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _completeReadyError(Object error) {
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  void _handleLocalReconnect() {
    if (_isDisposed || _explicitDisconnect || !isLocalTransport) {
      return;
    }

    if (_reconnectTimer?.isActive ?? false) {
      return;
    }

    _reconnectAttempts++;
    final delaySeconds = (_reconnectAttempts * 2).clamp(2, 10);
    _logger.info(
      '[${hashCode}]: Scheduling local WebSocket reconnect attempt #$_reconnectAttempts in ${delaySeconds}s...',
    );

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      if (_isDisposed || _explicitDisconnect) return;
      _logger.info(
        '[${hashCode}]: Executing local WebSocket reconnect attempt #$_reconnectAttempts',
      );
      try {
        await connect();
      } catch (e) {
        _logger.severe(
          '[${hashCode}]: Reconnect attempt #$_reconnectAttempts failed: $e',
        );
      }
    });
  }

  @visibleForTesting
  void debugSetSocketConnected(bool value) {
    _setSocketConnected(value);
  }

  @visibleForTesting
  void debugSetLifecycleState(SocketLifecycleState value) {
    _setLifecycleState(value);
  }

  @visibleForTesting
  void debugEmitAuthFailure(Map<String, dynamic> payload) {
    _authFailureController.add(payload);
    _setLifecycleState(SocketLifecycleState.authFailed);
  }

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
  void debugLogIncomingSocketEvent(String event, dynamic data) {
    _logIncomingSocketEvent(event, data);
  }

  @visibleForTesting
  String debugFormatData(dynamic data, {int maxLength = 500}) {
    return _formatDebugData(data, maxLength: maxLength);
  }

  void _logIncomingSocketEvent(String event, dynamic data) {
    if (!kDebugMode) return;

    try {
      String logMessage = '⬇️ event "\x1B[35m$event\x1B[0m"';
      String currentEventName = event;

      if (event == 'device_event' && data is Map<String, dynamic>) {
        final eventName = data['event'] ?? 'unknown';
        logMessage = '⬇️ [event \x1B[35m$eventName\x1B[0m] >';
        currentEventName = eventName.toString();
      }

      if (currentEventName == 'thought_stream' || currentEventName == 'reasoning_stream') {
        if (_lastIncomingEventName == currentEventName) {
          return;
        }
      }
      _lastIncomingEventName = currentEventName;

      final debugData = _formatDebugData(data);
      _logger.info('$logMessage: $debugData');
    } catch (e) {
      _logger.severe('Logging Error (Incoming): $e');
    }
  }

  void _logOutgoingSocketEvent(String event, dynamic data) {
    if (!kDebugMode) return;

    try {
      String logMessage = '⬆️ event "\x1B[32m$event\x1B[0m"';

      if (event == 'device_command' && data is Map<String, dynamic>) {
        final command = data['command'] ?? 'unknown';
        logMessage = '⬆️ [command \x1B[32m$command\x1B[0m] >';
      }

      final debugData = _formatDebugData(data);
      _logger.info('$logMessage: $debugData');
    } catch (e) {
      _logger.severe('Logging Error (Outgoing): $e');
    }
  }

  String _formatDebugData(dynamic data, {int maxLength = 500}) {
    if (!kDebugMode) return '';

    try {
      String debugData;
      try {
        debugData = jsonEncode(_redactSensitiveLogData(data));
      } catch (_) {
        debugData = '[unserializable payload]';
      }

      if (debugData.length > maxLength) {
        return '${debugData.substring(0, maxLength)}...';
      }
      return debugData;
    } catch (e) {
      return 'Format error: $e';
    }
  }

  dynamic _redactSensitiveLogData(dynamic data) {
    if (data is Map) {
      return <String, dynamic>{
        for (final entry in data.entries)
          entry.key.toString(): _isSensitiveLogKey(entry.key) ? '[REDACTED]' : _redactSensitiveLogData(entry.value),
      };
    }

    if (data is Iterable) {
      return data.map(_redactSensitiveLogData).toList(growable: false);
    }

    return data;
  }

  bool _isSensitiveLogKey(Object? key) {
    final normalized = key
        .toString()
        .trim()
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match[1]}_${match[2]}',
        )
        .toLowerCase()
        .replaceAll('-', '_');
    return normalized == 'token' ||
        normalized == 'authorization' ||
        normalized == 'cookie' ||
        normalized == 'set_cookie' ||
        normalized == 'password' ||
        normalized == 'credential' ||
        normalized == 'credentials' ||
        normalized == 'secret' ||
        normalized == 'api_key' ||
        normalized == 'client_instance_id' ||
        normalized == 'event_id' ||
        normalized == 'email' ||
        normalized == 'hostname' ||
        normalized == 'content' ||
        normalized == 'payload' ||
        normalized == 'origin_client' ||
        normalized == 'local_presence_assertion' ||
        normalized == 'presence_assertion' ||
        normalized.endsWith('_token') ||
        normalized.endsWith('_secret') ||
        normalized.endsWith('_password') ||
        normalized.endsWith('_api_key') ||
        normalized.endsWith('_proof') ||
        normalized.endsWith('_thumbprint');
  }
}
