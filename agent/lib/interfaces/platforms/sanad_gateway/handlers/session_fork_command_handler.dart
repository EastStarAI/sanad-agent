import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_fork_service.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import '../sanad_protocol_bridge.dart';

class SessionForkCommandHandler {
  final SessionManager _sessionManager;
  final SanadProtocolBridge _bridge;
  final SessionForkService _fork;

  SessionForkCommandHandler({
    required SessionManager sessionManager,
    required SanadProtocolBridge bridge,
    SessionForkService? fork,
  }) : _sessionManager = sessionManager,
       _bridge = bridge,
       _fork = fork ?? SessionForkService(sessionManager: sessionManager);

  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString() ?? '';
    final requestId = event.payload['request_id']?.toString().trim() ?? '';
    final targetMessageId =
        event.payload['target_message_id']?.toString().trim() ?? '';
    final targetTurnId =
        event.payload['target_turn_id']?.toString().trim() ?? '';

    if (sessionId.isEmpty ||
        requestId.isEmpty ||
        targetMessageId.isEmpty ||
        targetTurnId.isEmpty) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        outcome: SessionForkOutcome.invalidRequest,
      );
      return;
    }

    final result = _fork.fork(
      sourceSessionId: sessionId,
      requestId: requestId,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
    );
    await _emitResult(
      emitEnvelope,
      sessionId: sessionId,
      requestId: requestId,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
      outcome: result.outcome,
      child: result.child,
    );
  }

  Future<void> _emitResult(
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope, {
    required String sessionId,
    required String requestId,
    required String targetMessageId,
    required String targetTurnId,
    required SessionForkOutcome outcome,
    SessionState? child,
  }) {
    return emitEnvelope(
      _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionForkResult,
          sessionId: child?.sessionId ?? sessionId,
          payload: {
            'session_id': sessionId,
            'request_id': requestId,
            'target_message_id': targetMessageId,
            'target_turn_id': targetTurnId,
            'outcome': _outcomeName(outcome),
            if (child != null) ...{
              'child': buildSessionPayload(
                session: child,
                sessionMetadata: _sessionManager.getSessionMetadata(
                  child.sessionId,
                ),
              ),
              'lineage_id': child.lineageId,
              'parent_session_id': child.parentSessionId,
              'forked_from_message_id': child.forkedFromMessageId,
              'forked_from_turn_id': child.forkedFromTurnId,
              'fork_sequence': child.forkSequence,
            },
          },
        ),
      ),
    );
  }

  static String _outcomeName(SessionForkOutcome outcome) => switch (outcome) {
    SessionForkOutcome.accepted => 'accepted',
    SessionForkOutcome.alreadyExists => 'already_exists',
    SessionForkOutcome.targetNotFound => 'target_not_found',
    SessionForkOutcome.sessionNotFound => 'session_not_found',
    SessionForkOutcome.targetNotForkable => 'target_not_forkable',
    SessionForkOutcome.invalidRequest => 'invalid_request',
    SessionForkOutcome.failed => 'failed',
  };
}
