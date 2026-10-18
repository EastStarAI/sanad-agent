import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_watchdog_config.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
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
    List<Message>? providerProjection,
    List<ToolSchema>? providerTools,
    LLMRequestOptions? providerRequestOptions,
    int? contextWindowTokens,
    ConfirmedInputUsageBaseline? confirmedInputUsage,
    double? targetRatio,
  }) async {
    if (!getIt.isRegistered<ModelProjectionBuilder>() ||
        !getIt.isRegistered<SessionHistoryRevisionRepository>() ||
        !getIt.isRegistered<SessionProjectionRevisionRepository>() ||
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
    final activeProjection = projectionBuilder.buildForSession(sessionId);
    final projectionRevision = getIt<SessionProjectionRevisionRepository>()
        .read(sessionId);
    if (projectionRevision == null) return null;

    final session = getIt<SessionManager>().getSessionRecord(sessionId);
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
          conversationMessages: activeProjection.conversationMessages,
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
      providerProjection:
          providerProjection ??
          [
            if (systemPrompt.isNotEmpty)
              Message(role: MessageRole.system, content: systemPrompt),
            ...activeProjection.conversationMessages,
          ],
      providerTools:
          providerTools ??
          toolSchemas.map(ToolSchema.fromJson).toList(growable: false),
      providerRequestOptions: buildCompactionRequestOptions(
        sessionId: sessionId,
        compactionId: compactionId,
        routeSignature: route,
        baseOptions: providerRequestOptions,
        fallbackThinkingMode: session?.thinkingMode,
      ),
      projectionRevision: projectionRevision.value,
      previousSummary: activeBoundary?.internalSummary,
      previousSourceRange: activeBoundary?.sourceRange,
      targetRequestTokens:
          (effectiveWindow * (targetRatio ?? policy?.targetRatio ?? 0.10))
              .round(),
      thresholdRatio: policy?.threshold ?? 0.90,
    );
  }

  /// Derives canonical request options for compaction across manual, auto,
  /// and overflow triggers while preserving all adapter and thinking context.
  static LLMRequestOptions buildCompactionRequestOptions({
    required String sessionId,
    required String compactionId,
    required RouteSignature routeSignature,
    LLMRequestOptions? baseOptions,
    String? fallbackThinkingMode,
    Duration? defaultTimeout,
    int? defaultMaxOutputTokens,
  }) {
    final reqId = compactionId.startsWith('compaction:')
        ? compactionId
        : 'compaction:$compactionId';
    final pId = baseOptions?.providerInstanceId ??
        (routeSignature.providerInstanceId.isNotEmpty
            ? routeSignature.providerInstanceId
            : null);
    final effectiveThinkingMode =
        baseOptions?.thinkingMode ?? fallbackThinkingMode;

    RouteCapabilityProfile? profile = baseOptions?.routeCapabilityProfile;
    if (profile == null &&
        pId != null &&
        routeSignature.modelId.isNotEmpty &&
        getIt.isRegistered<RouteCapabilityResolver>()) {
      profile = getIt<RouteCapabilityResolver>().resolveSync(
        providerInstanceId: pId,
        modelId: routeSignature.modelId,
        thinkingMode: effectiveThinkingMode,
      );
    }

    final thinkingDirective =
        baseOptions?.thinkingDirective ?? profile?.thinkingDirective;
    final routeSnapshot =
        baseOptions?.routeCapabilitySnapshot ?? profile?.rawOverride;
    final attachmentStore = baseOptions?.attachmentStore ??
        (getIt.isRegistered<AttachmentStore>()
            ? getIt<AttachmentStore>()
            : null);

    final scope = baseOptions?.cancellationScope;
    final validScope = (scope != null &&
            scope.isPublicationOpen &&
            !scope.isCancellationTerminal)
        ? scope
        : null;

    return LLMRequestOptions(
      sessionId: baseOptions?.sessionId ?? sessionId,
      requestId: reqId,
      providerInstanceId: pId,
      thinkingMode: effectiveThinkingMode,
      thinkingDirective: thinkingDirective,
      timeout: baseOptions?.timeout ?? defaultTimeout,
      maxOutputTokens: baseOptions?.maxOutputTokens ?? defaultMaxOutputTokens,
      cancellationScope: validScope,
      watchdogs: baseOptions?.watchdogs ?? ProviderWatchdogConfig.defaults,
      routeCapabilitySnapshot: routeSnapshot,
      routeCapabilityProfile: profile,
      attachmentStore: attachmentStore,
      requestClientFactory: baseOptions?.requestClientFactory,
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
