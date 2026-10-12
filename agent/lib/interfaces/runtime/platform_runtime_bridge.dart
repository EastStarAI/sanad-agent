import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_session_channel.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';

typedef PermissionRequestHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> payload);
typedef PlatformToolExecutionHandler =
    Future<String> Function(Map<String, dynamic> payload);
typedef SessionResponseEmitter =
    Future<void> Function(GatewayResponse response);
typedef RuntimeResponseSink = void Function(GatewayResponse response);

class PendingPermissionEntry {
  final Completer<Map<String, dynamic>> completer;
  final String sessionId;
  final String requestId;
  final String toolName;
  final Map<String, dynamic> payload;

  const PendingPermissionEntry({
    required this.completer,
    required this.sessionId,
    required this.requestId,
    required this.toolName,
    required this.payload,
  });

  bool get isUserQuestion =>
      toolName == 'system_ask_user' ||
      (payload['questions'] is List &&
          (payload['questions'] as List).isNotEmpty);
}

class PermissionDecisionOutcome {
  final bool isSuccess;
  final String outcome;
  final String? errorCode;
  final String? errorMessage;

  const PermissionDecisionOutcome.success({this.outcome = 'resolved'})
    : isSuccess = true,
      errorCode = null,
      errorMessage = null;

  const PermissionDecisionOutcome.failure({
    required this.outcome,
    required this.errorCode,
    required this.errorMessage,
  }) : isSuccess = false;
}

class ResolvedPermissionRecord {
  final String sessionId;
  final Map<String, dynamic> decision;
  final DateTime resolvedAt;

  ResolvedPermissionRecord({
    required this.sessionId,
    required this.decision,
    DateTime? resolvedAt,
  }) : resolvedAt = resolvedAt ?? DateTime.now();
}

class PlatformRuntimeBridge {
  static final Logger _logger = Logger('PlatformRuntimeBridge');
  static const int _resolvedPermissionRetention = 256;
  final Map<String, PlatformSessionChannel> _sessionChannels = {};
  final Map<String, String> _sessionDeviceIds = {};
  final Map<String, PermissionRequestHandler> _permissionHandlers = {};
  final Map<String, PlatformToolExecutionHandler> _platformToolHandlers = {};
  final Map<String, SessionResponseEmitter> _sessionResponseEmitters = {};
  final Map<String, PendingPermissionEntry> _pendingPermissionRequests = {};
  final Map<String, ResolvedPermissionRecord> _resolvedPermissionRequests = {};
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
    _pendingPermissionRequests[requestId] = PendingPermissionEntry(
      completer: completer,
      sessionId: sessionId,
      requestId: requestId,
      toolName: payload['tool_name']?.toString() ?? '',
      payload: Map<String, dynamic>.from(payload),
    );

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
        unawaited(handlePermissionResponse(event));
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

  PermissionDecisionOutcome? _validateToolDecision(
    Map<String, dynamic> payload,
  ) {
    if (payload.containsKey('answer')) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'wrong_kind',
        errorCode: 'INVALID_INTERVENTION_KIND',
        errorMessage:
            'Cannot submit an answer to an ordinary tool permission request.',
      );
    }

    final hasAllowed = payload.containsKey('allowed');
    final hasDecision = payload.containsKey('decision');

    if (!hasAllowed && !hasDecision) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'wrong_kind',
        errorCode: 'INVALID_DECISION',
        errorMessage:
            'Request is a tool permission and requires an allow or deny decision.',
      );
    }

    bool? allowed;
    if (hasAllowed) {
      final rawAllowed = payload['allowed'];
      if (rawAllowed is! bool) {
        return const PermissionDecisionOutcome.failure(
          outcome: 'invalid_decision',
          errorCode: 'MALFORMED_DECISION',
          errorMessage: 'The "allowed" field must be a boolean.',
        );
      }
      allowed = rawAllowed;
    }

    String? decision;
    if (hasDecision) {
      final rawDecision = payload['decision']?.toString().toLowerCase().trim();
      if (rawDecision != 'allow' && rawDecision != 'deny') {
        return const PermissionDecisionOutcome.failure(
          outcome: 'invalid_decision',
          errorCode: 'MALFORMED_DECISION',
          errorMessage:
              'The "decision" field must be either "allow" or "deny".',
        );
      }
      decision = rawDecision;
    }

    if (allowed != null && decision != null) {
      final decisionAllowed = decision == 'allow';
      if (allowed != decisionAllowed) {
        return PermissionDecisionOutcome.failure(
          outcome: 'invalid_decision',
          errorCode: 'CONTRADICTORY_DECISION',
          errorMessage:
              'Contradictory decision: "allowed" is $allowed but "decision" is "$decision".',
        );
      }
    }

    return null;
  }

  PermissionDecisionOutcome? _validateClarificationDecision(
    Map<String, dynamic> payload,
  ) {
    if (!payload.containsKey('answer')) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'wrong_kind',
        errorCode: 'INVALID_ANSWER',
        errorMessage:
            'Request is a clarification question and requires a non-empty answer.',
      );
    }
    final rawAnswer = payload['answer'];
    if (rawAnswer == null) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'wrong_kind',
        errorCode: 'INVALID_ANSWER',
        errorMessage:
            'Request is a clarification question and requires a non-empty answer.',
      );
    }
    final answer = rawAnswer.toString().trim();
    if (answer.isEmpty) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'wrong_kind',
        errorCode: 'INVALID_ANSWER',
        errorMessage:
            'Request is a clarification question and requires a non-empty answer.',
      );
    }
    return null;
  }

  /// Processes an incoming permission or clarification decision with strict
  /// identity and kind validation. Stale, duplicate, cross-session, or wrong-kind
  /// responses fail closed without consuming the pending request.
  Future<PermissionDecisionOutcome> handlePermissionResponse(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id']?.toString();
    if (requestId == null || requestId.isEmpty) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'invalid_request',
        errorCode: 'MISSING_REQUEST_ID',
        errorMessage: 'request_id is required.',
      );
    }
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString();
    if (sessionId == null || sessionId.isEmpty) {
      return const PermissionDecisionOutcome.failure(
        outcome: 'invalid_request',
        errorCode: 'MISSING_SESSION_ID',
        errorMessage: 'session_id is required.',
      );
    }

    final pending = _pendingPermissionRequests[requestId];
    if (pending != null) {
      // 1. Cross-session validation
      if (pending.sessionId != sessionId) {
        _logger.warning(
          'Cross-session permission response rejected: request $requestId belongs to '
          '${pending.sessionId}, got $sessionId',
        );
        return PermissionDecisionOutcome.failure(
          outcome: 'cross_session_mismatch',
          errorCode: 'CROSS_SESSION_MISMATCH',
          errorMessage:
              'Request $requestId belongs to session ${pending.sessionId}, not $sessionId.',
        );
      }

      // 2. Kind and consistency validation
      final kindFailure = pending.isUserQuestion
          ? _validateClarificationDecision(event.payload)
          : _validateToolDecision(event.payload);
      if (kindFailure != null) {
        _logger.warning(
          'Validation failed for request $requestId: ${kindFailure.errorMessage}',
        );
        return kindFailure;
      }

      // Validation passed: consume the pending request and complete it
      _pendingPermissionRequests.remove(requestId);
      _rememberPermissionResolution(
        requestId,
        event.payload,
        sessionId: sessionId,
      );
      pending.completer.complete(event.payload);
      return const PermissionDecisionOutcome.success();
    }

    // 3. Stale / Already-resolved check (with cross-session preservation)
    final resolved = _resolvedPermissionRequests[requestId];
    if (resolved != null) {
      if (resolved.sessionId != sessionId) {
        _logger.warning(
          'Cross-session resolved permission response rejected: request $requestId was resolved for '
          '${resolved.sessionId}, got $sessionId',
        );
        return PermissionDecisionOutcome.failure(
          outcome: 'cross_session_mismatch',
          errorCode: 'CROSS_SESSION_MISMATCH',
          errorMessage:
              'Request $requestId belongs to session ${resolved.sessionId}, not $sessionId.',
        );
      }

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
      return PermissionDecisionOutcome.failure(
        outcome: 'already_resolved',
        errorCode: 'ALREADY_RESOLVED',
        errorMessage: 'Request $requestId has already been resolved.',
      );
    }

    // 4. Suspended checkpoint in SuspendedResumeService
    final resumeService = getIt.isRegistered<SuspendedResumeService>()
        ? getIt<SuspendedResumeService>()
        : null;
    final checkpointStore = getIt.isRegistered<SuspendedCheckpointStore>()
        ? getIt<SuspendedCheckpointStore>()
        : null;

    if (checkpointStore != null) {
      final checkpoint = await checkpointStore.getByRequestId(requestId);
      if (checkpoint == null) {
        return PermissionDecisionOutcome.failure(
          outcome: 'not_found',
          errorCode: 'REQUEST_NOT_FOUND',
          errorMessage: 'No pending request found with id $requestId.',
        );
      }

      if (checkpoint.sessionId != sessionId) {
        _logger.warning(
          'Cross-session suspended permission response rejected: request $requestId belongs to '
          '${checkpoint.sessionId}, got $sessionId',
        );
        return PermissionDecisionOutcome.failure(
          outcome: 'cross_session_mismatch',
          errorCode: 'CROSS_SESSION_MISMATCH',
          errorMessage:
              'Request $requestId belongs to session ${checkpoint.sessionId}, not $sessionId.',
        );
      }

      if (checkpoint.status != 'awaiting_permission') {
        return PermissionDecisionOutcome.failure(
          outcome: 'already_resolved',
          errorCode: 'ALREADY_RESOLVED',
          errorMessage:
              'Request $requestId is in status ${checkpoint.status} and cannot be resolved.',
        );
      }

      final isAskUser = checkpoint.toolName == 'system_ask_user';
      final kindFailure = isAskUser
          ? _validateClarificationDecision(event.payload)
          : _validateToolDecision(event.payload);
      if (kindFailure != null) {
        return kindFailure;
      }
    }

    final sink = _responseSink;
    final emitter =
        _sessionResponseEmitters[sessionId] ??
        (sink == null
            ? null
            : (GatewayResponse response) async => sink(response));

    if (resumeService != null && emitter != null) {
      final claimCompleter = Completer<PermissionDecisionOutcome>();
      unawaited(
        _resumePersistedPermission(
          resumeService: resumeService,
          emitter: emitter,
          sessionId: sessionId,
          requestId: requestId,
          decision: event.payload,
          onClaimSuccess: () {
            if (!claimCompleter.isCompleted) {
              claimCompleter.complete(
                const PermissionDecisionOutcome.success(),
              );
            }
          },
          onClaimFailure: (outcome) {
            if (!claimCompleter.isCompleted) {
              claimCompleter.complete(outcome);
            }
          },
        ),
      );
      return await claimCompleter.future;
    }

    return PermissionDecisionOutcome.failure(
      outcome: 'not_found',
      errorCode: 'REQUEST_NOT_FOUND',
      errorMessage: 'No pending request found with id $requestId.',
    );
  }

  Future<void> _resumePersistedPermission({
    required SuspendedResumeService resumeService,
    required SessionResponseEmitter emitter,
    required String sessionId,
    required String requestId,
    required Map<String, dynamic> decision,
    required void Function() onClaimSuccess,
    required void Function(PermissionDecisionOutcome outcome) onClaimFailure,
  }) async {
    final origin = _sessionOrigins[sessionId];
    final delivery = _deliveryForOrigin(origin, requestId: requestId);
    try {
      final resumed = await resumeService.resumeFromDecision(
        requestId: requestId,
        decision: decision,
        emitResponse: emitter,
        onClaimed: () async {
          _rememberPermissionResolution(
            requestId,
            decision,
            sessionId: sessionId,
          );
          onClaimSuccess();
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
        onClaimFailure(
          const PermissionDecisionOutcome.failure(
            outcome: 'already_resolved',
            errorCode: 'ALREADY_RESOLVED',
            errorMessage:
                'Request was already resolved or could not be claimed.',
          ),
        );
        await _emitPermissionResolution(
          sessionId: sessionId,
          requestId: requestId,
          outcome: 'already_resolved',
          delivery: delivery,
          origin: origin,
        );
      }
    } catch (e) {
      onClaimFailure(
        PermissionDecisionOutcome.failure(
          outcome: 'error',
          errorCode: 'RESUME_FAILED',
          errorMessage: 'Failed to resume decision for request $requestId: $e',
        ),
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
    Map<String, dynamic> decision, {
    required String sessionId,
  }) {
    _resolvedPermissionRequests[requestId] = ResolvedPermissionRecord(
      sessionId: sessionId,
      decision: Map.unmodifiable(decision),
    );
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
