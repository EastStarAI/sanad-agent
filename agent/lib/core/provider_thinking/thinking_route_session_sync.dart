/// Applies route-bound thinking revalidation to session and turn state (Task 43 Gate D).
library;

import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';

class ThinkingRouteSessionSync {
  final ThinkingRouteRevalidator _revalidator;
  final ThinkingRoutePreferenceStore _store;
  final SessionManager _sessions;

  ThinkingRouteSessionSync({
    required ThinkingRouteRevalidator revalidator,
    required ThinkingRoutePreferenceStore store,
    required SessionManager sessions,
  }) : _revalidator = revalidator,
       _store = store,
       _sessions = sessions;

  ThinkingRouteRevalidationResult revalidateAndApplySession({
    required String sessionId,
    required String providerInstanceId,
    required String modelId,
    String? selectionId,
  }) {
    final session = _sessions.getSession(sessionId);
    final currentSelection = selectionId ?? session?.thinkingMode;
    final result = _revalidator.revalidateForRoute(
      sessionId: sessionId,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      selectionId: currentSelection,
    );
    if (result.selectionId != currentSelection || result.corrected) {
      _sessions.updateSessionModeling(
        sessionId,
        thinkingMode: result.selectionId,
        clearThinkingMode: result.selectionId == null,
      );
    }
    return result;
  }

  AgentTurnRequest revalidateTurnRequest(AgentTurnRequest request) {
    final providerId = request.effectiveProviderInstanceId?.trim();
    final modelId = request.model?.trim();
    if (providerId == null ||
        providerId.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      return request;
    }
    final result = _revalidator.revalidateForRoute(
      sessionId: request.sessionId,
      providerInstanceId: providerId,
      modelId: modelId,
      selectionId: request.thinkingMode,
    );
    if (result.selectionId == request.thinkingMode) {
      return request;
    }
    return request.copyWith(thinkingMode: result.selectionId);
  }

  Map<String, dynamic>? correctionPayloadFor(String sessionId) {
    return _store.readCorrection(sessionId)?.toMap();
  }
}
