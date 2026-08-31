import '../../core/config.dart';
import '../../core/di.dart';
import '../../core/agent_runtime_service.dart';
import '../../core/provider_thinking/thinking_route_session_sync.dart';
import '../adapters/llm_adapter.dart';
import '../adapters/missing_provider_adapter.dart';
import '../agent_context_assembler.dart';
import '../../evolution/session_manager.dart';
import '../../evolution/db/runtime/session_route_mutation_coordinator.dart';
import '../../evolution/models/session_route_transition.dart';
import '../../core/provider_runtime/session_queue_provider_override.dart';

/// Resolves, tracks, and overrides the per-turn provider/model route.
///
/// **Ownership boundaries (Gate C refactor):**
/// - Owns the *volatile per-turn routing intent* (`_turnProviderId`,
///   `_turnModel`, `_turnThinkingMode`, `_turnRequestId`,
///   `_resolvedTurnRoute`). These are per-message values that do NOT
///   duplicate session-persisted state — they override it for the duration of
///   one turn only.
/// - Does **not** own session state. Persisting a provider/model switch to
///   the session is done via [applyTurnSwitchIfNeeded] which delegates to
///   the authoritative `SessionRouteMutationCoordinator`.
/// - Reads provider/model from `SessionManager` and `AgentRuntimeService`
///   via explicit lookups — no parallel source of truth.
class TurnRouteState {
  final String sessionId;
  final LLMAdapter fallbackAdapter;
  final SessionManager sessionManager;
  final AgentContextAssembler contextAssembler;

  String? _turnProviderId;
  String? _turnModel;
  String? _turnThinkingMode;
  String? _turnRequestId;
  String? _turnRunId;
  ({LLMAdapter adapter, String? modelOverride})? _resolvedTurnRoute;

  TurnRouteState({
    required this.sessionId,
    required this.fallbackAdapter,
    required this.sessionManager,
    required this.contextAssembler,
  });

  String? get effectiveModel {
    final session = sessionManager.getSession(sessionId);
    return session?.model;
  }

  /// Reads the persisted provider id for this session, if any.
  String? sessionProviderId() {
    final session = sessionManager.getSession(sessionId);
    final pid = session?.providerId;
    return (pid == null || pid.isEmpty) ? null : pid;
  }

  void setTurnRequestId(String? requestId) {
    _turnRequestId = requestId;
  }

  String? get turnRequestId => _turnRequestId;

  void setTurnRunId(String? runId) {
    _turnRunId = runId;
    _resolvedTurnRoute = null;
  }

  String? get effectiveThinkingMode {
    final session = sessionManager.getSession(sessionId);
    return _turnThinkingMode ?? session?.thinkingMode;
  }

  /// Sets the per-message routing intent from the incoming turn request.
  void configureTurn({
    String? providerId,
    String? model,
    String? thinkingMode,
    String? requestId,
  }) {
    _turnProviderId = providerId;
    _turnModel = model;
    _turnThinkingMode = thinkingMode;
    if (requestId != null) {
      _turnRequestId = requestId;
    }
  }

  /// Overwrites the active turn's provider/model route mid-flight so that the
  /// next retry loop iteration uses the new route rather than the stale one
  /// (Plan 30 Phase H P1: route override during waiting).
  void updateTurnRoute({String? providerId, String? modelId}) {
    if (providerId != null) _turnProviderId = providerId;
    if (modelId != null) _turnModel = modelId;
    // Invalidate any cached resolved route so the next resolution re-resolves
    // from AgentRuntimeService with the updated ids.
    _resolvedTurnRoute = null;
  }

  void updateTurnThinkingMode(String? thinkingMode) {
    _turnThinkingMode = thinkingMode;
  }

  /// Clears the cached resolved route, forcing re-resolution on next call.
  /// Used after a failed attempt so the retry loop picks up session changes.
  void invalidateResolvedRoute() {
    _resolvedTurnRoute = null;
  }

  /// Refreshes per-turn provider/model from session-persisted values after a
  /// recovery wait abort (the user may have changed provider/model).
  void refreshFromSession() {
    _turnProviderId = sessionProviderId();
    _turnModel = effectiveModel;
    _resolvedTurnRoute = null;
  }

  void cacheResolvedRoute(LLMAdapter adapter, String? modelOverride) {
    _resolvedTurnRoute = (adapter: adapter, modelOverride: modelOverride);
  }

  /// Resolves the adapter for the current turn from the composite cache in
  /// [AgentRuntimeService], using the per-message routing intent when present,
  /// or the session/config fallback otherwise. Falls back to the injected
  /// adapter when [AgentRuntimeService] is not registered (isolated tests).
  LLMAdapter adapterForTurn() {
    final resolved = _resolvedTurnRoute;
    if (resolved != null) {
      return resolved.adapter;
    }
    if (_turnProviderId == null &&
        _turnModel == null &&
        sessionProviderId() == null &&
        effectiveModel == null) {
      return fallbackAdapter;
    }
    if (!getIt.isRegistered<AgentRuntimeService>()) {
      return fallbackAdapter;
    }
    final runtime = getIt<AgentRuntimeService>();
    try {
      final providerId = _turnProviderId ?? sessionProviderId();
      final model = _turnModel ?? effectiveModel;
      final signature = runtime.resolveSignature(
        providerId: providerId,
        modelId: model,
      );
      runtime.rememberSessionSignature(sessionId, signature);
      return runtime.adapterForTurn(
        signature,
        sessionId: sessionId,
        requestId: _turnRequestId,
        runId: _turnRunId,
      );
    } catch (error) {
      return runtime.missingProviderAdapter(error);
    }
  }

  /// Returns the resolved (adapter, modelOverride) for the current turn.
  ({LLMAdapter adapter, String? modelOverride}) routeForTurn() {
    final resolved = _resolvedTurnRoute;
    if (resolved != null) {
      return resolved;
    }
    final turnAdapter = adapterForTurn();
    final modelOverride = switch (turnAdapter) {
      MissingProviderAdapter() => null,
      _ => _turnModel ?? effectiveModel,
    };
    return (adapter: turnAdapter, modelOverride: modelOverride);
  }

  /// Resolves the effective (providerId, model, baseUrl, apiKey) for the
  /// current turn from the per-message intent, falling back to session values
  /// and then the global config default.
  ({String? providerId, String? model, String? baseUrl, String? apiKey})
  resolveTurnRouting() {
    if (!getIt.isRegistered<AgentRuntimeService>()) {
      final config = getIt.isRegistered<Config>() ? getIt<Config>() : null;
      return (
        providerId:
            _turnProviderId ??
            sessionProviderId() ??
            config?.resolveProviderName(),
        model: _turnModel ?? effectiveModel ?? config?.llmModel,
        baseUrl: config?.llmBaseUrl,
        apiKey: config?.llmApiKey,
      );
    }
    final runtime = getIt<AgentRuntimeService>();
    final providerId = _turnProviderId ?? sessionProviderId();
    final model = _turnModel ?? effectiveModel;
    try {
      final signature = runtime.resolveSignature(
        providerId: providerId,
        modelId: model,
      );
      String? resolvedApiKey;
      if (runtime.credentialService != null &&
          !signature.providerInstanceId.startsWith('fallback-')) {
        final rawSecret = runtime.credentialService!.rawForResolver(
          signature.providerInstanceId,
        );
        if (rawSecret != null) {
          resolvedApiKey = rawSecret.apiKey ?? rawSecret.accessToken;
        }
      }
      return (
        providerId: signature.providerInstanceId,
        model: signature.modelId,
        baseUrl: signature.normalizedBaseUrl,
        apiKey: resolvedApiKey,
      );
    } catch (_) {
      final config = getIt.isRegistered<Config>() ? getIt<Config>() : null;
      return (
        providerId: providerId,
        model: model,
        baseUrl: config?.llmBaseUrl,
        apiKey: config?.llmApiKey,
      );
    }
  }

  /// Detects whether the current turn's (provider, model, thinkingMode)
  /// differs from the session's persisted values and, on a real switch,
  /// persists the new values to the session and invalidates the volatile
  /// prompt tier.
  ///
  /// Returns the previous values when a switch occurred, otherwise null.
  ({String? providerId, String? model, String? thinkingMode})?
  applyTurnSwitchIfNeeded() {
    final session = sessionManager.getSession(sessionId);
    if (session == null) return null;

    final newProvider = _turnProviderId ?? sessionProviderId();
    final newModel = _turnModel ?? session.model;
    var newThinking = _turnThinkingMode ?? session.thinkingMode;

    final providerChanged =
        newProvider != null && newProvider != session.providerId;
    final modelChanged = newModel != session.model;

    if ((providerChanged || modelChanged) &&
        newProvider != null &&
        newProvider.isNotEmpty &&
        newModel.isNotEmpty &&
        getIt.isRegistered<ThinkingRouteSessionSync>()) {
      final revalidated = getIt<ThinkingRouteSessionSync>().revalidateAndApplySession(
        sessionId: sessionId,
        providerInstanceId: newProvider,
        modelId: newModel,
        selectionId: newThinking,
      );
      newThinking = revalidated.selectionId;
      _turnThinkingMode = newThinking;
    }

    final thinkingChanged = newThinking != session.thinkingMode;

    if (!providerChanged && !modelChanged && !thinkingChanged) {
      return null;
    }

    final previous = (
      providerId: session.providerId,
      model: session.model,
      thinkingMode: session.thinkingMode,
    );

    if ((providerChanged || modelChanged) &&
        newProvider != null &&
        getIt.isRegistered<SessionRouteMutationCoordinator>()) {
      getIt<SessionRouteMutationCoordinator>().mutate(
        sessionId: sessionId,
        providerInstanceId: newProvider,
        model: newModel,
        source: SessionRouteSource.user,
        reason: 'turn_route',
        requestId: _turnRequestId,
        publish: true,
      );
      if (thinkingChanged) {
        sessionManager.updateSessionModeling(
          sessionId,
          thinkingMode: newThinking,
          clearThinkingMode: newThinking == null,
        );
      }
    } else {
      // Isolated tests and provider-less legacy sessions may not initialize
      // the production route persistence graph.
      sessionManager.updateSessionModeling(
        sessionId,
        providerId: newProvider,
        model: newModel,
        thinkingMode: newThinking,
        clearThinkingMode: newThinking == null,
      );
    }
    contextAssembler.invalidateVolatile();
    return previous;
  }

  /// Rewrites queued provider overrides for this session during auto-failover.
  void rewriteQueuedProvider(String newProviderId) {
    if (getIt.isRegistered<SessionQueueProviderOverride>()) {
      getIt<SessionQueueProviderOverride>().rewriteQueuedProvider(
        sessionId,
        newProviderId,
      );
    }
    _turnProviderId = newProviderId;
    contextAssembler.invalidateVolatile();
  }
}
