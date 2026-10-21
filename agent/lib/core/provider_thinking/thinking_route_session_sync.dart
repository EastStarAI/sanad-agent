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
    bool restorePreserved = true,
  }) {
    final session = _sessions.getSession(sessionId);
    final persistedThinkingMode = session?.thinkingMode;

    String? candidateSelection;
    bool effectiveRestorePreserved = restorePreserved;

    if (!restorePreserved) {
      // Deliberate default / reset intent: do not restore preserved or coalesce with session mode.
      candidateSelection = selectionId;
      effectiveRestorePreserved = false;
    } else if (selectionId != null) {
      // Explicit selection passed with restorePreserved.
      candidateSelection = selectionId;
      effectiveRestorePreserved = false;
    } else {
      // selectionId is null with restorePreserved == true (restore intent).
      // Check if store already has a preserved route preference.
      final hasStoredPreference = _store.readForRoute(
        sessionId,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      ) != null;

      if (!hasStoredPreference &&
          session != null &&
          session.providerId == providerInstanceId &&
          session.model == modelId &&
          persistedThinkingMode != null &&
          persistedThinkingMode.trim().isNotEmpty) {
        // Same-route legacy session without metadata: validate legacy mode
        candidateSelection = persistedThinkingMode;
        effectiveRestorePreserved = false;
      } else {
        candidateSelection = null;
        effectiveRestorePreserved = true;
      }
    }

    final result = _revalidator.revalidateForRoute(
      sessionId: sessionId,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      selectionId: candidateSelection,
      restorePreserved: effectiveRestorePreserved,
    );
    if (result.selectionId != persistedThinkingMode || result.corrected) {
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
      restorePreserved: true,
    );
    if (result.selectionId == request.thinkingMode) {
      return request;
    }
    return request.copyWith(thinkingMode: result.selectionId);
  }

  /// Admits a turn selection that only echoes the session's already-persisted
  /// thinking preference.
  ///
  /// Provenance: a turn value equal to the preference persisted *before* this
  /// turn (by `create_session`, a previous turn or a preference update) is a
  /// carried-over preference, not a fresh explicit choice for this route. The
  /// Client may carry a value the target route never offered and the user could
  /// not see. When the route offers it, the request is unchanged and nothing is
  /// written. When it does not, the selection falls back to provider default
  /// through [ThinkingRouteRevalidator.revalidateForRoute], which records the
  /// existing route-scoped correction (or a silent provider default when the
  /// value was inherited from another route). A turn value that differs from
  /// the persisted preference stays a fresh explicit request and is returned
  /// untouched so admission still validates and rejects it.
  AgentTurnRequest revalidateCarriedTurnSelection(
    AgentTurnRequest request, {
    required String? persistedSelection,
    required String? sessionProviderInstanceId,
    required String? sessionModelId,
  }) {
    final carried = request.thinkingMode?.trim();
    if (carried == null || carried.isEmpty) return request;
    if (carried != persistedSelection?.trim()) return request;
    final providerId =
        (request.effectiveProviderInstanceId ?? sessionProviderInstanceId)
            ?.trim();
    final modelId = (request.model ?? sessionModelId)?.trim();
    if (providerId == null ||
        providerId.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      return request;
    }
    if (_revalidator.offersSelection(
      providerInstanceId: providerId,
      modelId: modelId,
      selectionId: carried,
    )) {
      return request;
    }
    final result = _revalidator.revalidateForRoute(
      sessionId: request.sessionId,
      providerInstanceId: providerId,
      modelId: modelId,
      selectionId: carried,
    );
    return request.copyWith(thinkingMode: result.selectionId);
  }

  Map<String, dynamic>? correctionPayloadFor(String sessionId) {
    return _store.readCorrection(sessionId)?.toMap();
  }
}
