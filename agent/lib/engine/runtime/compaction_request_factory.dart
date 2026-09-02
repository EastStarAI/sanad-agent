import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

/// Builds engine requests from persisted session state (Plan 53d).
abstract final class CompactionRequestFactory {
  CompactionRequestFactory._();

  static Future<CompactionEngineRequest?> forSession({
    required String sessionId,
    required CompactionTrigger trigger,
    required String compactionId,
    String systemPrompt = '',
    String runtimeContext = '',
    List<Map<String, dynamic>> toolSchemas = const [],
    int? contextWindowTokens,
    ConfirmedInputUsageBaseline? confirmedInputUsage,
    double? targetRatio,
  }) async {
    if (!getIt.isRegistered<ModelProjectionBuilder>() ||
        !getIt.isRegistered<SessionHistoryRevisionRepository>() ||
        !getIt.isRegistered<AgentRuntimeService>()) {
      return null;
    }
    final revision = getIt<SessionHistoryRevisionRepository>().read(sessionId);
    if (revision == null) {
      return null;
    }
    final projectionBuilder = getIt<ModelProjectionBuilder>();
    final timeline = projectionBuilder.loadCanonicalTimeline(sessionId);
    if (timeline.messages.isEmpty) {
      return null;
    }
    final activeBoundary = projectionBuilder
        .buildForSession(sessionId)
        .activeBoundary;

    final session = getIt<SessionManager>().getSession(sessionId);
    final runtime = getIt<AgentRuntimeService>();
    final route = runtime.resolveSignature(
      providerId: session?.providerId,
      modelId: session?.model,
    );
    final config = getIt.isRegistered<Config>() ? getIt<Config>() : null;
    final policy = config?.compactionPolicyForModel(route.modelId);
    final pressureProbe = RequestPressureEvaluator(
      outputReservationTokens: 1000,
      safetyBufferTokens: 500,
    );
    final estimatedRequestTokens = pressureProbe
        .evaluate(
          routeSignature: route,
          contextWindowTokens: 128_000,
          conversationMessages: [
            for (final entry in timeline.messages) entry.message,
          ],
          systemPrompt: systemPrompt,
          runtimeContext: runtimeContext,
          toolSchemas: toolSchemas,
        )
        .estimatedRequestTokens;
    final window = await resolveContextWindowTokens(
      explicitOverride: contextWindowTokens,
      configuredOverride: config?.contextModelLimit(route.modelId),
      resolveProviderLimit: () =>
          runtime.adapterFor(route).getContextLimit(route.modelId),
      estimatedRequestTokens: estimatedRequestTokens,
    );
    final effectiveWindow = calculateEffectiveInputWindow(window);

    return CompactionEngineRequest(
      compactionId: compactionId,
      sessionId: sessionId,
      trigger: trigger,
      sourceRevision: revision.toCompactionRevision(),
      routeSignature: route,
      contextWindowTokens: window,
      confirmedInputUsage: confirmedInputUsage,
      timeline: [
        for (final entry in timeline.messages)
          IndexedConversationMessage(
            rowId: entry.rowId,
            message: entry.message,
          ),
      ],
      systemPrompt: systemPrompt,
      runtimeContext: runtimeContext,
      toolSchemas: toolSchemas,
      previousSummary: activeBoundary?.internalSummary,
      previousSourceRange: activeBoundary?.sourceRange,
      targetRequestTokens:
          (effectiveWindow * (targetRatio ?? policy?.targetRatio ?? 0.10))
              .round(),
      thresholdRatio: policy?.threshold ?? 0.80,
    );
  }

  static Future<int> resolveContextWindowTokens({
    required int? explicitOverride,
    required int? configuredOverride,
    required Future<int> Function() resolveProviderLimit,
    required int estimatedRequestTokens,
  }) async {
    if (explicitOverride != null) return explicitOverride;
    if (configuredOverride != null) return configuredOverride;
    try {
      final providerLimit = await resolveProviderLimit();
      if (providerLimit > 0) return providerLimit;
    } catch (_) {
      // Keep manual compaction available if provider metadata cannot be
      // resolved; the bounded estimate below remains the last resort.
    }
    return (estimatedRequestTokens * 1.4).round().clamp(4_096, 128_000);
  }
}
