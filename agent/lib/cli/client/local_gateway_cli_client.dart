import 'dart:async';
import 'dart:convert';
import 'dart:io';

export 'cli_turn_client.dart' show CliConnectionState;

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../interfaces/models/agent_turn_request.dart';
import 'cli_turn_client.dart';
import '../discovery/local_gateway_discovery.dart';
import '../models/cli_events.dart';

class CliClientException implements Exception {
  final String message;
  final String code;
  final Object? cause;

  const CliClientException(
    this.message, {
    this.code = 'client_error',
    this.cause,
  });

  @override
  String toString() =>
      'CliClientException($code): $message${cause != null ? " ($cause)" : ""}';
}

/// Pluggable WebSocket connector for testing and abstraction.
typedef WebSocketConnector =
    Future<WebSocket> Function(
      Uri uri, {
      Map<String, dynamic>? headers,
      Duration? timeout,
    });

/// High-level WebSocket client connecting to the Sanad Local Gateway.
///
/// Implements Zero-Agent Core Mutation by acting as a clean consumer of
/// [SanadProtocolBridge] and [LocalDaemonServerPlatform].
class LocalGatewayCliClient implements CliTurnClient {
  LocalGatewayCliClient({
    required this.gatewayUri,
    required this.token,
    this.deviceId = 'cli_client',
    this.connectTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 15),
    this.autoReconnect = true,
    this.maxReconnectAttempts = 5,
    this.reconnectDelay = const Duration(seconds: 1),
    WebSocketConnector? connector,
  }) : _connector = connector ?? _defaultConnector;

  final Uri gatewayUri;
  final String token;
  final String deviceId;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final bool autoReconnect;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;
  final WebSocketConnector _connector;

  final _logger = Logger('LocalGatewayCliClient');
  final _uuid = const Uuid();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  bool _isDisposed = false;
  bool _explicitDisconnect = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  CliConnectionState _state = CliConnectionState.disconnected;
  final _stateController = StreamController<CliConnectionState>.broadcast();
  final _eventController = StreamController<CliEvent>.broadcast();

  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  CliConnectionState get state => _state;
  bool get isConnected => _state == CliConnectionState.connected;
  @override
  Stream<CliConnectionState> get stateStream => _stateController.stream;
  @override
  Stream<CliEvent> get eventStream => _eventController.stream;

  // Filtered streams for common consumption patterns
  @override
  Stream<CliAssistantChunkEvent> get assistantStream => eventStream
      .where((e) => e is CliAssistantChunkEvent)
      .cast<CliAssistantChunkEvent>();

  @override
  Stream<CliReasoningDeltaEvent> get reasoningStream => eventStream
      .where((e) => e is CliReasoningDeltaEvent)
      .cast<CliReasoningDeltaEvent>();

  @override
  Stream<CliToolCallEvent> get toolCallStream =>
      eventStream.where((e) => e is CliToolCallEvent).cast<CliToolCallEvent>();

  @override
  Stream<CliToolResultEvent> get toolResultStream => eventStream
      .where((e) => e is CliToolResultEvent)
      .cast<CliToolResultEvent>();

  @override
  Stream<CliPermissionRequestEvent> get permissionStream => eventStream
      .where((e) => e is CliPermissionRequestEvent)
      .cast<CliPermissionRequestEvent>();

  @override
  Stream<CliTurnCompleteEvent> get turnCompleteStream => eventStream
      .where((e) => e is CliTurnCompleteEvent)
      .cast<CliTurnCompleteEvent>();

  /// Factory that auto-discovers active port and token from SANAD_HOME.
  static Future<LocalGatewayCliClient> discoverAndConnect({
    String? urlOverride,
    int? portOverride,
    String? tokenOverride,
    String? sanadHomeOverride,
    String deviceId = 'cli_client',
    Duration connectTimeout = const Duration(seconds: 5),
    Duration requestTimeout = const Duration(seconds: 15),
    bool autoReconnect = true,
    WebSocketConnector? connector,
  }) async {
    final discovery = LocalGatewayDiscovery(
      sanadHomeOverride: sanadHomeOverride,
    );
    final result = await discovery.discover(
      urlOverride: urlOverride,
      portOverride: portOverride,
      tokenOverride: tokenOverride,
    );

    final client = LocalGatewayCliClient(
      gatewayUri: result.gatewayWsUri,
      token: result.token,
      deviceId: deviceId,
      connectTimeout: connectTimeout,
      requestTimeout: requestTimeout,
      autoReconnect: autoReconnect,
      connector: connector,
    );

    await client.connect();
    return client;
  }

  /// Establishes the WebSocket connection with canonical authentication headers.
  Future<void> connect() async {
    if (_isDisposed) {
      throw const CliClientException(
        'Client is already disposed',
        code: 'disposed',
      );
    }
    if (_state == CliConnectionState.connected) {
      return;
    }

    _setState(
      _reconnectAttempts > 0
          ? CliConnectionState.reconnecting
          : CliConnectionState.connecting,
    );
    _explicitDisconnect = false;

    final headers = <String, dynamic>{
      'x-sanad-gateway-token': token,
      'x-sanad-local-token': token,
      'authorization': 'Bearer $token',
    };

    try {
      _logger.info('Connecting to local gateway at $gatewayUri');
      try {
        _socket = await _connector(
          gatewayUri,
          headers: headers,
          timeout: connectTimeout,
        );
      } catch (error) {
        // If connecting to /gateway fails with 404 or connection error and default path was used,
        // attempt /ws fallback to match LocalDaemonServerPlatform route
        if (gatewayUri.path == '/gateway') {
          final fallbackUri = gatewayUri.replace(path: '/ws');
          _logger.info('Retrying connection with fallback path: $fallbackUri');
          _socket = await _connector(
            fallbackUri,
            headers: headers,
            timeout: connectTimeout,
          );
        } else {
          rethrow;
        }
      }

      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _setState(CliConnectionState.connected);

      _socketSub = _socket!.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      );
    } catch (e) {
      _setState(CliConnectionState.disconnected);
      _handleDisconnect(error: e);
      throw CliClientException(
        'Failed to connect to gateway at $gatewayUri: $e',
        code: 'connection_failed',
        cause: e,
      );
    }
  }

  /// Dispatches a `think` command to initiate or continue an agent turn.
  Future<String> think({
    required String sessionId,
    required String message,
    String? workspaceId,
    String? model,
    String? providerInstanceId,
    String? providerId,
    String? thinkingMode,
    String? requestId,
    String? deliveryIntent,
    Map<String, dynamic>? sessionMetadata,
    dynamic platformTools,
  }) async {
    final reqId = requestId ?? _uuid.v4();
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'message': message,
      'workspace_id': ?workspaceId,
      'model': ?model,
      'provider_instance_id': ?providerInstanceId,
      'provider_id': ?providerId,
      'thinking_mode': ?thinkingMode,
      'request_id': reqId,
      'delivery_intent': ?deliveryIntent,
      'session_metadata': ?sessionMetadata,
      'platform_tools': ?platformTools,
    };

    await sendCommand(command: 'think', payload: payload, requestId: reqId);
    return reqId;
  }

  /// Dispatches a `think` command using a canonical [AgentTurnRequest] envelope.
  @override
  Future<String> dispatchTurnRequest(AgentTurnRequest request) {
    return think(
      sessionId: request.sessionId,
      message: request.message,
      workspaceId: request.effectiveWorkspaceId,
      model: request.model,
      providerInstanceId: request.providerInstanceId,
      providerId: request.providerId,
      thinkingMode: request.thinkingMode,
      requestId: request.requestId,
      deliveryIntent: request.deliveryIntent.name,
      sessionMetadata: request.effectiveMetadata.isNotEmpty
          ? request.effectiveMetadata
          : null,
      platformTools: request.platformTools.isNotEmpty
          ? request.platformTools
          : null,
    );
  }

  /// Dispatches a `steer` command to guide active agent execution mid-turn.
  Future<String> steer({
    required String sessionId,
    required String message,
    String? workspaceId,
    String? model,
    String? requestId,
  }) async {
    final reqId = requestId ?? _uuid.v4();
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'message': message,
      'workspace_id': ?workspaceId,
      'model': ?model,
      'request_id': reqId,
    };

    await sendCommand(command: 'steer', payload: payload, requestId: reqId);
    return reqId;
  }

  /// Dispatches a `stop` command and waits for authoritative session state.
  @override
  Future<void> stop({required String sessionId, String? runId}) async {
    final stopped = Completer<void>();
    final subscription = eventStream
        .where((event) => event is CliTurnCancelledEvent)
        .cast<CliTurnCancelledEvent>()
        .where((event) => event.sessionId == sessionId)
        .listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        });
    final requestId = _uuid.v4();
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'run_id': ?runId,
      'request_id': requestId,
    };

    try {
      await sendCommand(
        command: 'stop',
        payload: payload,
        requestId: requestId,
      );

      // The history query is an ordered transport barrier. It keeps this
      // short-lived CLI connection alive until the daemon has received the
      // preceding stop command, while also preserving idempotent idle stops.
      final history = await getSessionHistory(
        sessionId: sessionId,
        timeout: requestTimeout,
      );
      final historyPayload = history['payload'] is Map
          ? Map<String, dynamic>.from(history['payload'] as Map)
          : history;
      final isIdle =
          historyPayload['in_flight'] == null &&
          historyPayload['pending_permission_request'] == null;
      if (isIdle || stopped.isCompleted) return;

      await stopped.future.timeout(
        requestTimeout,
        onTimeout: () => throw CliClientException(
          'Timed out waiting for session $sessionId to stop.',
          code: 'stop_timeout',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Responds to an interactive tool permission or clarification request.
  @override
  Future<void> respondPermission({
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? answer,
    String? comment,
    String? sessionId,
  }) async {
    final payload = <String, dynamic>{
      'request_id': requestId,
      'allowed': allowed,
      'scope': scope,
      'decision': ?decision,
      'answer': ?answer,
      'comment': ?comment,
      'session_id': ?sessionId,
    };

    await sendCommand(
      command: 'tool_permission_response',
      payload: payload,
      requestId: requestId,
    );
  }

  /// Submits an answer to a clarification question (`system_ask_user`) and awaits gateway confirmation.
  Future<Map<String, dynamic>> respondAnswer({
    required String sessionId,
    required String requestId,
    required String answer,
    Duration? timeout,
  }) async {
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'request_id': requestId,
      'answer': answer,
      'allowed': true,
      'decision': 'allow',
    };

    final result = await query(
      command: 'tool_permission_response',
      payload: payload,
      timeout: timeout,
    );
    _throwIfError(result);
    return result;
  }

  /// Submits a tool permission decision and awaits gateway confirmation.
  Future<Map<String, dynamic>> respondToolPermission({
    required String sessionId,
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? comment,
    Duration? timeout,
  }) async {
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'request_id': requestId,
      'allowed': allowed,
      'scope': scope,
      'decision': decision ?? (allowed ? 'allow' : 'deny'),
      'comment': ?comment,
    };

    final result = await query(
      command: 'tool_permission_response',
      payload: payload,
      timeout: timeout,
    );
    _throwIfError(result);
    return result;
  }

  /// Sends a request-response query to the gateway and awaits the matching response.
  Future<Map<String, dynamic>> query({
    required String command,
    Map<String, dynamic>? payload,
    Duration? timeout,
  }) async {
    final reqId = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[reqId] = completer;

    final effectiveTimeout = timeout ?? requestTimeout;
    Timer? timeoutTimer;
    if (effectiveTimeout > Duration.zero) {
      timeoutTimer = Timer(effectiveTimeout, () {
        if (!completer.isCompleted) {
          _pendingRequests.remove(reqId);
          completer.completeError(
            CliClientException(
              'Gateway query "$command" timed out after ${effectiveTimeout.inSeconds}s',
              code: 'query_timeout',
            ),
          );
        }
      });
    }

    try {
      await sendCommand(
        command: command,
        payload: payload ?? const {},
        requestId: reqId,
      );
      final result = await completer.future;
      timeoutTimer?.cancel();
      return result;
    } catch (e) {
      timeoutTimer?.cancel();
      _pendingRequests.remove(reqId);
      rethrow;
    }
  }

  /// Fetches system capabilities from the gateway.
  Future<Map<String, dynamic>> getCapabilities({Duration? timeout}) async {
    final reqId = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[reqId] = completer;

    final envelope = <String, dynamic>{
      'type': 'get_capabilities',
      'request_id': reqId,
      'device_id': deviceId,
    };

    _sendJson(envelope);

    final effectiveTimeout = timeout ?? requestTimeout;
    return completer.future.timeout(
      effectiveTimeout,
      onTimeout: () {
        _pendingRequests.remove(reqId);
        throw CliClientException(
          'get_capabilities timed out after ${effectiveTimeout.inSeconds}s',
          code: 'query_timeout',
        );
      },
    );
  }

  /// Queries all registered sessions from the gateway.
  Future<List<Map<String, dynamic>>> getSessions({Duration? timeout}) async {
    final result = await query(
      command: 'get_sessions',
      payload: const {},
      timeout: timeout,
    );
    final sessions = result['sessions'] ?? result['payload']?['sessions'];
    if (sessions is List) {
      return sessions
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
    }
    return const [];
  }

  /// Queries message history for a specific session.
  Future<Map<String, dynamic>> getSessionHistory({
    required String sessionId,
    Duration? timeout,
  }) async {
    return query(
      command: 'get_session_history',
      payload: {'session_id': sessionId},
      timeout: timeout,
    );
  }

  /// Queries registered workspaces.
  Future<List<Map<String, dynamic>>> listWorkspaces({Duration? timeout}) async {
    final result = await query(
      command: 'list_workspaces',
      payload: const {},
      timeout: timeout,
    );
    _throwIfError(result);
    final workspaces =
        result['workspaces'] ??
        result['payload']?['workspaces'] ??
        result['event']?['payload']?['workspaces'];
    if (workspaces is List) {
      return workspaces
          .whereType<Map>()
          .map((w) => Map<String, dynamic>.from(w))
          .toList();
    }
    return const [];
  }

  /// Creates or registers a workspace via the gateway.
  Future<Map<String, dynamic>> createWorkspace({
    required String name,
    String? path,
    String? description,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'create_workspace',
      payload: {'name': name, 'path': ?path, 'description': ?description},
      timeout: timeout,
    );
    _throwIfError(result);
    final workspace =
        result['workspace'] ??
        result['payload']?['workspace'] ??
        result['event']?['payload']?['workspace'];
    if (workspace is Map) {
      return Map<String, dynamic>.from(workspace);
    }
    return result;
  }

  /// Browses the directory tree of a workspace via the gateway.
  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'browse_workspace_tree',
      payload: {
        'workspace_id': ?workspaceId,
        'path': ?path,
        'max_entries': maxEntries,
      },
      timeout: timeout,
    );
    _throwIfError(result);
    final payload = result['payload'] ?? result['event']?['payload'] ?? result;
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return result;
  }

  /// Gets the security policy of a workspace via the gateway.
  Future<Map<String, dynamic>> getWorkspacePolicy({
    required String workspacePath,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'workspace.get_policy',
      payload: {'workspace_path': workspacePath},
      timeout: timeout,
    );
    _throwIfError(result);
    final payload = result['payload'] ?? result['event']?['payload'] ?? result;
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return result;
  }

  /// Sets the security permission mode of a workspace via the gateway.
  Future<Map<String, dynamic>> setWorkspacePermissionMode({
    required String workspaceId,
    required String permissionMode,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'workspace.set_permission_mode',
      payload: {'workspace_id': workspaceId, 'permission_mode': permissionMode},
      timeout: timeout,
    );
    _throwIfError(result);
    final payload = result['payload'] ?? result['event']?['payload'] ?? result;
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return result;
  }

  /// Lists MCP servers associated with a workspace via the gateway.
  Future<Map<String, dynamic>> listMcpServers({
    String? workspaceId,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'list_mcp_servers',
      payload: {'workspace_id': ?workspaceId},
      timeout: timeout,
    );
    _throwIfError(result);
    final payload = result['payload'] ?? result['event']?['payload'] ?? result;
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return result;
  }

  /// Dispatches a `session.compact` command to compact the active session context.
  Future<Map<String, dynamic>> compactSession({
    required String sessionId,
    Duration? timeout,
  }) async {
    try {
      final result = await query(
        command: 'session.compact',
        payload: {'session_id': sessionId},
        timeout: timeout ?? const Duration(seconds: 5),
      );
      _throwIfError(result);
      final payload =
          result['payload'] ?? result['event']?['payload'] ?? result;
      if (payload is Map) {
        return Map<String, dynamic>.from(payload);
      }
      return result;
    } catch (e) {
      // If query timed out or failed to correlate, attempt fire-and-forget fallback
      if (e is CliClientException && e.code == 'query_timeout') {
        await sendCommand(
          command: 'session.compact',
          payload: {'session_id': sessionId},
        );
        return {'outcome': 'dispatched'};
      }
      rethrow;
    }
  }

  /// Lists available skills via the gateway.
  Future<Map<String, dynamic>> listSkills({
    String? workspaceId,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'list_skills',
      payload: {'workspace_id': ?workspaceId},
      timeout: timeout,
    );
    _throwIfError(result);
    final payload = result['payload'] ?? result['event']?['payload'] ?? result;
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return result;
  }

  /// Searches registered slash commands via the gateway.
  Future<List<Map<String, dynamic>>> searchSlashCommands({
    String? query,
    String? workspaceId,
    Duration? timeout,
  }) async {
    final result = await this.query(
      command: 'search_slash_commands',
      payload: {'query': ?query, 'workspace_id': ?workspaceId},
      timeout: timeout,
    );
    _throwIfError(result);
    final list =
        result['slash_commands'] ??
        result['payload']?['slash_commands'] ??
        result['event']?['payload']?['slash_commands'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return const [];
  }

  static void _throwIfError(Map<String, dynamic> result) {
    final type =
        result['message_type'] ?? result['type'] ?? result['event']?['type'];
    if (type == 'error') {
      final payload = result['payload'] ?? result['event']?['payload'];
      final message = payload is Map ? payload['message']?.toString() : null;
      throw CliClientException(
        message ?? 'Gateway request failed with error.',
        code:
            (payload is Map ? payload['code']?.toString() : null) ??
            'gateway_error',
      );
    }
  }

  /// Sends a raw command envelope over the WebSocket.
  Future<void> sendCommand({
    required String command,
    required Map<String, dynamic> payload,
    String? requestId,
  }) async {
    if (!isConnected) {
      throw const CliClientException(
        'Cannot send command: client is not connected to gateway.',
        code: 'not_connected',
      );
    }

    final effectivePayload = <String, dynamic>{
      ...payload,
      if (requestId != null && !payload.containsKey('request_id'))
        'request_id': requestId,
    };

    final envelope = <String, dynamic>{
      'type': 'execute_command',
      'command': command,
      'payload': effectivePayload,
      'device_id': deviceId,
      'request_id': ?requestId,
    };

    _sendJson(envelope);
  }

  void _sendJson(Map<String, dynamic> data) {
    try {
      final jsonStr = jsonEncode(data);
      _socket?.add(jsonStr);
    } catch (e) {
      _logger.warning('Failed to send payload over socket: $e');
      throw CliClientException(
        'Failed to send data: $e',
        code: 'send_error',
        cause: e,
      );
    }
  }

  void _onMessage(dynamic data) {
    if (_isDisposed) return;

    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      final json = jsonDecode(text);
      if (json is! Map) return;
      final map = Map<String, dynamic>.from(json);

      // Check if this fulfills a pending query request by request_id
      String? reqId = map['request_id']?.toString();
      if (reqId == null && map['payload'] is Map) {
        reqId = (map['payload'] as Map)['request_id']?.toString();
      }
      if (reqId == null && map['event'] is Map) {
        final ev = map['event'] as Map;
        if (ev['payload'] is Map) {
          reqId = (ev['payload'] as Map)['request_id']?.toString();
        }
      }

      if (reqId != null && _pendingRequests.containsKey(reqId)) {
        final completer = _pendingRequests.remove(reqId);
        completer?.complete(map);
      }

      final event = CliEvent.fromJson(map);
      _eventController.add(event);
    } catch (e, stack) {
      _logger.warning(
        'Failed to decode incoming gateway message: $e',
        e,
        stack,
      );
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _logger.warning('Gateway socket error: $error', error, stackTrace);
    _handleDisconnect(error: error);
  }

  void _onDone() {
    _logger.info('Gateway socket closed.');
    _handleDisconnect();
  }

  void _handleDisconnect({Object? error}) {
    _socketSub?.cancel();
    _socketSub = null;
    _socket = null;

    // Fail any outstanding pending requests
    final pending = Map<String, Completer<Map<String, dynamic>>>.from(
      _pendingRequests,
    );
    _pendingRequests.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          CliClientException(
            'Gateway disconnected before query completed.',
            code: 'disconnected',
            cause: error,
          ),
        );
      }
    }

    if (_isDisposed || _explicitDisconnect) {
      _setState(CliConnectionState.closed);
      return;
    }

    _setState(CliConnectionState.disconnected);

    if (autoReconnect && _reconnectAttempts < maxReconnectAttempts) {
      _reconnectAttempts++;
      final delay = reconnectDelay * _reconnectAttempts;
      _logger.info(
        'Scheduling reconnect attempt $_reconnectAttempts/$maxReconnectAttempts in ${delay.inSeconds}s',
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(delay, () async {
        try {
          await connect();
        } catch (_) {
          // Failure in auto-reconnect will re-trigger _handleDisconnect
        }
      });
    } else {
      _setState(CliConnectionState.closed);
    }
  }

  void _setState(CliConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Gracefully closes the connection and cancels reconnect timers.
  Future<void> disconnect() async {
    _explicitDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await _socket?.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    _socket = null;

    _setState(CliConnectionState.closed);
  }

  /// Disposes all resources and streams.
  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    try {
      await disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _stateController.close();
    await _eventController.close();
  }

  static Future<WebSocket> _defaultConnector(
    Uri uri, {
    Map<String, dynamic>? headers,
    Duration? timeout,
  }) async {
    final future = WebSocket.connect(
      uri.toString(),
      headers: headers?.map((k, v) => MapEntry(k, v.toString())),
    );
    if (timeout != null && timeout > Duration.zero) {
      return future.timeout(timeout);
    }
    return future;
  }
}
