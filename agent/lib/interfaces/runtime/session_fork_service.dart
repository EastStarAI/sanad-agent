import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

/// Daemon-authoritative materialized conversation fork.
class SessionForkService {
  final SessionManager _sessionManager;

  const SessionForkService({required SessionManager sessionManager})
    : _sessionManager = sessionManager;

  SessionForkCommit fork({
    required String sourceSessionId,
    required String requestId,
    required String targetMessageId,
    required String targetTurnId,
  }) {
    return _sessionManager.commitFork(
      sourceSessionId: sourceSessionId,
      requestId: requestId,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
    );
  }
}
