import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import 'session_metadata_resolver.dart';

/// Creates the durable row and the `session_created` projection of a session.
///
/// The first turn of a session both creates it and reports it to every client,
/// so this owner keeps that one projection complete: the title the turn starts
/// with, the model it routes to, and the targeting and permission mode it was
/// started with. Keeping it out of the run orchestrator means the projection and
/// the durable row can never be built from different inputs.
class SessionCreationProjector {
  const SessionCreationProjector({
    required SessionMetadataResolver metadataResolver,
    required void Function(GatewayResponse) emitResponse,
  }) : _metadataResolver = metadataResolver,
       _emitResponse = emitResponse;

  final SessionMetadataResolver _metadataResolver;
  final void Function(GatewayResponse) _emitResponse;

  /// Persists a new session for [turnRequest] and publishes its projection.
  ///
  /// Returns the created row so the caller can keep it as the title owner of
  /// the turn that created it.
  Future<SessionState> createAndPublish({
    required GatewayEvent event,
    required AgentTurnRequest turnRequest,
    required String? requestedWorkspaceId,
    required String? payloadModel,
  }) async {
    final sessionManager = getIt<SessionManager>();
    final initialTitle = _metadataResolver.resolveInitialSessionTitle(event);
    final sessionMetadata = await _metadataResolver.buildCreatedSessionMetadata(
      workspaceId: requestedWorkspaceId,
      turnRequest: turnRequest,
    );
    final now = DateTime.now();
    final session = SessionState(
      sessionId: event.sessionId,
      model: _resolveModel(payloadModel),
      providerId: turnRequest.effectiveProviderInstanceId,
      thinkingMode: turnRequest.thinkingMode,
      title: initialTitle.title,
      titleStatus: initialTitle.isPlaceholder
          ? SessionTitleStatus.pending
          : SessionTitleStatus.finalized,
      workspaceId: _metadataResolver.workspaceIdFromMetadata(
        sessionMetadata,
        fallback: requestedWorkspaceId,
      ),
      createdAt: now,
      updatedAt: now,
    );
    sessionManager.db.saveSession(session);
    if (sessionMetadata.isNotEmpty) {
      sessionManager.saveSessionMetadata(event.sessionId, sessionMetadata);
    }

    _emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.assistant,
          content: initialTitle.title,
        ),
        isSessionCreated: true,
        isComplete: true,
        runId: event.runId,
        sessionPayload: buildSessionPayload(
          session: session,
          sessionMetadata: sessionMetadata,
        ),
      ),
    );
    return session;
  }

  String _resolveModel(String? payloadModel) {
    if (payloadModel != null && payloadModel.isNotEmpty) {
      return payloadModel;
    }
    return getIt.isRegistered<Config>() ? getIt<Config>().llmModel : 'sanad-agent';
  }
}
