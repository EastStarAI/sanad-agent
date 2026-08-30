import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

/// Builds engine requests from persisted session state (Plan 53d).
abstract final class CompactionRequestFactory {
  CompactionRequestFactory._();

  static CompactionEngineRequest? forSession({
    required String sessionId,
    required CompactionTrigger trigger,
    required String compactionId,
    String systemPrompt = '',
    String runtimeContext = '',
    List<Map<String, dynamic>> toolSchemas = const [],
    int? contextWindowTokens,
    int? confirmedInputTokens,
    double targetRatio = 0.7,
  }) {
    if (!getIt.isRegistered<ModelProjectionBuilder>() ||
        !getIt.isRegistered<SessionHistoryRevisionRepository>()) {
      return null;
    }
    final revision = getIt<SessionHistoryRevisionRepository>().read(sessionId);
    if (revision == null) {
      return null;
    }
    final timeline = getIt<ModelProjectionBuilder>().loadCanonicalTimeline(
      sessionId,
    );
    if (timeline.messages.isEmpty) {
      return null;
    }

    final session = getIt<SessionManager>().getSession(sessionId);
    final runtime = getIt<AgentRuntimeService>();
    final route = runtime.resolveSignature(
      providerId: session?.providerId,
      modelId: session?.model,
    );
    final pressureProbe = RequestPressureEvaluator(
      outputReservationTokens: 1000,
      safetyBufferTokens: 500,
    );
    final estimatedRequestTokens = pressureProbe.evaluate(
      routeSignature: route,
      contextWindowTokens: 128_000,
      conversationMessages: [
        for (final entry in timeline.messages) entry.message,
      ],
      systemPrompt: systemPrompt,
      runtimeContext: runtimeContext,
      toolSchemas: toolSchemas,
    ).estimatedRequestTokens;
    final window = contextWindowTokens ??
        (estimatedRequestTokens * 1.4).round().clamp(4_096, 128_000);

    return CompactionEngineRequest(
      compactionId: compactionId,
      sessionId: sessionId,
      trigger: trigger,
      sourceRevision: revision.toCompactionRevision(),
      routeSignature: route,
      contextWindowTokens: window,
      confirmedInputTokens: confirmedInputTokens,
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
      targetRequestTokens: (window * targetRatio).round(),
    );
  }
}
