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
    required Future<void> Function(Map<String, dynamic> responseEnvelope)
    onResponse,
    Map<String, dynamic>? envelope,
  }) async {
    logger.info('⬇️ [$transportName] Received protocol_event: ${event.type}');
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
    required Future<void> Function(Map<String, dynamic> responseEnvelope)
    onResponse,
  }) async {
    final commandName = envelope['command']?.toString() ?? 'unknown';
    final origin = AuthenticatedCommandOrigin.fromEnvelope(envelope);
    logger.info(
      '⬇️ [$transportName] Received execute_command: $commandName '
      'from ${origin.safeDisplay}',
    );

    final rawPayload = envelope['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : <String, dynamic>{};
    if (commandName == CanonicalEventTypes.toolPermissionResponse ||
        commandName == CanonicalEventTypes.platformToolResult) {
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
