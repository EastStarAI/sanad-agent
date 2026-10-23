import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Canonical envelope construction shared by the protocol bridge and the
/// gateway command handlers.
///
/// Handlers call this owner instead of the bridge they are invoked from, so the
/// handler layer has no back-edge to `SanadProtocolBridge`.
Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) {
  final authManager = getIt<AuthManager>();
  final hardwareId = authManager.hardwareId ?? 'sanad-agent-local';

  final eventId = canonicalEvent.eventId ?? EventId.generate();
  final delivery =
      canonicalEvent.delivery ??
      DeliveryPolicy.origin(
        requestId: canonicalEvent.payload['request_id']?.toString(),
      );

  return {
    'device_id': hardwareId,
    'hardware_id': hardwareId,
    'type': 'event',
    'event': canonicalEvent.type,
    'payload': canonicalEvent.payload,
    if (canonicalEvent.sessionId != null)
      'session_id': canonicalEvent.sessionId,
    if (canonicalEvent.runId != null) 'run_id': canonicalEvent.runId,
    if (canonicalEvent.payload['request_id'] != null)
      'request_id': canonicalEvent.payload['request_id'],
    'event_id': eventId,
    'delivery': delivery.toJson(),
  };
}

/// Failure envelope for a gateway command whose owner raised [error].
Map<String, dynamic> buildCommandMutationErrorEnvelope({
  required String? requestId,
  required String action,
  required Object error,
}) {
  return buildAgentEventEnvelope(
    CanonicalEvent(
      type: 'error',
      payload: {
        'request_id': requestId,
        if (error is WorkspaceCommandException) 'code': error.code,
        'message': 'Failed to $action: ${commandErrorMessage(error)}',
      },
    ),
  );
}

/// The secrets-safe message of a command failure.
String commandErrorMessage(Object error) {
  final raw = switch (error) {
    WorkspaceCommandException() => error.message,
    StateError() => error.message,
    FormatException() => error.message,
    FileSystemException() => error.message,
    _ => error.toString(),
  };
  return const SecretsRedactor().redact(raw);
}
