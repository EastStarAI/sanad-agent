import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';

import 'support/agent_event_envelope.dart';

/// Owns the device-directed session-control commands that the gateway accepts
/// outside the session query, recovery, compact, fork, and replay handlers:
/// pending-steer cancel, queued-message delete, and the stop-recovery
/// acknowledgment and claim pair.
///
/// Dependencies are explicit constructor inputs; this owner never resolves a
/// runtime owner through the service locator.
class SessionControlCommandHandler {
  final SessionRunOrchestrator _orchestrator;
  final PersistedRuntimeStateRepository? _persistedState;

  SessionControlCommandHandler({
    required SessionRunOrchestrator orchestrator,
    PersistedRuntimeStateRepository? persistedState,
  }) : _orchestrator = orchestrator,
       _persistedState = persistedState;

  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    switch (event.type) {
      case CanonicalEventTypes.sessionPendingSteerCancel:
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final targetRequestId = event.payload['request_id']?.toString();
        final commandRequestId = event.payload['command_request_id']
            ?.toString();
        if (sessionId != null &&
            targetRequestId != null &&
            commandRequestId != null) {
          _orchestrator.cancelPendingSteer(
            sessionId: sessionId,
            targetRequestId: targetRequestId,
            commandRequestId: commandRequestId,
          );
        }
        return;
      case CanonicalEventTypes.sessionQueuedMessageDelete:
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final targetRequestId = event.payload['request_id']?.toString();
        final commandRequestId = event.payload['command_request_id']
            ?.toString();
        if (sessionId != null &&
            targetRequestId != null &&
            commandRequestId != null) {
          _orchestrator.deleteQueuedMessage(
            sessionId: sessionId,
            targetRequestId: targetRequestId,
            commandRequestId: commandRequestId,
          );
        }
        return;
      case CanonicalEventTypes.sessionStopRecoveryAck:
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final stopRequestId = event.payload['stop_request_id']?.toString();
        final claimantId =
            (event.payload['claimant_id'] ??
                    event.payload['command_request_id'])
                ?.toString();
        final recoveryOwnerToken = event.payload['recovery_owner_token']
            ?.toString();
        if (sessionId != null && stopRequestId != null) {
          _orchestrator.acknowledgeStopRecovery(
            sessionId,
            stopRequestId,
            claimantId: claimantId,
            recoveryOwnerToken: recoveryOwnerToken,
          );
        }
        return;
      case CanonicalEventTypes.sessionStopRecoveryClaim:
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final stopRequestId = event.payload['stop_request_id']?.toString();
        final commandRequestId = event.payload['command_request_id']
            ?.toString();
        final persistedState = _persistedState;
        if (sessionId != null &&
            stopRequestId != null &&
            commandRequestId != null &&
            persistedState != null) {
          final claimed = persistedState.pendingInputs.claimStopOutcome(
            sessionId: sessionId,
            stopRequestId: stopRequestId,
            claimantId: commandRequestId,
          );
          if (claimed != null) {
            await emitEnvelope(
              buildAgentEventEnvelope(
                CanonicalEvent(
                  type: CanonicalEventTypes.sessionStopDraftRecovery,
                  sessionId: sessionId,
                  payload: claimed.toPayload(),
                ),
              ),
            );
          }
        }
        return;
    }
  }
}
