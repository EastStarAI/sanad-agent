import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:sanad_agent/core/app_config.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/colocated_auth_coupling.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/sanad_home/loopback_policy.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/core/utils/logger.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';

import 'capabilities_loader.dart';
import 'sanad_protocol_bridge.dart';
import 'protocol/canonical_events.dart';
import 'channels/websocket_session_channel.dart';
import 'sanad_gateway_behavior.dart';
import 'package:sanad_agent/infrastructure/voice/voice_engine.dart';
import 'package:sanad_agent/infrastructure/voice/voice_transport_channel.dart';
import 'package:sanad_agent/infrastructure/voice/gemini_voice_provider.dart';

class LocalDaemonServerPlatform extends BasePlatform with SanadGatewayBehavior {
  final _logger = Logger('LocalDaemonServerPlatform');

  /// Local Gateway security policy. Dependency composition may inject it;
  /// otherwise initialization loads the owner-only local credential before
  /// the server binds. There is no tokenless fallback.
  LocalGatewaySecurity? _security;
  ColocatedAuthCoupling? _authCoupling;
  final Future<void> Function()? beforeUpgradeAuthentication;

  @override
  Logger get logger => _logger;

  @override
  SanadProtocolBridge get protocolBridge => _protocolBridge;

  @override
  String get transportName => 'ws';
  final _eventController = StreamController<GatewayEvent>.broadcast();
  final _clients = <WebSocket>{};
  final _sessionClients = <String, WebSocket>{};
  final _sessionDeviceIds = <String, String>{};
  final _sessionHardwareIds = <String, String>{};

  /// Phase 27 — per-socket device_id registry. When a socket sends a
  /// command, we record its device_id so that later platform_family
  /// broadcasts can stamp each socket's copy with the device_id it expects
  /// (e.g. "local-agent"). Without this, cloud-origin events mirrored to
  /// local sockets carry the daemon's hardware_id, which the local client's
  /// EventRouter has no listener for.
  final _socketDeviceIds = <WebSocket, String>{};
  final _voiceEngines = <VoiceEngine>[];

  HttpServer? _server;
  StreamSubscription<void>? _authChangeSubscription;

  @override
  String get platformId => 'local_gateway';

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor.sanadClient(
    transport: PlatformTransport.local,
    platformInstanceId: 'local-daemon',
  );

  @override
  bool get shouldReceiveUserEcho => true;

  @override
  Stream<GatewayEvent> get eventStream => _eventController.stream;

  SanadProtocolBridge get _protocolBridge => getIt<SanadProtocolBridge>();
  PlatformRuntimeBridge get _platformRuntimeBridge =>
      getIt<PlatformRuntimeBridge>();
  Config get _config => getIt<Config>();
  bool get _e2eTestModeEnabled =>
      Platform.environment['SANAD_E2E_TEST_MODE']?.trim().toLowerCase() ==
      'true';

  LocalDaemonServerPlatform({
    LocalGatewaySecurity? security,
    ColocatedAuthCoupling? authCoupling,
    this.beforeUpgradeAuthentication,
  }) : _security = security,
       _authCoupling = authCoupling;

  @override
  Future<void> initialize() async {
    _authChangeSubscription ??= getIt<AuthManager>().changes.listen((_) {
      unawaited(_broadcastAuthenticationExchange());
    });

    final host = _config.localGatewayHost;
    final port = _config.localGatewayPort;

    // SEC-02 / INV-1: refuse any non-loopback bind. We log one warning
    // and rethrow so the daemon entry point can exit non-zero. We never
    // silently fall back to loopback.
    if (!LoopbackPolicy.isLoopbackHost(host)) {
      _logger.warning(
        'Refusing to bind local gateway to a non-loopback host. '
        'SEC-02 requires loopback-only.',
      );
      throw LocalGatewayBindViolation(host);
    }

    _security ??= LocalGatewaySecurity(
      config: LocalGatewaySecurityConfig(allowedPort: port),
      expectedToken: await LocalGatewayCredentials.loadOrCreate(),
    );

    try {
      _server = await HttpServer.bind(host, port, shared: true);
    } on SocketException catch (e, stack) {
      _logger.severe(
        'Failed to bind local gateway on ${_config.localGatewayUrl}. '
        'Local platform disabled while other platforms continue.',
        e,
        stack,
      );
      rethrow;
    }

    _logger.info(
      'Local daemon gateway listening on ${_config.localGatewayUrl}',
    );
    unawaited(_listen());
  }

  Future<void> _listen() async {
    final server = _server;
    if (server == null) {
      return;
    }

    await for (final request in server) {
      unawaited(_dispatchHttpRequest(request));
    }
  }

  Future<void> _dispatchHttpRequest(HttpRequest request) async {
    try {
      await _handleHttpRequest(request);
    } on Object catch (error, stackTrace) {
      _logger.warning(
        'Local daemon request failed for ${request.uri.path}.',
        error,
        stackTrace,
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The peer may already have disconnected.
      }
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final isWebSocketUpgrade =
        request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request);
    final peerKey = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (isWebSocketUpgrade && !_security!.tryReserveUpgrade(peerKey)) {
      await _writeAuthFailure(
        request.response,
        LocalGatewayAuthResult.budgetExhausted('preauth_handshake_budget'),
      );
      return;
    }
    if (isWebSocketUpgrade) {
      try {
        await beforeUpgradeAuthentication?.call();
      } on Object {
        _security!.releaseUpgrade(peerKey);
        rethrow;
      }
    }

    // SEC-02 / INV-2, INV-3: gate every HTTP request through the
    // LocalGatewaySecurity policy before any business logic runs.
    final gate = _security!.verifyHttp(
      headers: request.headers,
      remoteAddress: request.connectionInfo?.remoteAddress,
    );
    if (!gate.isOk) {
      if (isWebSocketUpgrade) {
        _security!.releaseUpgrade(peerKey);
      }
      await _writeAuthFailure(request.response, gate);
      return;
    }

    if (request.uri.path == '/auth/logout') {
      final hasBody =
          request.headers.contentLength > 0 ||
          request.headers.value(HttpHeaders.transferEncodingHeader) != null;
      if (request.method != 'POST' || request.uri.hasQuery || hasBody) {
        await _writeJsonResponse(request.response, const {
          'status': 'invalid_request',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      await getIt<AuthManager>().logout();
      await _writeJsonResponse(request.response, const {
        'status': 'logged_out',
      });
      return;
    }

    if (request.uri.path == '/auth/coupling') {
      final hasBody =
          request.headers.contentLength > 0 ||
          request.headers.value(HttpHeaders.transferEncodingHeader) != null;
      if (request.uri.hasQuery ||
          hasBody ||
          (request.method != 'GET' && request.method != 'POST')) {
        await _writeJsonResponse(request.response, {
          'status': 'invalid_request',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final coupling = _authCoupling ??= ColocatedAuthCoupling(
        authManager: getIt<AuthManager>(),
        authorizationClient: DeviceAuthorizationClient(
          portalUrl: _config.portalUrl,
          authManager: getIt<AuthManager>(),
        ),
      );
      final snapshot = request.method == 'POST'
          ? await coupling.start()
          : coupling.snapshot;
      await _writeJsonResponse(request.response, snapshot.toJson());
      return;
    }

    if (request.uri.path == '/health') {
      final stateMode = (getSanadStateHome() != getSanadHome())
          ? 'isolated'
          : 'default';
      await _writeJsonResponse(request.response, {
        'status': 'ok',
        'platform_id': platformId,
        'url': _config.localGatewayUrl,
        'version': _config.version,
        'is_source': AppConfig.isSourceRun,
        'workspace_hash': _workspaceHash(),
        'dev_launcher_id': Platform.environment['SANAD_DEV_LAUNCHER_ID'],
        'dev_runtime_nonce': Platform.environment['SANAD_DEV_RUNTIME_NONCE'],
        'state_mode': stateMode,
        'gateway_enabled': _config.enableGateway,
      });
      return;
    }

    if (request.uri.path == '/update' && request.method == 'POST') {
      String? targetVersion;
      try {
        targetVersion = request.uri.queryParameters['target_version']?.trim();
        if (targetVersion == null || targetVersion.isEmpty) {
          throw const FormatException('target_version is required.');
        }
        ReleaseVersion.parse(targetVersion);
      } on FormatException catch (error) {
        await _writeJsonResponse(request.response, {
          'success': false,
          'status': 'target_mismatch',
          'message': error.message,
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final updater = AgentUpdateService(
        currentVersion: _config.version,
        executablePath: Platform.resolvedExecutable,
        isSourceManaged: AppConfig.isSourceRun,
      );
      var result = await updater.update(targetVersion: targetVersion);
      if (Platform.isWindows && result.stagedPath != null) {
        final scheduled = await updater.scheduleWindowsReplacement(result);
        if (!scheduled) {
          result = result.copyWith(
            status: AgentUpdateStatus.scheduleFailed,
            message:
                'Verified replacement could not be scheduled; the running agent was kept.',
          );
        }
      }
      await _writeJsonResponse(
        request.response,
        result.toJson(),
        statusCode: result.isSuccess
            ? HttpStatus.ok
            : HttpStatus.unprocessableEntity,
      );
      if (result.status == AgentUpdateStatus.restartRequired) {
        unawaited(
          Platform.isWindows
              ? getIt<DaemonRestartCoordinator>().stop()
              : getIt<DaemonRestartCoordinator>().restart(),
        );
      }
      return;
    }

    if (request.uri.path == '/logs' && request.method == 'GET') {
      await _writeJsonResponse(request.response, {'logs': agentLogs});
      return;
    }

    if (request.uri.path == '/restart' && request.method == 'POST') {
      final forceRaw = request.uri.queryParameters['force'];
      if (forceRaw != null && forceRaw != 'true' && forceRaw != 'false') {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_force',
          'message': 'force must be true or false.',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final force = forceRaw == 'true';
      final permanentRaw = request.uri.queryParameters['permanent'];
      if (permanentRaw != null &&
          permanentRaw != 'true' &&
          permanentRaw != 'false') {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_permanent',
          'message': 'permanent must be true or false.',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final permanent = permanentRaw == 'true';
      final timeoutRaw = request.uri.queryParameters['timeout_seconds'];
      final timeoutSeconds = timeoutRaw == null
          ? null
          : int.tryParse(timeoutRaw);
      if (timeoutRaw != null &&
          (timeoutSeconds == null ||
              timeoutSeconds < 1 ||
              timeoutSeconds > 3600)) {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_timeout',
          'message': 'timeout_seconds must be between 1 and 3600.',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final coordinator = getIt<DaemonRestartCoordinator>();
      final preparation = await coordinator.prepareRestart(
        force: force,
        timeout: Duration(
          seconds:
              timeoutSeconds ??
              SessionRunOrchestrator
                  .controlledRestartCheckpointTimeout
                  .inSeconds,
        ),
        requesterSessionId: request.headers.value(
          'x-sanad-requester-session-id',
        ),
        requesterToolCallId: request.headers.value(
          'x-sanad-requester-tool-call-id',
        ),
      );
      try {
        await _writeJsonResponse(
          request.response,
          preparation.toJson(),
          statusCode: preparation.accepted
              ? HttpStatus.ok
              : preparation.outcome == 'internal_error'
              ? HttpStatus.internalServerError
              : HttpStatus.conflict,
        );
      } on Object catch (error) {
        coordinator.abandonPreparedRestart(preparation);
        _logger.warning(
          'Restart response could not be flushed; restart was cancelled: '
          '$error',
        );
        return;
      }
      unawaited(
        permanent
            ? coordinator.completePreparedStop(preparation)
            : coordinator.completePreparedRestart(preparation),
      );
      return;
    }

    if (request.uri.path == '/shutdown' && request.method == 'POST') {
      final mode = request.uri.queryParameters['mode'] ?? 'pause';
      if (mode != 'pause' && mode != 'cancel') {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_mode',
          'message': 'mode must be pause or cancel.',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final coordinator = getIt<DaemonRestartCoordinator>();
      if (mode == 'cancel') {
        await _writeJsonResponse(request.response, {
          'success': true,
          'outcome': 'cancelled',
          'message': 'Daemon work cancelled; shutting down permanently.',
        });
        unawaited(coordinator.stop());
        return;
      }

      final timeoutRaw = request.uri.queryParameters['timeout_seconds'];
      final timeoutSeconds = timeoutRaw == null
          ? SessionRunOrchestrator.controlledRestartCheckpointTimeout.inSeconds
          : int.tryParse(timeoutRaw);
      if (timeoutSeconds == null ||
          timeoutSeconds < 1 ||
          timeoutSeconds > 3600) {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_timeout',
          'message': 'timeout_seconds must be between 1 and 3600.',
        }, statusCode: HttpStatus.badRequest);
        return;
      }
      final preparation = await coordinator.prepareRestart(
        timeout: Duration(seconds: timeoutSeconds),
      );
      try {
        await _writeJsonResponse(
          request.response,
          preparation.toJson(),
          statusCode: preparation.accepted
              ? HttpStatus.ok
              : preparation.outcome == 'internal_error'
              ? HttpStatus.internalServerError
              : HttpStatus.conflict,
        );
      } on Object catch (error) {
        coordinator.abandonPreparedRestart(preparation);
        _logger.warning(
          'Pause response could not be flushed; shutdown was cancelled: $error',
        );
        return;
      }
      unawaited(coordinator.completePreparedPause(preparation));
      return;
    }

    if (request.uri.path == '/stop' && request.method == 'POST') {
      _logger.info('Received stop request from client. Exiting permanently...');
      await _writeJsonResponse(request.response, {
        'success': true,
        'message': 'Daemon exiting permanently...',
      });
      unawaited(getIt<DaemonRestartCoordinator>().stop());
      return;
    }

    if (request.uri.path == '/authentication-exchange' &&
        request.method == 'POST') {
      await getIt<AuthManager>().reload(notifyIfChanged: true);
      await _writeJsonResponse(request.response, const {'success': true});
      return;
    }

    if (request.uri.path == '/capabilities') {
      final capabilities = await loadSanadCapabilities();
      await _writeJsonResponse(request.response, capabilities.toJson());
      return;
    }

    if (isWebSocketUpgrade) {
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        final type = request.uri.queryParameters['type'];
        if (type == 'voice') {
          final sessionId =
              request.uri.queryParameters['session_id'] ?? 'default';
          final deviceId = request.uri.queryParameters['device_id'] ?? '';
          _acceptVoiceClient(socket, sessionId, deviceId);
        } else if (type == 'logs') {
          agentLogWebSockets.add(socket);
          socket.done.then((_) => agentLogWebSockets.remove(socket));
        } else {
          _acceptClient(socket);
        }
      } finally {
        // The budget protects only the unauthenticated HTTP upgrade
        // handshake. Authenticated socket lifetime is not pre-auth work.
        _security!.releaseUpgrade(peerKey);
      }
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _acceptClient(WebSocket socket) {
    _clients.add(socket);
    _logger.info(
      '🔌 [ws] Local client connected. Active local clients: ${_clients.length}',
    );

    final welcomePayload = {
      'type': 'register_success',
      'platform_id': platformId,
      'url': _config.localGatewayUrl,
    };
    _logger.info('⬆️ [ws] Sending register_success to client');
    _logger.fine('⬆️ [ws] Welcome payload: $welcomePayload');
    _sendToSocket(socket, welcomePayload);

    socket.listen(
      (data) async {
        await _handleClientMessage(socket, data);
      },
      onDone: () {
        _clients.remove(socket);
        _socketDeviceIds.remove(socket);
        _platformRuntimeBridge.unregisterChannel(
          WebSocketSessionChannel(socket),
        );
        final closedSessionIds = <String>[];
        _sessionClients.removeWhere((sessionId, client) {
          final matches = identical(client, socket);
          if (matches) {
            closedSessionIds.add(sessionId);
          }
          return matches;
        });
        for (final sessionId in closedSessionIds) {
          _sessionDeviceIds.remove(sessionId);
          _sessionHardwareIds.remove(sessionId);
        }
        _logger.info(
          '🔌 [ws] Local client disconnected. Active local clients: ${_clients.length}',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _logger.warning('❌ [ws] Local client error: $error', error, stackTrace);
      },
      cancelOnError: true,
    );
  }

  Future<void> _handleClientMessage(WebSocket socket, dynamic data) async {
    final envelope = _decodeMessage(data);
    if (envelope == null) {
      _logger.warning('⬇️ [ws] Ignoring malformed local client message.');
      return;
    }

    final type = envelope['type'] as String?;
    _logger.fine('⬇️ [ws] Received message type: $type');
    if (type == 'authentication_exchange') {
      if (envelope.length != 1) {
        _logger.warning(
          'Ignoring authentication_exchange with unexpected fields.',
        );
        return;
      }
      // The notification carries no credentials and grants no state. The
      // owner-only shared document remains the sole authentication authority.
      await getIt<AuthManager>().reload(notifyIfChanged: true);
      return;
    }

    _logger.fine('⬇️ [ws] Message payload: $envelope');
    _rememberSocketIdentity(socket, envelope);

    if (type == 'get_capabilities') {
      final capabilities = await loadSanadCapabilities();
      final capabilitiesPayload = {
        'type': 'capabilities',
        if (envelope['device_id'] != null) 'device_id': envelope['device_id'],
        if (envelope['hardware_id'] != null)
          'hardware_id': envelope['hardware_id'],
        'payload': capabilities.toJson(),
        if (envelope['request_id'] != null)
          'request_id': envelope['request_id'],
      };
      _logger.info('⬆️ [ws] Sending capabilities to client');
      _logger.fine('⬆️ [ws] Capabilities payload: $capabilitiesPayload');
      _sendToSocket(socket, capabilitiesPayload);
      return;
    }

    if (type == 'protocol_event') {
      final rawEvent = envelope['event'];
      final eventMap = toMap(rawEvent);
      if (eventMap.isEmpty) {
        return;
      }
      final canonicalEvent = CanonicalEvent.fromJson(eventMap);
      if (_e2eTestModeEnabled &&
          await _handleE2eFixtureProtocolEvent(socket, canonicalEvent)) {
        return;
      }
      await handleIncomingProtocolEvent(
        event: canonicalEvent,
        runtimeBridge: _platformRuntimeBridge,
        onResponse: (responseEnvelope) =>
            _sendAgentEventToSocket(socket, responseEnvelope),
        envelope: eventMap,
      );
      return;
    }

    final commandEnvelope =
        type == 'execute_command' || envelope.containsKey('command')
        ? envelope
        : null;
    if (commandEnvelope == null) {
      return;
    }

    final payload = toMap(commandEnvelope['payload']);
    final sessionId = payload['session_id'] as String?;
    final deviceId = commandEnvelope['device_id'] as String?;
    final hardwareId = commandEnvelope['hardware_id'] as String?;
    if (sessionId != null) {
      _sessionClients[sessionId] = socket;
      if (deviceId != null && deviceId.isNotEmpty) {
        _sessionDeviceIds[sessionId] = deviceId;
      }
      if (hardwareId != null && hardwareId.isNotEmpty) {
        _sessionHardwareIds[sessionId] = hardwareId;
      }
      _platformRuntimeBridge.registerSessionClient(
        sessionId,
        WebSocketSessionChannel(socket, deviceId: deviceId),
        deviceId: deviceId,
      );
      _platformRuntimeBridge.registerSessionHandlers(
        sessionId,
        responseEmitter: (response) => sendResponse(response),
      );
    }

    final handled = await handleIncomingCommand(
      envelope: commandEnvelope,
      runtimeBridge: _platformRuntimeBridge,
      onResponse: (responseEnvelope) => _sendAgentEventToSocket(
        socket,
        _withCommandIdentity(responseEnvelope, commandEnvelope),
      ),
    );
    if (handled) {
      return;
    }

    final commandName = commandEnvelope['command'] ?? 'unknown';
    final gatewayEvent = _protocolBridge.translateCommand(
      commandEnvelope,
      platformId,
    );
    if (gatewayEvent == null) {
      _logger.warning('Unknown or unhandled command: $commandName');
      return;
    }
    final resolvedSessionId = gatewayEvent.sessionId;

    _sessionClients[resolvedSessionId] = socket;
    if (deviceId != null && deviceId.isNotEmpty) {
      _sessionDeviceIds[resolvedSessionId] = deviceId;
    }
    if (hardwareId != null && hardwareId.isNotEmpty) {
      _sessionHardwareIds[resolvedSessionId] = hardwareId;
    }
    _platformRuntimeBridge.registerSessionClient(
      resolvedSessionId,
      WebSocketSessionChannel(socket, deviceId: deviceId),
      deviceId: deviceId,
    );
    _platformRuntimeBridge.registerSessionHandlers(
      resolvedSessionId,
      responseEmitter: (response) => sendResponse(response),
    );

    _eventController.add(gatewayEvent);
  }

  Future<bool> _handleE2eFixtureProtocolEvent(
    WebSocket socket,
    CanonicalEvent event,
  ) async {
    switch (event.type) {
      case 'debug.runtime_notice_wait':
        if (!getIt.isRegistered<RuntimeRecoveryService>()) {
          return true;
        }
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString() ?? '';
        if (sessionId.isEmpty) {
          return true;
        }
        final retryAfterMs =
            int.tryParse(event.payload['retry_after_ms']?.toString() ?? '') ??
            30000;
        await getIt<RuntimeRecoveryService>().reportRateLimitWait(
          sessionId: sessionId,
          providerInstanceId:
              event.payload['provider_instance_id']?.toString() ??
              'e2e-provider',
          retryAfter: Duration(milliseconds: retryAfterMs),
          requestId: event.payload['request_id']?.toString(),
          limit: int.tryParse(
            event.payload['requests_per_minute']?.toString() ?? '',
          ),
        );
        return true;
    }
    return false;
  }

  Map<String, dynamic>? _decodeMessage(dynamic data) {
    try {
      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } else if (data is List<int>) {
        return _decodeMessage(utf8.decode(data));
      } else if (data is Map<String, dynamic>) {
        return data;
      } else if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      _logger.warning('Failed to decode local client message: $e');
    }
    return null;
  }

  Future<void> _sendAgentEventToSocket(
    WebSocket socket,
    Map<String, dynamic> envelope,
  ) async {
    final payload = {
      'message_type': envelope['type'],
      ..._withSocketIdentity(envelope, socket),
      'type': 'device_event',
    };
    final eventType = payload['event'] ?? payload['type'] ?? 'unknown';
    if (eventType == 'thought_stream' || eventType == 'reasoning_stream') {
      _logger.fine('⬆️ [ws] Sending device_event: $eventType');
    } else {
      _logger.info('⬆️ [ws] Sending device_event: $eventType');
    }
    _logger.fine('⬆️ [ws] Device event payload: $payload');
    await _sendToSocket(socket, payload);
  }

  Future<void> _sendToSocket(
    WebSocket socket,
    Map<String, dynamic> data,
  ) async {
    socket.add(jsonEncode(data));
  }

  Future<void> _broadcastAuthenticationExchange() async {
    const event = <String, dynamic>{'type': 'authentication_exchange'};
    for (final client in _clients.toList(growable: false)) {
      try {
        await _sendToSocket(client, event);
      } on Object {
        // Socket lifecycle cleanup owns disconnected clients.
      }
    }
  }

  Future<void> _writeJsonResponse(
    HttpResponse response,
    Map<String, dynamic> data, {
    int statusCode = HttpStatus.ok,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }

  Future<void> _writeAuthFailure(
    HttpResponse response,
    LocalGatewayAuthResult result,
  ) async {
    switch (result.outcome) {
      case LocalGatewayAuthOutcome.missingCredential:
        response.statusCode = HttpStatus.unauthorized;
        response.headers.set('WWW-Authenticate', 'Sanad realm="local-gateway"');
        await _writeJsonResponse(response, {
          'status': 'unauthorized',
          'reason': 'missing_credential',
        }, statusCode: HttpStatus.unauthorized);
        return;
      case LocalGatewayAuthOutcome.invalidCredential:
        await _writeJsonResponse(response, {
          'status': 'unauthorized',
          'reason': 'invalid_credential',
        }, statusCode: HttpStatus.unauthorized);
        return;
      case LocalGatewayAuthOutcome.peerRejected:
        await _writeJsonResponse(response, {
          'status': 'forbidden',
          'reason': 'peer_not_loopback',
        }, statusCode: HttpStatus.forbidden);
        return;
      case LocalGatewayAuthOutcome.hostRejected:
        await _writeJsonResponse(response, {
          'status': 'forbidden',
          'reason': 'host_not_allowed',
        }, statusCode: HttpStatus.forbidden);
        return;
      case LocalGatewayAuthOutcome.originRejected:
        await _writeJsonResponse(response, {
          'status': 'forbidden',
          'reason': 'origin_not_allowed',
        }, statusCode: HttpStatus.forbidden);
        return;
      case LocalGatewayAuthOutcome.budgetExhausted:
        response.statusCode = HttpStatus.tooManyRequests;
        response.headers.set('Retry-After', '30');
        await _writeJsonResponse(response, {
          'status': 'rate_limited',
          'reason': 'preauth_budget',
        }, statusCode: HttpStatus.tooManyRequests);
        return;
      case LocalGatewayAuthOutcome.ok:
        await _writeJsonResponse(response, {'status': 'ok'});
        return;
    }
  }

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    final canonicalEnvelope = _protocolBridge.buildAgentEventEnvelope(
      _protocolBridge.translateResponse(response),
    );
    final deviceId = _sessionDeviceIds[response.sessionId];
    final hardwareId = _sessionHardwareIds[response.sessionId];
    final envelope = {
      'message_type': canonicalEnvelope['type'],
      ..._withDeviceIdentity(
        canonicalEnvelope,
        deviceId: deviceId,
        hardwareId: hardwareId,
      ),
      'type': 'device_event',
    };

    final eventType =
        envelope['event'] ?? envelope['message_type'] ?? 'unknown';
    if (eventType == 'thought_stream' || eventType == 'reasoning_stream') {
      _logger.fine('⬆️ [ws] Sending device_event response: $eventType');
    } else {
      _logger.info('⬆️ [ws] Sending device_event response: $eventType');
    }
    _logger.fine('⬆️ [ws] Response payload: $envelope');

    // Phase 27 — delivery-aware local routing. The runtime sets the scope;
    // the platform resolves it to concrete sockets.
    final delivery = response.delivery;
    switch (delivery.scope) {
      case DeliveryScope.origin:
        final targetSocket = _sessionClients[response.sessionId];
        if (targetSocket != null) {
          await _sendToSocket(
            targetSocket,
            _withSocketIdentity(envelope, targetSocket),
          );
        } else {
          _logger.warning(
            '⬆️ [ws] origin delivery for session ${response.sessionId} '
            'has no bound socket (fail closed).',
          );
        }
      case DeliveryScope.platformFamily:
        // Fan out to every connected local Sanad Client socket.
        for (final client in _clients.toList()) {
          await _sendToSocket(client, _withSocketIdentity(envelope, client));
        }
      case DeliveryScope.hardware:
        final target = delivery.targetHardwareId;
        final matched = <WebSocket>{};
        for (final entry in _sessionHardwareIds.entries) {
          if (entry.value == target) {
            final socket = _sessionClients[entry.key];
            if (socket != null) matched.add(socket);
          }
        }
        if (matched.isEmpty) {
          _logger.warning(
            '⬆️ [ws] hardware delivery target=$target reached 0 sockets '
            '(fail closed).',
          );
        }
        for (final socket in matched) {
          await _sendToSocket(socket, _withSocketIdentity(envelope, socket));
        }
      case DeliveryScope.device:
        // App → daemon direction: not applicable on the local server platform
        // (this IS the daemon). No-op.
        _logger.fine('⬆️ [ws] device scope ignored on local daemon server.');
    }
  }

  void _acceptVoiceClient(WebSocket socket, String sessionId, String deviceId) {
    _logger.info(
      '🔌 [ws] Local voice client connected for session: $sessionId',
    );
    final channel = LocalWebSocketTransportChannel(socket);
    final provider = GeminiRealtimeVoiceProvider();
    final engine = VoiceEngine(
      channel: channel,
      provider: provider,
      sessionId: sessionId,
    );
    _voiceEngines.add(engine);

    unawaited(
      engine
          .start({'session_id': sessionId, 'device_id': deviceId})
          .catchError((Object err) {
            _logger.severe('Failed to start VoiceEngine: $err');
          })
          .whenComplete(() {
            _voiceEngines.remove(engine);
          }),
    );
  }

  @override
  Future<void> dispose() async {
    await _authChangeSubscription?.cancel();
    _authChangeSubscription = null;
    await _eventController.close();
    for (final client in _clients.toList()) {
      await client.close();
    }
    _clients.clear();
    _sessionClients.clear();
    _sessionDeviceIds.clear();
    _sessionHardwareIds.clear();
    _socketDeviceIds.clear();
    for (final engine in _voiceEngines.toList()) {
      await engine.close();
    }
    _voiceEngines.clear();
    await _server?.close(force: true);
  }

  Map<String, dynamic> _withCommandIdentity(
    Map<String, dynamic> envelope,
    Map<String, dynamic> commandEnvelope,
  ) {
    return _withDeviceIdentity(
      envelope,
      deviceId: commandEnvelope['device_id'] as String?,
      hardwareId: commandEnvelope['hardware_id'] as String?,
    );
  }

  void _rememberSocketIdentity(
    WebSocket socket,
    Map<String, dynamic> envelope,
  ) {
    final deviceId = envelope['device_id'] as String?;
    if (deviceId != null && deviceId.isNotEmpty) {
      _socketDeviceIds[socket] = deviceId;
    }
  }

  Map<String, dynamic> _withSocketIdentity(
    Map<String, dynamic> envelope,
    WebSocket socket,
  ) {
    return _withDeviceIdentity(envelope, deviceId: _socketDeviceIds[socket]);
  }

  Map<String, dynamic> _withDeviceIdentity(
    Map<String, dynamic> envelope, {
    String? deviceId,
    String? hardwareId,
  }) {
    final next = Map<String, dynamic>.from(envelope);
    if (deviceId != null && deviceId.isNotEmpty) {
      next['device_id'] = deviceId;
    }
    if (hardwareId != null && hardwareId.isNotEmpty) {
      next['hardware_id'] = hardwareId;
    }
    return next;
  }

  String? _findGitTopLevel(String startPath) {
    var dir = Directory(startPath);
    while (true) {
      final gitEntity = Directory('${dir.path}${Platform.pathSeparator}.git');
      final gitFile = File('${dir.path}${Platform.pathSeparator}.git');
      if (gitEntity.existsSync() || gitFile.existsSync()) {
        return dir.absolute.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  String _canonicalPath(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return Directory(path).absolute.path;
    }
  }

  int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  String _workspaceHash() {
    final gitTop = _findGitTopLevel(Directory.current.absolute.path);
    if (gitTop == null) return 'unknown';
    return _stableHash(
      _canonicalPath(gitTop),
    ).toRadixString(16).padLeft(8, '0').substring(0, 8);
  }
}
