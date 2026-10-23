import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

export 'cli_turn_client.dart' show CliConnectionState;

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../core/config.dart' show ModelAwareCompactionPolicy;
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
  /// Interval between authoritative state re-reads while a stop is unconfirmed.
  static const defaultStopPollInterval = Duration(milliseconds: 250);

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
  ///
  /// With [steerOnly] the payload carries `steer_only: true`, which binds the
  /// daemon to reject the message with a typed `no_active_turn` error when no
  /// run owns the session instead of admitting it as a turn or queuing it. A
  /// caller that omits the flag keeps the legacy admit-or-queue behaviour.
  Future<String> steer({
    required String sessionId,
    required String message,
    String? workspaceId,
    String? model,
    String? requestId,
    bool steerOnly = false,
  }) async {
    final reqId = requestId ?? _uuid.v4();
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'message': message,
      'workspace_id': ?workspaceId,
      'model': ?model,
      'request_id': reqId,
      if (steerOnly) 'steer_only': true,
    };

    await sendCommand(command: 'steer', payload: payload, requestId: reqId);
    return reqId;
  }

  /// Dispatches a `steer` command and waits for the gateway's own delivery
  /// classification of that message id.
  ///
  /// The acknowledgement is the daemon's authoritative classification of the
  /// dispatched message, never proof that the instruction was applied: a steer
  /// takes effect at the next execution boundary. The normalized result is
  /// either a `session.message_classified` frame (`classification` is `steer`
  /// when the text was registered as a pending steer for the owning run,
  /// `queue`/`think` when it was admitted some other way), a
  /// `session.pending_steer_changed` record for the same request id, or a
  /// `session.queued_message_steer_result`.
  ///
  /// A typed gateway rejection is thrown as [CliClientException] carrying the
  /// gateway's own `code`. No acknowledgement within [requestTimeout] (or the
  /// caller's [timeout]) raises [CliClientException] with code
  /// `steer_unacknowledged` so a caller never reports an unconfirmed steer as
  /// sent.
  ///
  /// [steerOnly] is forwarded to [steer], so a daemon that honours it answers
  /// with a typed `no_active_turn` rejection rather than a `think`/`queue`
  /// classification when no run owns the session.
  Future<Map<String, dynamic>> steerAndAwaitAck({
    required String sessionId,
    required String message,
    String? workspaceId,
    String? model,
    String? requestId,
    bool steerOnly = false,
    Duration? timeout,
  }) async {
    final reqId = requestId ?? _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    final subscription = eventStream.listen((event) {
      if (completer.isCompleted) return;
      try {
        final ack = _steerAckFor(event, reqId, sessionId);
        if (ack != null) completer.complete(ack);
      } on CliClientException catch (error) {
        if (!completer.isCompleted) completer.completeError(error);
      }
    });
    final effectiveTimeout = timeout ?? requestTimeout;
    try {
      await steer(
        sessionId: sessionId,
        message: message,
        workspaceId: workspaceId,
        model: model,
        requestId: reqId,
        steerOnly: steerOnly,
      );
      return await completer.future.timeout(
        effectiveTimeout,
        onTimeout: () => throw CliClientException(
          'Gateway did not acknowledge the steer within '
          '${effectiveTimeout.inSeconds}s; it may still be dispatched.',
          code: 'steer_unacknowledged',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Normalizes one inbound event into a steer acknowledgement for [requestId].
  ///
  /// Only frames the daemon publishes for exactly this message id qualify, so
  /// a classification belonging to another turn can never be mistaken for this
  /// steer's outcome.
  Map<String, dynamic>? _steerAckFor(
    CliEvent event,
    String requestId,
    String sessionId,
  ) {
    final rawPayload = event.raw['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : const <String, dynamic>{};
    final eventRequestId =
        payload['request_id']?.toString() ??
        payload['target_request_id']?.toString();
    if (eventRequestId != requestId) return null;

    if (event is CliErrorEvent) {
      throw CliClientException(
        event.message,
        code: event.code.isEmpty ? 'gateway_error' : event.code,
      );
    }

    final ack = <String, dynamic>{
      'session_id': sessionId,
      'request_id': requestId,
      'event': event.type,
    };
    switch (event.type) {
      case 'session.message_classified':
        ack['classification'] = payload['classification']?.toString();
      case 'session.pending_steer_changed':
        // Only a record that is still pending (or already delivering/delivered)
        // proves the text was registered as a steer. A cancelled or recovered
        // record names the same request id but never became a steer, so it must
        // not be reported as one.
        final state = payload['state']?.toString();
        ack['state'] = state;
        ack['classification'] = switch (state) {
          'pending' || 'delivering' || 'delivered' => 'steer',
          _ => null,
        };
      case 'session.queued_message_steer_result':
        ack['outcome'] = payload['outcome']?.toString();
      default:
        ack['classification'] = null;
    }
    return ack;
  }

  /// Dispatches `session.runtime_retry` and waits for the daemon's own
  /// recovery transition for the session.
  ///
  /// The retry resumes the suspended request the session already owns, so the
  /// acknowledgement is the daemon's recovery projection, not a reply to the
  /// command: `session.runtime_notice` moving to `resuming` for [sessionId].
  ///
  /// * A `resuming` notice for the session is accepted even without a matching
  ///   request id: the daemon resumes under the *turn's* request id, so a strict
  ///   correlation would make every successful retry look unacknowledged. The
  ///   caller's pre-check ensures the session was blocked or waiting first, so a
  ///   `resuming` transition after the dispatch is the recovery it asked for.
  /// * A typed rejection is a correlated `error` frame or a correlated
  ///   `session.runtime_notice` whose status is `blocked`/`fatal`, and is thrown
  ///   as [CliClientException] carrying the gateway's own code.
  ///
  /// No answer within [requestTimeout] (or the caller's [timeout]) raises
  /// [CliClientException] with code `retry_unacknowledged`, so an unconfirmed
  /// retry is never reported as accepted.
  Future<Map<String, dynamic>> retryRuntimeAndAwaitAck({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    Duration? timeout,
  }) async {
    final reqId = requestId ?? _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    final subscription = eventStream.listen((event) {
      if (completer.isCompleted) return;
      try {
        final ack = _retryAckFor(event, reqId, sessionId);
        if (ack != null) completer.complete(ack);
      } on CliClientException catch (error) {
        if (!completer.isCompleted) completer.completeError(error);
      }
    });
    final effectiveTimeout = timeout ?? requestTimeout;
    try {
      await sendCommand(
        command: 'session.runtime_retry',
        payload: {
          'session_id': sessionId,
          'request_id': reqId,
          'provider_instance_id': ?providerInstanceId,
          'model_id': ?modelId,
        },
        requestId: reqId,
      );
      return await completer.future.timeout(
        effectiveTimeout,
        onTimeout: () => throw CliClientException(
          'Gateway did not acknowledge the retry within '
          '${effectiveTimeout.inSeconds}s; it may still be applied.',
          code: 'retry_unacknowledged',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Normalizes one inbound event into a retry acknowledgement for
  /// [requestId] and [sessionId].
  Map<String, dynamic>? _retryAckFor(
    CliEvent event,
    String requestId,
    String sessionId,
  ) {
    final rawPayload = event.raw['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : const <String, dynamic>{};
    final eventRequestId = payload['request_id']?.toString();
    final correlated = eventRequestId == requestId;
    final payloadSessionId = payload['session_id']?.toString();
    final forThisSession =
        payloadSessionId == null || payloadSessionId == sessionId;

    if (event is CliErrorEvent) {
      if (!correlated) return null;
      throw CliClientException(
        event.message,
        code: event.code.isEmpty ? 'gateway_error' : event.code,
      );
    }
    if (event is! CliRuntimeNoticeEvent || !forThisSession) return null;

    final status = payload['status']?.toString();
    if (status == 'resuming') {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'event': event.type,
        'status': status,
        'reason': payload['reason']?.toString(),
        'notice_request_id': eventRequestId,
        'correlated': correlated,
      };
    }
    if (correlated && (status == 'blocked' || status == 'fatal')) {
      final title = payload['title']?.toString() ?? 'Retry rejected';
      final message = payload['message']?.toString() ?? '';
      throw CliClientException(
        message.isEmpty ? title : '$title: $message',
        code: 'retry_rejected',
      );
    }
    return null;
  }

  /// Dispatches a `stop` command and waits for authoritative session state.
  ///
  /// The command mirrors the Sanad Client stop path: it is sent immediately,
  /// targets one session, and names the in-flight `run_id` when the caller knows
  /// it (the `sanad session stop` command resolves it from session state first).
  /// Success is only reported for an **authoritative idle** session. A matching
  /// `stopped` event merely wakes the wait early so the state is re-read; it is
  /// never accepted on its own (Task 134).
  @override
  Future<void> stop({
    required String sessionId,
    String? runId,
    Duration? timeout,
    Duration stopPollInterval = defaultStopPollInterval,
  }) async {
    final deadline = DateTime.now().add(timeout ?? requestTimeout);
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

      while (true) {
        // Every re-check is an ordered transport barrier: the daemon answers it
        // only after it has received the preceding stop command, so a running
        // projection here means the stop has not landed yet.
        final current = await _readSessionRuntimeState(sessionId);
        if (current.isIdle) return;
        if (!DateTime.now().isBefore(deadline)) {
          throw CliClientException(
            'Timed out waiting for session $sessionId to stop.',
            code: 'stop_timeout',
          );
        }
        if (stopped.isCompleted) {
          // The daemon already acknowledged this session; re-read immediately.
          await Future<void>.delayed(Duration.zero);
        } else {
          await Future.any<void>([
            Future<void>.delayed(stopPollInterval),
            stopped.future,
          ]);
        }
      }
    } finally {
      await subscription.cancel();
    }
  }

  /// Reads the daemon's authoritative runtime projection for [sessionId].
  Future<_CliSessionRuntimeState> _readSessionRuntimeState(
    String sessionId,
  ) async {
    final history = await getSessionHistory(
      sessionId: sessionId,
      timeout: requestTimeout,
    );
    _throwIfError(history);
    final payload = history['payload'] is Map
        ? Map<String, dynamic>.from(history['payload'] as Map)
        : history;
    final inFlight = payload['in_flight'] is Map
        ? Map<String, dynamic>.from(payload['in_flight'] as Map)
        : null;
    return _CliSessionRuntimeState(
      isIdle: inFlight == null && payload['pending_permission_request'] == null,
    );
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
  ///
  /// A typed `error` envelope is thrown as [CliClientException] carrying the
  /// gateway's own code: an unreadable session projection is never returned as
  /// if it were session state.
  Future<Map<String, dynamic>> getSessionHistory({
    required String sessionId,
    Duration? timeout,
  }) async {
    final result = await query(
      command: 'get_session_history',
      payload: {'session_id': sessionId},
      timeout: timeout,
    );
    _throwIfError(result);
    return result;
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
  ///
  /// When [resendOnTimeout] is false, a query timeout is not followed by a second
  /// fire-and-forget dispatch attempt and the timeout exception is rethrown directly.
  Future<Map<String, dynamic>> compactSession({
    required String sessionId,
    Duration? timeout,
    bool resendOnTimeout = true,
  }) async {
    try {
      final result = await query(
        command: 'session.compact',
        payload: {'session_id': sessionId},
        // The daemon replies when the compaction operation ends; without an
        // explicit bound wait the central compaction pass timeout (Task 125).
        timeout: timeout ?? ModelAwareCompactionPolicy.defaultPassTimeout,
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
      // only when resendOnTimeout is true.
      if (resendOnTimeout &&
          e is CliClientException &&
          e.code == 'query_timeout') {
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

  /// Throws the gateway's typed error when [result] is an `error` frame.
  ///
  /// The daemon's bridge publishes canonical frames as
  /// `{type: 'event', event: '<canonical type>', payload: {...}}`, while a
  /// query handler may answer with a bare `{type: 'error', payload: {...}}`.
  /// Both shapes are recognized, so a typed rejection is never returned to a
  /// caller as if it were a successful payload.
  static void _throwIfError(Map<String, dynamic> result) {
    final eventField = result['event'];
    final type = eventField is String
        ? eventField
        : result['message_type'] ??
              result['type'] ??
              (eventField is Map ? eventField['type'] : null);
    if (type == 'error') {
      final payload =
          result['payload'] ?? (eventField is Map ? eventField['payload'] : null);
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
      // The loopback gateway stamps owner authority; a CLI running
      // inside a remote relay asks for the weaker authority instead.
      if (!CommandAuthority.current.isOwner)
        CommandAuthority.payloadKey: CommandAuthority.unverified.value,
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

/// The daemon's authoritative runtime projection for one session.
class _CliSessionRuntimeState {
  const _CliSessionRuntimeState({required this.isIdle});

  /// True when the session has no in-flight execution and no pending
  /// intervention request.
  final bool isIdle;
}
