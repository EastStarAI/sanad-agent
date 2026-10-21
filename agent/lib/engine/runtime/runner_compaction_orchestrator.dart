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
import '../../evolution/models/compaction_operation_record.dart';
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
import 'post_boundary_usage_reservation.dart';
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
  String? get currentModelStepId;

  /// Compaction boundary of the provider projection built for the current
  /// request, or `null` when the projection has no active boundary.
  CompactionOperationRecord? get activeProjectionBoundary;
  void healHistory();
  Future<int?> getContextTokens();
  LLMRequestOptions requestOptionsForTurn(
    String? providerId, {
    String? requestId,
  });
  LLMRequestOptions compactionRequestOptions(
    String? providerInstanceId, {
    required String compactionId,
  });
  List<Message> buildEffectiveHistory({String? runtimeSystemPrompt});
}

/// Owns preflight (automatic) compaction, the per-run automatic-compaction
/// breaker, the compaction cooldown, the pending and confirmed provider input
/// baselines with their wire proof, post-boundary usage reconciliation and
/// missing-usage finalization, timeline and projection-revision reads, and the
/// idle compaction provider seed.
class RunnerCompactionOrchestrator {
  static const Duration compactionCooldown = Duration(seconds: 30);
  static final Logger _logger = Logger('RunnerCompactionOrchestrator');

  /// Fine-level scalar record of one automatic pressure decision (Task 118b),
  /// so a turn that does not compact still shows whether admission used a
  /// provider receipt or the estimate. No session, content or route identity.
  static void _logPressureDecision(
    RequestPressureSnapshot pressure,
    String decision,
  ) {
    _logger.fine(
      'auto_pressure basis=${pressure.measurementKind.wireValue} '
      'estimated=${pressure.estimatedRequestTokens} '
      'confirmed=${pressure.confirmedInputTokens ?? 'none'} '
      'threshold=${pressure.thresholdTokens} '
      'window=${pressure.windowTokens} '
      'capped=${pressure.thresholdCappedByUsableBudget} '
      'decision=$decision',
    );
  }

  final RunnerCompactionHost host;

  ConfirmedInputUsageBaseline? confirmedInputUsageBaseline;
  ConfirmedInputUsageBaseline? pendingInputUsageBaseline;

  /// Compact versioned non-content proof of the request wire material whose
  /// provider-confirmed usage backs the current context-usage snapshot.
  /// Persisted with the snapshot so a later restore can prove the historical
  /// wire request prefix and route match before reusing confirmed usage.
  String? confirmedWireProof;
  RequestPressureSnapshot? lastPreflightPressure;
  DateTime? lastCompactionCompletedAt;
  bool autoCompactionBlockedForRun = false;

  RunnerCompactionOrchestrator(this.host);

  /// Opens the per-run automatic-compaction breaker.
  void markCompactionFailure() {
    autoCompactionBlockedForRun = true;
  }

  /// A new authoritative run is eligible for automatic compaction again.
  void resetRunFlags() {
    autoCompactionBlockedForRun = false;
  }

  void setConfirmedInputUsageBaseline(ConfirmedInputUsageBaseline? baseline) {
    confirmedInputUsageBaseline = baseline;
  }

  /// Post-boundary request identity for the current model step.
  String stepRequestId() {
    final turnRequestId = host.turnRoute.turnRequestId ?? '';
    final stepId = host.currentModelStepId;
    return stepId != null && stepId.isNotEmpty
        ? '$turnRequestId:$stepId'
        : turnRequestId;
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

  /// Confirms the staged input baseline from one provider response's usage
  /// and reconciles post-boundary usage for the active compaction boundary.
  ///
  /// A response without usage or without input tokens leaves the pending
  /// baseline staged, so a stream whose usage arrives only in a later chunk
  /// still confirms it.
  void confirmInputUsageBaseline(Map<String, dynamic>? usage) {
    final pending = pendingInputUsageBaseline;
    final activeBoundary = host.activeProjectionBoundary;
    final now = DateTime.now().toUtc();

    if (usage == null) {
      return;
    }

    final snapshot = LlmUsageSnapshot.fromProviderUsage(usage);
    final inputTokens = snapshot.inputTokens;

    if (inputTokens == null) {
      return;
    }

    if (pending != null) {
      confirmedInputUsageBaseline = pending.copyWithInputTokens(inputTokens);
      confirmedWireProof = pending.wireMeasurement != null
          ? RequestPressureEvaluator.wireProof(
              wireMeasurement: pending.wireMeasurement!,
              routeSignature: pending.routeSignature,
            )
          : null;
    }

    if (activeBoundary != null &&
        pending?.routeSignature != null &&
        getIt.isRegistered<CompactionCoordinator>()) {
      getIt<CompactionCoordinator>().reconcilePostBoundaryUsage(
        compactionId: activeBoundary.compactionId,
        requestId: stepRequestId(),
        observedAt: now,
        inputTokens: inputTokens,
        cachedTokens: snapshot.cachedTokens,
        routeSignature: pending!.routeSignature,
      );
    }
  }

  /// Reserves the post-boundary dispatch of the current step when a compaction
  /// boundary is active and the pending baseline carries a route. Returns the
  /// captured reservation, or `null` when none was made.
  DispatchedReservation? reservePostBoundaryDispatch({
    required CompactionOperationRecord? activeBoundary,
    required String stepRequestId,
  }) {
    final pending = pendingInputUsageBaseline;
    if (activeBoundary != null &&
        pending?.routeSignature != null &&
        getIt.isRegistered<CompactionCoordinator>()) {
      final reserved = getIt<CompactionCoordinator>()
          .reservePostBoundaryDispatch(
            compactionId: activeBoundary.compactionId,
            requestId: stepRequestId,
            routeSignature: pending!.routeSignature,
            dispatchedAt: DateTime.now().toUtc(),
          );
      if (reserved) {
        return DispatchedReservation(
          compactionId: activeBoundary.compactionId,
          requestId: stepRequestId,
          routeSignature: pending.routeSignature,
        );
      }
    }
    return null;
  }

  void finalizeCapturedPostBoundaryMissingUsage({
    required String compactionId,
    required String requestId,
    required RouteSignature routeSignature,
    required String missingReason,
  }) {
    if (getIt.isRegistered<CompactionCoordinator>()) {
      getIt<CompactionCoordinator>().recordPostBoundaryMissingUsage(
        compactionId: compactionId,
        requestId: requestId,
        observedAt: DateTime.now().toUtc(),
        missingReason: missingReason,
        routeSignature: routeSignature,
      );
    }
  }

  /// Finalizes one captured [reservation] as missing usage with [reason].
  void finalizeReservation(
    DispatchedReservation reservation,
    String missingReason,
  ) => finalizeCapturedPostBoundaryMissingUsage(
    compactionId: reservation.compactionId,
    requestId: reservation.requestId,
    routeSignature: reservation.routeSignature,
    missingReason: missingReason,
  );

  void finalizePostBoundaryMissingUsage({
    required CompactionOperationRecord? activeBoundary,
    required String stepRequestId,
    required String missingReason,
    RouteSignature? routeSignature,
  }) {
    final signature =
        routeSignature ?? pendingInputUsageBaseline?.routeSignature;
    if (activeBoundary != null && signature != null) {
      finalizeCapturedPostBoundaryMissingUsage(
        compactionId: activeBoundary.compactionId,
        requestId: stepRequestId,
        routeSignature: signature,
        missingReason: missingReason,
      );
    }
  }

  /// Restores one provider-confirmed input baseline for [routeSignature].
  ///
  /// The confirmed value always comes from the timestamped per-step
  /// `context_usage` snapshot when present, because the generic `usage` map on
  /// the same assistant row is a mutable last-run value that can disagree with
  /// the frozen per-call snapshot. `usage` remains a legacy fallback.
  ///
  /// Route identity follows authority: a `context_usage` provider/model
  /// identity is authoritative when present, so a matching mutable legacy
  /// `provider`/`model` value can never override a mismatched snapshot; a
  /// recorded identity that is absent or empty never matches a candidate
  /// alias, and candidate aliases themselves are never null.
  ///
  /// Adapters must expose [WireInputUsageMeasurer]. Unsupported/no-measurer
  /// adapters and legacy/unbound receipts fail closed to explicit estimate.
  /// A valid restored baseline requires a versioned `wire_proof` in
  /// `context_usage` that matches the active adapter's remeasurement of the
  /// historical request prefix and route signature, and requires the current
  /// request to extend that prefix. Stale receipts from before an activated
  /// compaction boundary are discarded by the same material proof, so no
  /// wall-clock recency heuristic is required.
  Future<void> restoreConfirmedInputUsageBaseline({
    required List<Message> prospectiveHistory,
    required WireInputUsageMeasurer? measurer,
    required RouteSignature routeSignature,
    required String? providerId,
    required String? modelId,
    required WireInputMeasurement? currentMeasurement,
  }) async {
    if (confirmedInputUsageBaseline != null) return;
    if (measurer == null) {
      // Unsupported/no-measurer adapters fail closed to explicit estimate.
      return;
    }
    for (var index = prospectiveHistory.length - 1; index >= 0; index--) {
      final receipt = ConfirmedUsageReceipt.read(
        prospectiveHistory[index],
        routeSignature: routeSignature,
        providerAlias: providerId,
      );
      if (receipt == null) continue;

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
      if (measurement == null) continue;

      if (!receipt.provenBy(measurement, routeSignature)) {
        // Historical wire material, tool schemas, prompt, or route mismatch:
        // fails closed.
        continue;
      }

      if (currentMeasurement == null ||
          !currentMeasurement.extendsMeasurement(measurement)) {
        return;
      }

      confirmedInputUsageBaseline = ConfirmedInputUsageBaseline(
        routeSignature: routeSignature,
        inputTokens: receipt.inputTokens,
        conversationMessages: measuredMessages,
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: toolSchemas.map((schema) => schema.toJson()).toList(),
        wireMeasurement: measurement,
      );
      return;
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
    final turnAdapter = _wireMeasurementAdapter(
      host.turnRoute.adapterForTurn(),
    );
    final measurementAdapter = turnAdapter is WireInputUsageMeasurer
        ? turnAdapter as WireInputUsageMeasurer
        : null;
    final wireMeasurement = measurementAdapter != null
        ? await measurementAdapter.measureInput(
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
        measurer: measurementAdapter,
        routeSignature: routeSignature,
        providerId: routing.providerId,
        modelId: routing.model,
        currentMeasurement: wireMeasurement,
      );
    } else {
      // Generic OpenAI-compatible adapters expose no wire measurement, but
      // their own provider-confirmed input must still drive admission instead
      // of an underestimated character fallback.
      await restoreConfirmedInputUsageBaseline(
        prospectiveHistory: prospectiveHistory,
        measurer: null,
        routeSignature: routeSignature,
        providerId: routing.providerId,
        modelId: routing.model,
        currentMeasurement: null,
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
        _logPressureDecision(pressure, 'below_threshold');
        return false;
      }
      final withinCooldown =
          lastCompactionCompletedAt != null &&
          DateTime.now().toUtc().difference(lastCompactionCompletedAt!) <
              compactionCooldown;
      if (withinCooldown &&
          pressure.estimatedRequestTokens <= pressure.effectiveInputBudget) {
        _logPressureDecision(pressure, 'cooldown');
        return false;
      }
      _logPressureDecision(pressure, 'compact');
    }
    try {
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
        providerTools: host.registry.allTools
            .map((tool) => tool.schema)
            .toList(),
        providerRequestOptions: host.compactionRequestOptions(
          routing.providerId,
          compactionId: 'auto',
        ),
        projectionRevision: currentProjectionRevision(),
        previousSummary: projection.activeBoundary?.internalSummary,
        previousSourceRange: projection.activeBoundary?.sourceRange,
        targetRequestTokens: CompactionTargetPolicy.targetRequestTokens(
          windowTokens: contextWindow,
          ratio: policy.targetRatio,
        ),
        thresholdRatio: policy.threshold,
        targetRatio: policy.targetRatio,
      );
      final outcome = await getIt<CompactionCoordinator>().runCompaction(
        request: request,
        force: true,
      );
      if (outcome?.status == CompactionStatus.completed) {
        lastCompactionCompletedAt = DateTime.now().toUtc();
        autoCompactionBlockedForRun = false;
        refreshCanonicalHistoryAfterCompaction();
        return true;
      }
      if (outcome?.status == CompactionStatus.failed) {
        autoCompactionBlockedForRun = true;
      }
      return false;
    } catch (_) {
      autoCompactionBlockedForRun = true;
      return false;
    }
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

  /// Builds the same idle provider payload used by an ordinary next request,
  /// without running preflight compaction or inventing a user turn.
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
