import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_uri_policy.dart';
import 'package:sanad_client/utils/app_platform.dart';

enum SocketLifecycleState {
  disconnected,
  connecting,
  authenticating,
  ready,
  authFailed,
  error,
}

enum SocketTransportMode { cloudSocketIo, localWebSocket }

typedef CloudSocketFactory =
    socket_io.Socket Function(
      String url,
      Map<String, dynamic> options,
    );

typedef RelayEventHandler = void Function(String event, dynamic data);
typedef CloudEventHandler = void Function(String event, dynamic data);
typedef LocalMessageHandler = void Function(Map<String, dynamic> payload);

/// Owns connection lifecycle, transport mode selection (cloud socket vs local
/// WebSocket), access token management, reconnect/backoff, and debug hooks.
class SocketConnectionController {
  static final _logger = Logger('SanadSocket');

  socket_io.Socket? _socket;
  WebSocket? _localSocket;
  final String _url;
  final String _hardwareId;
  final String? _clientInstanceId;
  final ClientDisplayMetadata? _clientMetadata;
  String? _authToken;
  final SocketTransportMode _transportMode;
  final LocalGatewayCredentialProvider? _localCredentialProvider;
  final bool _localTransportEnabled;
  final Duration Function(int attempt) _localReconnectDelay;
  final CloudSocketFactory _cloudSocketFactory;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _explicitDisconnect = false;

  final _authSuccessController = StreamController<Map<String, dynamic>>.broadcast();
  final _authFailureController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStatusController = StreamController<bool>.broadcast();
  final _lifecycleStateController = StreamController<SocketLifecycleState>.broadcast();

  bool _isSocketConnected = false;
  SocketLifecycleState _lifecycleState = SocketLifecycleState.disconnected;
  bool _isDisposed = false;
  Future<void>? _connectFuture;
  Completer<void>? _readyCompleter;
  String? _lastIncomingEventName;

  RelayEventHandler? onRelayEvent;
  CloudEventHandler? onCloudEvent;
  LocalMessageHandler? onLocalMessage;

  SocketConnectionController({
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
    this.onRelayEvent,
    this.onCloudEvent,
    this.onLocalMessage,
  }) : _url = url,
       _hardwareId = hardwareId,
       _clientInstanceId = clientInstanceId,
       _clientMetadata = clientMetadata,
       _authToken = startToken,
       _transportMode = transportMode,
       _localCredentialProvider =
           localCredentialProvider ??
           (transportMode == SocketTransportMode.localWebSocket ? const LocalGatewayCredentialProvider() : null),
       _localTransportEnabled = localTransportEnabled,
       _localReconnectDelay = localReconnectDelay ?? _defaultLocalReconnectDelay,
       _cloudSocketFactory = cloudSocketFactory;

  factory SocketConnectionController.local({
    required String url,
    required String hardwareId,
    String? clientInstanceId,
    ClientDisplayMetadata? clientMetadata,
    LocalGatewayCredentialProvider credentialProvider = const LocalGatewayCredentialProvider(),
    bool enabled = true,
    Duration Function(int attempt)? reconnectDelay,
    RelayEventHandler? onRelayEvent,
    CloudEventHandler? onCloudEvent,
    LocalMessageHandler? onLocalMessage,
  }) {
    return SocketConnectionController(
      url: url,
      hardwareId: hardwareId,
      clientInstanceId: clientInstanceId,
      clientMetadata: clientMetadata,
      transportMode: SocketTransportMode.localWebSocket,
      localCredentialProvider: credentialProvider,
      localTransportEnabled: enabled,
      localReconnectDelay: reconnectDelay,
      onRelayEvent: onRelayEvent,
      onCloudEvent: onCloudEvent,
      onLocalMessage: onLocalMessage,
    );
  }

  static Duration _defaultLocalReconnectDelay(int attempt) {
    return Duration(seconds: (attempt * 2).clamp(2, 10));
  }

  socket_io.Socket? get socket => _socket;
  WebSocket? get localSocket => _localSocket;

  String get url => _url;
  String get hardwareId => _hardwareId;
  String? get clientInstanceId => _clientInstanceId;
  ClientDisplayMetadata? get clientMetadata => _clientMetadata;
  String? get authToken => _authToken;
  SocketTransportMode get transportMode => _transportMode;
  bool get isLocalTransport => _transportMode == SocketTransportMode.localWebSocket;
  bool get localTransportEnabled => _localTransportEnabled;
  Duration Function(int attempt) get localReconnectDelay => _localReconnectDelay;
  int get reconnectAttempts => _reconnectAttempts;
  Timer? get reconnectTimer => _reconnectTimer;
  bool get explicitDisconnect => _explicitDisconnect;
  bool get isDisposed => _isDisposed;

  bool get isConnected => isReady;
  bool get isSocketConnected => _isSocketConnected;
  bool get isReady => _lifecycleState == SocketLifecycleState.ready;
  SocketLifecycleState get lifecycleState => _lifecycleState;

  Stream<Map<String, dynamic>> get onAuthSuccess => _authSuccessController.stream;
  Stream<Map<String, dynamic>> get onAuthFailure => _authFailureController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  Stream<SocketLifecycleState> get lifecycleStateStream => _lifecycleStateController.stream;

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
    } catch (_) {
      _logger.severe('[${hashCode}]: Connection timeout or error');
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

    _logger.info('[${hashCode}]: Connecting to cloud gateway');
    _socket = _cloudSocketFactory(
      _url,
      socket_io.OptionBuilder().setTransports(['websocket']).enableForceNew().disableAutoConnect().setExtraHeaders({
        'Authorization': 'Bearer $_authToken',
      }).build(),
    );

    _socket!.onAny((event, data) {
      if (_isDisposed) return;
      // device_event is logged by its handler only after cross-transport
      // deduplication accepts it.
      if (event == 'device_event' ||
          event.startsWith('attachment_upload_') ||
          event.startsWith('conversation_media_')) {
        return;
      }
      _logIncomingSocketEvent(event, data);
    });

    void relayAttachmentEvent(String event, dynamic data) {
      if (!_isDisposed) {
        onRelayEvent?.call(event, data);
      }
    }

    _socket!.on(
      'attachment_upload_ack',
      (data) => relayAttachmentEvent('attachment_upload_ack', data),
    );
    _socket!.on(
      'attachment_upload_error',
      (data) => relayAttachmentEvent('attachment_upload_error', data),
    );
    for (final event in const [
      'conversation_media_start',
      'conversation_media_chunk',
      'conversation_media_complete',
      'conversation_media_error',
    ]) {
      _socket!.on(event, (data) => relayAttachmentEvent(event, data));
    }

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

    _socket!.on('auth_revoked', _handleAuthRevoked);

    for (final event in const [
      'account_lifecycle_response',
      'account_lifecycle_revoke_result',
      'account_lifecycle_delete_result',
      'account_lifecycle_changed',
      'capabilities',
      'device_event',
      'voice_audio_chunk_relay',
      'command_result',
      'execute_tool',
    ]) {
      _socket!.on(event, (data) {
        if (!_isDisposed) {
          onCloudEvent?.call(event, data);
        }
      });
    }

    _socket!.on('error', (data) {
      _setLifecycleState(SocketLifecycleState.error);
      _completeReadyError(StateError(data?.toString() ?? 'Socket error'));
    });

    _socket!.connect();
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
    _logger.info('[${hashCode}]: Connecting to local Agent');
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
          _logger.severe('[${hashCode}]: Local socket error');
          _setSocketConnected(false);
          _setLifecycleState(SocketLifecycleState.error);
          _completeReadyError(StateError(error.toString()));
          _handleLocalReconnect();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _logger.severe(
        '[${hashCode}]: Local socket connection failed to establish',
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
      case 'error':
        _setLifecycleState(SocketLifecycleState.error);
        _completeReadyError(
          StateError(payload['message']?.toString() ?? 'Local socket error'),
        );
        return;
      default:
        onLocalMessage?.call(payload);
    }
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

  Future<void> reconnect() async {
    if (_isDisposed) return;
    disconnect();
    await connect();
  }

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

  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _socket?.dispose();
    unawaited(_localSocket?.close());
    unawaited(_connectionStatusController.close());
    unawaited(_lifecycleStateController.close());
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
    final delay = _localReconnectDelay(_reconnectAttempts);
    _logger.info(
      '[${hashCode}]: Scheduling local WebSocket reconnect attempt #$_reconnectAttempts in ${delay.inMilliseconds}ms...',
    );

    _reconnectTimer = Timer(delay, () async {
      if (_isDisposed || _explicitDisconnect) return;
      _logger.info(
        '[${hashCode}]: Executing local WebSocket reconnect attempt #$_reconnectAttempts',
      );
      try {
        await connect();
      } catch (_) {
        _logger.severe(
          '[${hashCode}]: Reconnect attempt #$_reconnectAttempts failed',
        );
      }
    });
  }

  void debugSetSocketConnected(bool value) {
    _setSocketConnected(value);
  }

  void debugSetLifecycleState(SocketLifecycleState value) {
    _setLifecycleState(value);
  }

  void _handleAuthRevoked(dynamic data) {
    final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    _authFailureController.add({...payload, 'terminal': true});
    _setLifecycleState(SocketLifecycleState.authFailed);
  }

  void debugEmitAuthFailure(Map<String, dynamic> payload) {
    _authFailureController.add(payload);
    _setLifecycleState(SocketLifecycleState.authFailed);
  }

  void debugHandleAuthRevoked(dynamic payload) {
    _handleAuthRevoked(payload);
  }

  void debugLogIncomingSocketEvent(String event, dynamic data) {
    _logIncomingSocketEvent(event, data);
  }

  String debugFormatData(dynamic data, {int maxLength = 500}) {
    return _formatDebugData(data, maxLength: maxLength);
  }

  void logIncomingSocketEvent(String event, dynamic data) {
    _logIncomingSocketEvent(event, data);
  }

  void logOutgoingSocketEvent(String event, dynamic data) {
    _logOutgoingSocketEvent(event, data);
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

      final debugData = _formatDebugData(_boundedSocketLogData(event, data));
      _logger.info('$logMessage: $debugData');
    } catch (_) {
      _logger.severe('Logging error for incoming event');
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

      final debugData = _formatDebugData(_boundedSocketLogData(event, data));
      _logger.info('$logMessage: $debugData');
    } catch (_) {
      _logger.severe('Logging error for outgoing event');
    }
  }

  Map<String, dynamic> _boundedSocketLogData(String event, dynamic data) {
    final payload = data is Map ? data : const <String, dynamic>{};
    if ({
      'get_account_lifecycle',
      'account_lifecycle_response',
      'account_lifecycle_changed',
      'revoke_account_principal',
      'account_lifecycle_revoke_result',
      'delete_account',
      'account_lifecycle_delete_result',
    }.contains(event)) {
      return {
        if (payload['version'] is num) 'version': payload['version'],
      };
    }
    // A typed error code is a short identifier, never content; log it so a
    // rejected command is diagnosable.
    final nested = payload['payload'];
    final code = payload['code'] ?? (nested is Map ? nested['code'] : null);
    return {
      'field_count': payload.length,
      if (code is String && RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(code)) 'code': code,
    };
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
        normalized == 'secrets' ||
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
