import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/runtime/llm_route_snapshot.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

/// Decides and publishes the post-terminal intelligent title of a session.
///
/// `SessionTurnExecutor` still owns terminal delivery, run ownership, and the
/// per-session in-flight title guard; this owner answers whether a title is due
/// for a finished turn and performs the generation and publication it was
/// scheduled for.
class SessionTitleRefresher {
  static final Logger _logger = Logger('SessionTitleRefresher');

  final void Function(GatewayResponse) emitResponse;

  const SessionTitleRefresher({required this.emitResponse});

  bool shouldGenerateIntelligentTitle({
    required bool isNewSession,
    required SessionState? existingSession,
    required SessionState? currentSession,
  }) {
    if (currentSession != null) {
      return currentSession.titleStatus == SessionTitleStatus.pending;
    }
    if (existingSession != null) {
      return existingSession.titleStatus == SessionTitleStatus.pending;
    }
    return isNewSession;
  }

  Future<void> generateAndEmitIntelligentTitle({
    required String sessionId,
    required String platformId,
    required String? expectedTitle,
    required String userMessage,
    required String assistantResponse,
    required LLMRouteSnapshot? route,
    String? runId,
  }) async {
    try {
      final titleService = getIt<TitleService>();
      final newTitle = await titleService.generateTitle(
        sessionId: sessionId,
        userMessage: userMessage,
        assistantResponse: assistantResponse,
        route: route,
      );

      final sessionManager = getIt<SessionManager>();
      final updated = sessionManager.updateSessionTitleIfCurrent(
        sessionId,
        expectedTitle: expectedTitle,
        title: newTitle,
      );
      if (!updated) {
        _logger.fine('Discarded stale generated title for session $sessionId.');
        return;
      }

      final updatedSession = sessionManager.getSession(sessionId);
      emitResponse(
        GatewayResponse(
          sessionId: sessionId,
          platformId: platformId,
          message: Message(role: MessageRole.assistant, content: newTitle),
          isSessionUpdated: true,
          isComplete: true,
          runId: runId,
          sessionPayload: updatedSession != null
              ? buildSessionPayload(
                  session: updatedSession,
                  sessionMetadata: sessionManager.getSessionMetadata(sessionId),
                )
              : null,
        ),
      );
    } catch (e) {
      _logger.warning('Failed to generate and emit intelligent title: $e');
    }
  }
}
