import 'dart:async';

import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_session_channel.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';

typedef PermissionRequestHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> payload);
typedef PlatformToolExecutionHandler =
    Future<String> Function(Map<String, dynamic> payload);
typedef SessionResponseEmitter =
    Future<void> Function(GatewayResponse response);
typedef RuntimeResponseSink = void Function(GatewayResponse response);

class PlatformRuntimeBridge {
  static const int _resolvedPermissionRetention = 256;
  final Map<String, PlatformSessionChannel> _sessionChannels = {};
  final Map<String, String> _sessionDeviceIds = {};
  final Map<String, PermissionRequestHandler> _permissionHandlers = {};
  final Map<String, PlatformToolExecutionHandler> _platformToolHandlers = {};
  final Map<String, SessionResponseEmitter> _sessionResponseEmitters = {};
  final Map<String, Completer<Map<String, dynamic>>>
  _pendingPermissionRequests = {};
  final Map<String, Map<String, dynamic>> _resolvedPermissionRequests = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingToolCalls = {};
  final Map<String, OriginContext> _sessionOrigins = {};
  RuntimeResponseSink? _responseSink;

  void attachResponseSink(RuntimeResponseSink sink) {
    _responseSink = sink;
  }

  void detachResponseSink() {
    _responseSink = null;
  }

  void registerSessionOrigin(String sessionId, OriginContext origin) {
    _sessionOrigins[sessionId] = origin;
  }

  void registerSessionHandlers(
    String sessionId, {
    PermissionRequestHandler? permissionHandler,
    PlatformToolExecutionHandler? platformToolHandler,
    SessionResponseEmitter? responseEmitter,
  }) {
    if (permissionHandler != null) {
      _permissionHandlers[sessionId] = permissionHandler;
    }
    if (platformToolHandler != null) {
      _platformToolHandlers[sessionId] = platformToolHandler;
    }
    if (responseEmitter != null) {
      _sessionResponseEmitters[sessionId] = responseEmitter;
    }
  }

  void unregisterSession(String sessionId) {
    _sessionChannels.remove(sessionId);
    _sessionDeviceIds.remove(sessionId);
    _permissionHandlers.remove(sessionId);
    _platformToolHandlers.remove(sessionId);
    _sessionResponseEmitters.remove(sessionId);
    _sessionOrigins.remove(sessionId);
  }

  void registerSessionClient(
    String sessionId,
    PlatformSessionChannel channel, {
    String? deviceId,
  }) {
    _sessionChannels[sessionId] = channel;
    if (deviceId != null && deviceId.isNotEmpty) {
      _sessionDeviceIds[sessionId] = deviceId;
    }
  }

  void unregisterChannel(PlatformSessionChannel channel) {
    final sessionIds = _sessionChannels.entries
        .where((entry) => entry.value == channel)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final sessionId in sessionIds) {
      _sessionChannels.remove(sessionId);
      _sessionDeviceIds.remove(sessionId);
    }
  }

  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final localHandler = _permissionHandlers[sessionId];
    if (localHandler != null && !_sessionChannels.containsKey(sessionId)) {
      return localHandler(payload);
    }

    final requestId =
        payload['request_id']?.toString() ?? _nextRequestId('permission');
    final completer = Completer<Map<String, dynamic>>();
    _pendingPermissionRequests[requestId] = completer;

    final origin = _sessionOrigins[sessionId];
    final delivery = _deliveryForOrigin(origin, requestId: requestId);
    await _emitRuntimeEvent(
      sessionId: sessionId,
      eventType: CanonicalEventTypes.toolPermissionRequest,
      payload: {...payload, 'request_id': requestId, 'session_id': sessionId},
      delivery: delivery,
      origin: origin,
    );

    try {
      final decision = await completer.future;
      await _emitPermissionResolution(
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'resolved',
        delivery: delivery,
        origin: origin,
      );
      return decision;
    } finally {
      _pendingPermissionRequests.remove(requestId);
    }
  }

  Future<String> executePlatformTool({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final localHandler = _platformToolHandlers[sessionId];
    if (localHandler != null && !_sessionChannels.containsKey(sessionId)) {
      return localHandler(payload);
    }

    final requestId =
        payload['request_id']?.toString() ?? _nextRequestId('platform-tool');
    final completer = Completer<Map<String, dynamic>>();
    _pendingToolCalls[requestId] = completer;

    // Phase 27: platform tools target a single qualified hardware id with no
    // fallback to family broadcast.
    final targetHardwareId = payload['target_hardware_id']?.toString();
    final toolDelivery = targetHardwareId == null
        ? const DeliveryPolicy.platformFamily(PlatformFamily.sanadClient)
        : DeliveryPolicy.hardware(targetHardwareId: targetHardwareId);

    await _sendProtocolEvent(
      sessionId: sessionId,
      eventType: CanonicalEventTypes.platformToolCall,
      payload: {
        ...payload,
        'request_id': requestId,
        'session_id': sessionId,
        'event_id': EventId.generate(),
        'delivery': toolDelivery.toJson(),
      },
    );

    try {
      final response = await completer.future.timeout(timeout);
      final isError = response['is_error'] == true;
      final output = response['output']?.toString() ?? '';
      if (isError) {
        throw Exception(
          output.isEmpty ? 'Platform tool execution failed.' : output,
        );
      }
      return output;
    } finally {
      _pendingToolCalls.remove(requestId);
    }
  }

  bool handleProtocolEvent(CanonicalEvent event) {
    switch (event.type) {
      case CanonicalEventTypes.toolPermissionResponse:
        final requestId = event.payload['request_id']?.toString();
        if (requestId == null) {
          return true;
        }
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final completer = _pendingPermissionRequests.remove(requestId);
        if (completer != null) {
          _rememberPermissionResolution(requestId, event.payload);
          completer.complete(event.payload);
          return true;
        }
        if (_resolvedPermissionRequests.containsKey(requestId)) {
          if (sessionId != null && sessionId.isNotEmpty) {
            final origin = _sessionOrigins[sessionId];
            unawaited(
              _emitPermissionResolution(
                sessionId: sessionId,
                requestId: requestId,
                outcome: 'already_resolved',
                delivery: _deliveryForOrigin(origin, requestId: requestId),
                origin: origin,
              ),
            );
          }
          return true;
        }
        final sink = _responseSink;
        final emitter = sessionId == null
            ? null
            : _sessionResponseEmitters[sessionId] ??
                  (sink == null
                      ? null
                      : (GatewayResponse response) async => sink(response));
        final resumeService = getIt.isRegistered<SuspendedResumeService>()
            ? getIt<SuspendedResumeService>()
            : null;
        if (sessionId != null && resumeService != null && emitter != null) {
          unawaited(
            _resumePersistedPermission(
              resumeService: resumeService,
              emitter: emitter,
              sessionId: sessionId,
              requestId: requestId,
              decision: event.payload,
            ),
          );
        }
        return true;
      case CanonicalEventTypes.platformToolResult:
        final requestId = event.payload['request_id']?.toString();
        if (requestId == null) {
          return true;
        }
        _pendingToolCalls.remove(requestId)?.complete(event.payload);
        return true;
      default:
        return false;
    }
  }

  Future<void> _resumePersistedPermission({
    required SuspendedResumeService resumeService,
    required SessionResponseEmitter emitter,
    required String sessionId,
    required String requestId,
    required Map<String, dynamic> decision,
  }) async {
    final origin = _sessionOrigins[sessionId];
    final delivery = _deliveryForOrigin(origin, requestId: requestId);
    final resumed = await resumeService.resumeFromDecision(
      requestId: requestId,
      decision: decision,
      emitResponse: emitter,
      onClaimed: () async {
        _rememberPermissionResolution(requestId, decision);
        await _emitPermissionResolution(
          sessionId: sessionId,
          requestId: requestId,
          outcome: 'resolved',
          delivery: delivery,
          origin: origin,
        );
      },
    );
    if (!resumed) {
      await _emitPermissionResolution(
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'already_resolved',
        delivery: delivery,
        origin: origin,
      );
    }
  }

  DeliveryPolicy _deliveryForOrigin(
    OriginContext? origin, {
    required String requestId,
  }) {
    if (origin == null || origin.platformFamily == PlatformFamily.sanadClient) {
      return const DeliveryPolicy.platformFamily(PlatformFamily.sanadClient);
    }
    return DeliveryPolicy.origin(requestId: requestId, routeId: origin.routeId);
  }

  Future<void> _emitPermissionResolution({
    required String sessionId,
    required String requestId,
    required String outcome,
    required DeliveryPolicy delivery,
    required OriginContext? origin,
  }) => _emitRuntimeEvent(
    sessionId: sessionId,
    eventType: CanonicalEventTypes.toolPermissionResolved,
    payload: {
      'session_id': sessionId,
      'request_id': requestId,
      'outcome': outcome,
    },
    delivery: delivery,
    origin: origin,
  );

  void _rememberPermissionResolution(
    String requestId,
    Map<String, dynamic> decision,
  ) {
    _resolvedPermissionRequests[requestId] = Map.unmodifiable(decision);
    while (_resolvedPermissionRequests.length > _resolvedPermissionRetention) {
      _resolvedPermissionRequests.remove(
        _resolvedPermissionRequests.keys.first,
      );
    }
  }

  Future<void> _emitRuntimeEvent({
    required String sessionId,
    required String eventType,
    required Map<String, dynamic> payload,
    required DeliveryPolicy delivery,
    required OriginContext? origin,
  }) async {
    final eventId = EventId.generate();
    final response = GatewayResponse(
      sessionId: sessionId,
      platformId: origin?.platformId,
      eventId: eventId,
      origin: origin,
      delivery: delivery,
      message: Message(
        role: MessageRole.assistant,
        metadata: {
          'canonical_event_type': eventType,
          'canonical_payload': payload,
        },
      ),
    );
    final sink = _responseSink;
    if (sink != null) {
      sink(response);
      return;
    }
    final emitter = _sessionResponseEmitters[sessionId];
    if (emitter != null) {
      await emitter(response);
      return;
    }

    await _sendProtocolEvent(
      sessionId: sessionId,
      eventType: eventType,
      payload: {...payload, 'event_id': eventId, 'delivery': delivery.toJson()},
    );
  }

  Future<void> _sendProtocolEvent({
    required String sessionId,
    required String eventType,
    required Map<String, dynamic> payload,
  }) async {
    final channel = _sessionChannels[sessionId];
    if (channel == null) {
      throw StateError(
        'No local platform client is attached to session $sessionId.',
      );
    }

    await channel.sendProtocolEvent(eventType, {
      ...payload,
      if (_sessionDeviceIds[sessionId] != null)
        'device_id': _sessionDeviceIds[sessionId],
      'session_id': sessionId,
    });
  }

  String _nextRequestId(String prefix) {
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}';
  }
}
