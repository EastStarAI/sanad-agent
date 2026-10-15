import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'sanad_protocol_bridge.dart';
import 'protocol/authenticated_command_origin.dart';
import 'protocol/canonical_events.dart';

/// A mixin that provides shared behavior for Sanad Gateway platforms
/// (both local daemon server and cloud gateway).
mixin SanadGatewayBehavior {
  Logger get logger;
  SanadProtocolBridge get protocolBridge;

  /// The transport name used in logs (e.g. 'ws' or 'socket').
  String get transportName;

  /// Common logic to process an incoming protocol event.
  Future<void> handleIncomingProtocolEvent({
    required CanonicalEvent event,
    required PlatformRuntimeBridge runtimeBridge,
    required Future<void> Function(Map<String, dynamic>) onResponse,
    Map<String, dynamic>? envelope,
    AuthenticatedCommandOrigin? authenticatedOrigin,
  }) async {
    final origin =
        authenticatedOrigin ??
        (envelope != null
            ? AuthenticatedCommandOrigin.fromEnvelope(envelope)
            : null);
    final tag = origin?.displayTag ?? transportName;
    logger.info('⬇️ [$tag] Received protocol_event: ${event.type}');
    if (envelope != null) {
      logFinePayload('⬇️ [$tag] Protocol event payload:', envelope);
    }
    if (runtimeBridge.handleProtocolEvent(event)) {
      return;
    }
    await protocolBridge.handleProtocolEvent(event, onResponse);
  }

  /// Common logic to process an incoming command.
  /// Returns `true` if the command was handled internally by the protocol bridge.
  Future<bool> handleIncomingCommand({
    required Map<String, dynamic> envelope,
    required PlatformRuntimeBridge runtimeBridge,
    required Future<void> Function(Map<String, dynamic>) onResponse,
    AuthenticatedCommandOrigin? authenticatedOrigin,
  }) async {
    final commandName = envelope['command']?.toString() ?? 'unknown';
    final origin =
        authenticatedOrigin ??
        AuthenticatedCommandOrigin.fromEnvelope(envelope);
    final tag = origin.displayTag;
    logger.info('⬇️ [$tag] Received execute_command: $commandName');
    logFinePayload('⬇️ [$tag] Command payload:', envelope);

    final rawPayload = envelope['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : <String, dynamic>{};
    if (commandName == CanonicalEventTypes.toolPermissionResponse) {
      final result = await runtimeBridge.handlePermissionResponse(
        CanonicalEvent(
          type: commandName,
          sessionId: payload['session_id']?.toString(),
          payload: payload,
        ),
      );
      final rpcRequestId = envelope['request_id']?.toString();
      if (rpcRequestId != null && rpcRequestId.isNotEmpty) {
        if (result.isSuccess) {
          await onResponse({
            'type': 'event',
            'event': CanonicalEventTypes.toolPermissionResolved,
            'request_id': rpcRequestId,
            'payload': {
              'request_id': rpcRequestId,
              'session_id': payload['session_id'],
              'permission_request_id': payload['request_id'],
              'success': true,
              'outcome': result.outcome,
            },
          });
        } else {
          await onResponse({
            'type': 'error',
            'request_id': rpcRequestId,
            'payload': {
              'request_id': rpcRequestId,
              'code': result.errorCode,
              'message': result.errorMessage,
              'outcome': result.outcome,
            },
          });
        }
      }
      return true;
    }
    if (commandName == CanonicalEventTypes.platformToolResult) {
      return runtimeBridge.handleProtocolEvent(
        CanonicalEvent(
          type: commandName,
          sessionId: payload['session_id']?.toString(),
          payload: payload,
        ),
      );
    }
    return protocolBridge.handleCommand(envelope, onResponse);
  }

  /// Logs only bounded structural metadata;payload values never enter logs.
  void logFinePayload(String label, Object? payload) {
    final fieldCount = payload is Map ? payload.length : 0;
    logger.fine('$label field_count=$fieldCount');
  }

  /// Safely converts dynamic map-like data into a structured `Map<String, dynamic>`.
  Map<String, dynamic> toMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }
}
