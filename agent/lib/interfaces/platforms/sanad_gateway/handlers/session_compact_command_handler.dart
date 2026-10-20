import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';

import '../sanad_protocol_bridge.dart';

class SessionCompactCommandHandler {
  final SessionRunOrchestrator _orchestrator;
  final SanadProtocolBridge _bridge;

  SessionCompactCommandHandler({
    required SessionRunOrchestrator orchestrator,
    required SanadProtocolBridge bridge,
  }) : _orchestrator = orchestrator,
       _bridge = bridge;

  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString() ?? '';
    final requestId = event.payload['request_id']?.toString().trim() ?? '';

    if (sessionId.isEmpty || requestId.isEmpty) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'invalid_request',
        failureReason: 'invalid_request',
        failureStage: CompactionFailureStage.preparation,
        failureCause: CompactionFailureCause.invalidRequest,
      );
      return;
    }

    try {
      final result = await _orchestrator.handleCompactCommand(
        sessionId: sessionId,
        requestId: requestId,
      );
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        outcome: result['outcome']?.toString() ?? 'failed',
        failureReason: result['failure_reason']?.toString(),
        compactionId: result['compaction_id']?.toString(),
        failureStage: result['failure_stage']?.toString(),
        failureCause: result['failure_cause']?.toString(),
      );
    } catch (error) {
      final diagnostics = CompactionDiagnostics.classify(error);
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'failed',
        failureReason: diagnostics.failureReason.wireValue,
        failureStage: diagnostics.stage,
        failureCause: diagnostics.cause,
      );
    }
  }

  Future<void> _emitResult(
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope, {
    required String sessionId,
    required String requestId,
    required String outcome,
    String? failureReason,
    String? compactionId,
    String? failureStage,
    String? failureCause,
  }) {
    return emitEnvelope(
      _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionCompactResult,
          sessionId: sessionId,
          payload: {
            'session_id': sessionId,
            'request_id': requestId,
            'outcome': outcome,
            'failure_reason': ?failureReason,
            'compaction_id': ?compactionId,
            'failure_stage': ?failureStage,
            'failure_cause': ?failureCause,
          },
        ),
      ),
    );
  }
}
