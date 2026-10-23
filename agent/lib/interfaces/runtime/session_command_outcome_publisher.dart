import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/models/pending_steer_record.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';

/// Shapes the canonical events a session command answers with and hands them to
/// the orchestrator's single response sink.
///
/// The publisher owns event shape only: it never reads or mutates admission,
/// active-run, queue, suspension, or compaction state. `SessionRunOrchestrator`
/// remains the one owner that decides whether a command is published at all, so
/// only the current non-invalidated owner can produce an outcome.
class SessionCommandOutcomePublisher {
  const SessionCommandOutcomePublisher({
    required void Function(GatewayResponse response) emit,
  }) : _emit = emit;

  final void Function(GatewayResponse response) _emit;

  void messageClassified(
    GatewayEvent event, {
    required String requestId,
    required String classification,
    DateTime? receivedAt,
  }) {
    _emit(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': 'session.message_classified',
            'canonical_payload': {
              'session_id': event.sessionId,
              'request_id': requestId,
              'classification': classification,
              if (receivedAt != null)
                'received_at': receivedAt.toUtc().toIso8601String(),
            },
          },
        ),
        isComplete: true,
        runId: event.runId,
      ),
    );
  }

  void pendingSteerChanged(String? platformId, PendingSteerRecord? record) {
    if (record == null) return;
    _emit(
      GatewayResponse(
        sessionId: record.sessionId,
        platformId: platformId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': 'session.pending_steer_changed',
            'canonical_payload': record.toPayload(),
          },
        ),
        isComplete: true,
        runId: record.runId,
      ),
    );
  }

  /// Emits the typed rejection for a `steer_only` command that found no live
  /// owner.
  ///
  /// A `steer_only` steer exists so a non-interactive caller can never turn a
  /// correction into a fresh turn or a queued turn. The rejection is correlated
  /// by the command's own `request_id` and names `no_active_turn`, the same code
  /// the CLI already reports for its own pre-check, so one code means one
  /// condition for every caller.
  void steerRejected({
    required GatewayEvent event,
    required String? requestId,
    required String code,
    required String message,
  }) {
    // The rejection is always published, even when the steer carries no request
    // id to correlate it with. A silent rejection would leave a caller waiting
    // for an answer that cannot arrive, and the text is still neither queued nor
    // admitted, so the outcome must be observable either way.
    _emit(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': 'error',
            'canonical_payload': {
              'session_id': event.sessionId,
              'request_id': ?requestId,
              'code': code,
              'message': message,
              'is_fatal': false,
            },
          },
        ),
        isComplete: true,
        runId: event.runId,
      ),
    );
  }

  void commandOutcome({
    required String sessionId,
    required String type,
    required String targetRequestId,
    required String commandRequestId,
    required String outcome,
  }) {
    _emit(
      GatewayResponse(
        sessionId: sessionId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': type,
            'canonical_payload': {
              'session_id': sessionId,
              'target_request_id': targetRequestId,
              'command_request_id': commandRequestId,
              'outcome': outcome,
            },
          },
        ),
        isComplete: true,
      ),
    );
  }

  static String wireName(String value) {
    return value.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => '_${match.group(0)!.toLowerCase()}',
    );
  }
}
