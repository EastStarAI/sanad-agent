import 'dart:async';

import 'package:logging/logging.dart';

import '../../capabilities/models/tool_schema.dart';
import '../../capabilities/registry/tools_registry.dart';
import '../../core/agent_runtime_service.dart';
import '../../core/config.dart';
import '../../core/di.dart';
import '../../core/models/llm_usage_snapshot.dart';
import '../../core/models/message.dart';
import '../../evolution/compaction/model_projection_builder.dart';
import '../../evolution/db/session_history_revision_repository.dart';
import '../../evolution/db/session_projection_revision_repository.dart';
import '../../evolution/session_manager.dart';
import '../../plugins/plugin_manager.dart';
import '../adapters/llm_adapter.dart';
import '../adapters/llm_request_options.dart';
import '../adapters/rate_limited_llm_adapter.dart';
import '../agent_context_assembler.dart';
import '../compaction/compaction.dart';
import '../context/context.dart';
import 'compaction_coordinator.dart';
import 'continuation_checkpoint_coordinator.dart';
import 'turn_route_state.dart';

/// Compaction seed data for the provider.
class CompactionProviderSeed {
  final List<Message> projection;
  final List<ToolSchema> tools;
  final LLMRequestOptions options;

  CompactionProviderSeed({
    required List<Message> projection,
    required List<ToolSchema> tools,
    required this.options,
  }) : projection = List.unmodifiable(projection),
       tools = List.unmodifiable(tools);
}

/// Host interface providing state and callbacks to [RunnerCompactionOrchestrator].
abstract class RunnerCompactionHost {
  String get sessionId;
  TurnRouteState get turnRoute;
  ToolsRegistry get registry;
  SessionManager get sessionManager;
  PluginManager get pluginManager;
  AgentContextAssembler get contextAssembler;
  ContinuationCheckpointCoordinator get checkpointCoordinator;
  CheckpointContext get checkpointCtx;
  List<Message> get history;
  set history(List<Message> newHistory);
  void healHistory();
  Future<int?> getContextTokens();
  LLMRequestOptions requestOptionsForTurn(String? providerId);
  LLMRequestOptions compactionRequestOptions(
    String providerInstanceId, {
    required String compactionId,
  });
  List<Message> buildEffectiveHistory({String? runtimeSystemPrompt});
}

/// Orchestrates preflight and overflow context compaction, compaction cooldowns,
/// timeline projections, and token baseline measurements for AgentRunner.
class RunnerCompactionOrchestrator {
  static final Logger _logger = Logger('RunnerCompactionOrchestrator');
  static const Duration compactionCooldown = Duration(seconds: 30);

  final RunnerCompactionHost host;

  ConfirmedInputUsageBaseline? confirmedInputUsageBaseline;
  ConfirmedInputUsageBaseline? pendingInputUsageBaseline;
  RequestPressureSnapshot? lastPreflightPressure;
  DateTime? lastCompactionCompletedAt;
  bool autoCompactionBlockedForRun = false;

  RunnerCompactionOrchestrator(this.host);

  void markCompactionFailure() {
    autoCompactionBlockedForRun = true;
  }

  void resetRunFlags() {
    autoCompactionBlockedForRun = false;
  }

  void setConfirmedInputUsageBaseline(ConfirmedInputUsageBaseline? baseline) {
    confirmedInputUsageBaseline = baseline;
  }

  Future<void> stageInputUsageBaseline({
    required List<Message> requestMessages,
    required List<Map<String, dynamic>> toolSchemas,
    required String? providerId,
    required String? modelId,
  }) async {
    if (providerId == null ||
        modelId == null ||
        !getIt.isRegistered<AgentRuntimeService>()) {
      pendingInputUsageBaseline = null;
      return;
    }
    final measurementAdapter = _wireMeasurementAdapter(
      host.turnRoute.adapterForTurn(),
    );
    final wireMeasurement = measurementAdapter is WireInputUsageMeasurer
        ? await (measurementAdapter as WireInputUsageMeasurer).measureInput(
            requestMessages,
            tools: host.registry.allTools.map((tool) => tool.schema).toList(),
            modelOverride: modelId,
            options: host.requestOptionsForTurn(providerId),
          )
        : null;
    pendingInputUsageBaseline = ConfirmedInputUsageBaseline(
      routeSignature: getIt<AgentRuntimeService>().resolveSignature(
        providerId: providerId,
        modelId: modelId,
      ),
      inputTokens: 0,
      conversationMessages: requestMessages,
      systemPrompt: '',
      runtimeContext: '',
      toolSchemas: toolSchemas,
      wireMeasurement: wireMeasurement,
    );
  }

  static LLMAdapter _wireMeasurementAdapter(LLMAdapter adapter) =>
      adapter is RateLimitedLLMAdapter ? adapter.providerAdapter : adapter;

  Future<void> restoreConfirmedInputUsageBaseline({
    required List<Message> prospectiveHistory,
    required WireInputUsageMeasurer measurer,
    required RouteSignature routeSignature,
    required String? providerId,
    required String? modelId,
    required WireInputMeasurement currentMeasurement,
  }) async {
    if (confirmedInputUsageBaseline != null) return;

    for (var index = prospectiveHistory.length - 1; index >= 0; index--) {
      final message = prospectiveHistory[index];
      if (message.role != MessageRole.assistant) continue;
      final metadata = message.metadata;
      final usage = metadata?['usage'];
      final inputTokens = usage is Map ? usage['input_tokens'] : null;
      if (inputTokens is! num || inputTokens <= 0) continue;

      final recordedModel = metadata?['model']?.toString();
      final recordedProvider = metadata?['provider']?.toString();
      final contextUsage = metadata?['context_usage'];
      final recordedContextProvider = contextUsage is Map
          ? contextUsage['provider_instance_id']?.toString()
          : null;
      final providerMatches =
          <String?>{
            routeSignature.providerInstanceId,
            routeSignature.templateId,
            providerId,
          }.contains(recordedProvider) ||
          <String?>{
            routeSignature.providerInstanceId,
            routeSignature.templateId,
            providerId,
          }.contains(recordedContextProvider);
      if (recordedModel != routeSignature.modelId || !providerMatches) {
        continue;
      }

      final measuredMessages = prospectiveHistory.sublist(0, index);
      final toolSchemas = host.registry.allTools
          .map((tool) => tool.schema)
          .toList();
      final measurement = await measurer.measureInput(
        measuredMessages,
        tools: toolSchemas,
        modelOverride: modelId,
        options: host.requestOptionsForTurn(providerId),
      );
      if (measurement == null) return;
      if (!currentMeasurement.extendsMeasurement(measurement)) return;

      confirmedInputUsageBaseline = ConfirmedInputUsageBaseline(
        routeSignature: routeSignature,
        inputTokens: inputTokens.toInt(),
        conversationMessages: measuredMessages,
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: toolSchemas.map((tool) => tool.toJson()).toList(),
        wireMeasurement: measurement,
      );
      return;
    }
  }

  void confirmInputUsageBaseline(Map<String, dynamic>? usage) {
    final pending = pendingInputUsageBaseline;
    pendingInputUsageBaseline = null;
    if (usage == null || pending == null) return;
    final inputTokens = LlmUsageSnapshot.fromProviderUsage(usage).inputTokens;
    if (inputTokens != null) {
      confirmedInputUsageBaseline = pending.copyWithInputTokens(inputTokens);
      if (getIt.isRegistered<CompactionCoordinator>()) {
        getIt<CompactionCoordinator>().reconcileLatestProviderUsage(
          sessionId: host.sessionId,
          routeSignature: pending.routeSignature,
          inputTokens: inputTokens,
        );
      }
    }
  }

  Future<bool> maybeRunPreflightCompaction({
    String? runtimeSystemPrompt,
    required List<Message> prospectiveHistory,
  }) async {
    if (autoCompactionBlockedForRun) {
      return false;
    }
    if (!getIt.isRegistered<CompactionCoordinator>() ||
        !getIt.isRegistered<SessionHistoryRevisionRepository>() ||
        !getIt.isRegistered<AgentRuntimeService>()) {
      return false;
    }
    final revisionRepo = getIt<SessionHistoryRevisionRepository>();
    final revision = revisionRepo.read(host.sessionId);
    if (revision == null) {
      return false;
    }
    final timelineEntries = compactionTimelineForSession();
    if (timelineEntries.isEmpty) {
      return false;
    }
    final projection = getIt<ModelProjectionBuilder>().buildForSession(
      host.sessionId,
    );
    final routing = host.turnRoute.resolveTurnRouting();
    final contextWindow = await host.getContextTokens() ?? 128_000;
    final policy = getIt.isRegistered<Config>()
        ? getIt<Config>().compactionPolicyForModel(routing.model ?? '')
        : const CompactionPolicy(threshold: 0.90, targetRatio: 0.10);
    final turnAdapter = _wireMeasurementAdapter(host.turnRoute.adapterForTurn());
    final wireMeasurement = turnAdapter is WireInputUsageMeasurer
        ? await (turnAdapter as WireInputUsageMeasurer).measureInput(
            prospectiveHistory,
            tools: host.registry.allTools.map((tool) => tool.schema).toList(),
            modelOverride: routing.model,
            options: host.requestOptionsForTurn(routing.providerId),
          )
        : null;
    final wireEstimatedInputTokens =
        wireMeasurement?.estimatedTokens ??
        (turnAdapter is WireInputTokenEstimator
            ? await (turnAdapter as WireInputTokenEstimator)
                  .estimateInputTokens(
                    prospectiveHistory,
                    tools: host.registry.allTools
                        .map((tool) => tool.schema)
                        .toList(),
                    modelOverride: routing.model,
                    options: host.requestOptionsForTurn(routing.providerId),
                  )
            : null);
    final routeSignature = getIt<AgentRuntimeService>().resolveSignature(
      providerId: routing.providerId,
      modelId: routing.model,
    );
    if (turnAdapter is WireInputUsageMeasurer && wireMeasurement != null) {
      await restoreConfirmedInputUsageBaseline(
        prospectiveHistory: prospectiveHistory,
        measurer: turnAdapter as WireInputUsageMeasurer,
        routeSignature: routeSignature,
        providerId: routing.providerId,
        modelId: routing.model,
        currentMeasurement: wireMeasurement,
      );
    }
    final toolSchemas = host.registry.allTools
        .map((tool) => tool.schema.toJson())
        .toList();
    RequestPressureSnapshot? preflightPressure;
    if (getIt.isRegistered<ContextCompactionEngine>()) {
      final pressure = RequestPressureEvaluator().evaluate(
        routeSignature: routeSignature,
        contextWindowTokens: contextWindow,
        conversationMessages: prospectiveHistory,
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: toolSchemas,
        confirmedInputUsage: confirmedInputUsageBaseline,
        wireEstimatedInputTokens: wireEstimatedInputTokens,
        wireMeasurement: wireMeasurement,
        thresholdRatio: policy.threshold,
      );
      preflightPressure = pressure;
      lastPreflightPressure = pressure;
      if (!pressure.exceedsThreshold) {
        return false;
      }
      final withinCooldown =
          lastCompactionCompletedAt != null &&
          DateTime.now().toUtc().difference(lastCompactionCompletedAt!) <
              compactionCooldown;
      if (withinCooldown &&
          pressure.estimatedRequestTokens <= pressure.effectiveInputBudget) {
        return false;
      }
    }
    final request = CompactionEngineRequest(
      compactionId: '',
      sessionId: host.sessionId,
      trigger: CompactionTrigger.auto,
      sourceRevision: revision.toCompactionRevision(),
      routeSignature: routeSignature,
      contextWindowTokens: contextWindow,
      preflightPressure: preflightPressure,
      timeline: timelineEntries,
      systemPrompt: host.contextAssembler.assemble() ?? '',
      runtimeContext: runtimeSystemPrompt ?? '',
      toolSchemas: toolSchemas,
      providerProjection: prospectiveHistory,
      providerTools: host.registry.allTools.map((tool) => tool.schema).toList(),
      providerRequestOptions: host.compactionRequestOptions(
        routing.providerId ?? '',
        compactionId: 'auto',
      ),
      projectionRevision: currentProjectionRevision(),
      previousSummary: projection.activeBoundary?.internalSummary,
      previousSourceRange: projection.activeBoundary?.sourceRange,
      targetRequestTokens:
          (calculateEffectiveInputWindow(contextWindow) * policy.targetRatio).round(),
      thresholdRatio: policy.threshold,
    );
    final coordinator = getIt<CompactionCoordinator>();
    final outcome = await coordinator.runCompaction(
      request: request,
      force: true,
    );
    if (outcome?.status == CompactionStatus.completed) {
      lastCompactionCompletedAt = DateTime.now().toUtc();
      refreshCanonicalHistoryAfterCompaction();
      return true;
    }
    if (outcome?.status == CompactionStatus.failed) {
      _logger.warning('Preflight compaction failed for session ${host.sessionId}');
      autoCompactionBlockedForRun = true;
    }
    return false;
  }

  int currentProjectionRevision() {
    if (!getIt.isRegistered<SessionProjectionRevisionRepository>()) return 0;
    return getIt<SessionProjectionRevisionRepository>()
            .read(host.sessionId)
            ?.value ??
        0;
  }

  void refreshCanonicalHistoryAfterCompaction() {
    final session = host.sessionManager.getSession(host.sessionId);
    if (session != null) {
      host.history = session.messages.toList();
      host.healHistory();
    }
    host.checkpointCoordinator.saveCheckpoint(
      ctx: host.checkpointCtx,
      resumeHistoryLength: host.history.length,
    );
  }

  List<IndexedConversationMessage> compactionTimelineForSession() {
    if (getIt.isRegistered<ModelProjectionBuilder>()) {
      final canonical = getIt<ModelProjectionBuilder>().loadCanonicalTimeline(
        host.sessionId,
      );
      if (canonical.messages.isNotEmpty) {
        return [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ];
      }
    }
    return host.history
        .asMap()
        .entries
        .map((entry) {
          return IndexedConversationMessage(
            rowId: entry.key + 1,
            message: entry.value,
          );
        })
        .toList(growable: false);
  }

  Future<CompactionProviderSeed> prepareCompactionProviderSeed({
    String? runtimeSystemPrompt,
  }) async {
    var projection = host.buildEffectiveHistory(
      runtimeSystemPrompt: runtimeSystemPrompt,
    );
    projection = await host.pluginManager.runPreExecution(projection);
    final routing = host.turnRoute.resolveTurnRouting();
    return CompactionProviderSeed(
      projection: projection,
      tools: host.registry.allTools.map((tool) => tool.schema).toList(),
      options: host.requestOptionsForTurn(routing.providerId),
    );
  }
}
