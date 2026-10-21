import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/rate_limited_llm_adapter.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:uuid/uuid.dart';

/// Canonical compaction lifecycle payload for protocol/UI (Plan 53d D6).
@immutable
class CompactionLifecycleEvent {
  final String compactionId;
  final String sessionId;
  final CompactionTrigger trigger;
  final CompactionStatus status;
  final CompactionFailureReason? failureReason;
  final String? failureStage;
  final String? failureCause;
  final Map<String, dynamic>? failureDetail;
  final CompactionMetrics? metrics;
  final String? providerInstanceId;
  final String? modelId;
  final DateTime startedAt;
  final DateTime? completedAt;

  const CompactionLifecycleEvent({
    required this.compactionId,
    required this.sessionId,
    required this.trigger,
    required this.status,
    this.failureReason,
    this.failureStage,
    this.failureCause,
    this.failureDetail,
    this.metrics,
    this.providerInstanceId,
    this.modelId,
    required this.startedAt,
    this.completedAt,
  });

  String get eventId => eventIdFor(compactionId, status);

  static String eventIdFor(String compactionId, CompactionStatus status) =>
      'context_compaction:$compactionId:${status.wireValue}';
}

/// Session-scoped compaction orchestration (Plan 53d).
class CompactionCoordinator {
  final ContextCompactionEngine _engine;
  final CompactionBoundaryRepository _boundaries;
  final CompactionActivationService _activation;
  final ModelProjectionBuilder _projectionBuilder;
  final SessionProjectionRevisionRepository? _projectionRevisions;
  final AgentRuntimeService? _runtime;
  final void Function(CompactionLifecycleEvent event)? onLifecycleEvent;

  CompactionCoordinator({
    required ContextCompactionEngine engine,
    required CompactionBoundaryRepository boundaries,
    required CompactionActivationService activation,
    required ModelProjectionBuilder projectionBuilder,
    SessionProjectionRevisionRepository? projectionRevisions,
    AgentRuntimeService? runtime,
    this.onLifecycleEvent,
  }) : _engine = engine,
       _boundaries = boundaries,
       _activation = activation,
       _projectionBuilder = projectionBuilder,
       _projectionRevisions = projectionRevisions,
       _runtime = runtime;

  ModelProjectionBuilder get projectionBuilder => _projectionBuilder;

  /// Reconciles the immutable compaction estimate with the first provider
  /// response that used its projection, then republishes the same completed
  /// logical event so live clients advance from estimated to confirmed.
  bool reconcileProviderUsage({
    required String compactionId,
    required int inputTokens,
  }) {
    final record = _boundaries.reconcileProviderUsage(
      compactionId: compactionId,
      inputTokens: inputTokens,
    );
    if (record == null ||
        record.metrics == null ||
        record.completedAt == null) {
      return false;
    }
    _emit(
      CompactionLifecycleEvent(
        compactionId: record.compactionId,
        sessionId: record.sessionId,
        trigger: record.trigger,
        status: CompactionStatus.completed,
        metrics: record.metrics,
        providerInstanceId: record.routeSignature.providerInstanceId,
        modelId: record.routeSignature.modelId,
        startedAt: record.startedAt,
        completedAt: record.completedAt,
      ),
    );
    return true;
  }

  /// Binds the confirmed post-boundary usage to the exact compaction boundary
  /// and turn request that used it, enforcing route matching and first-call immutability.
  bool reconcilePostBoundaryUsage({
    required String compactionId,
    required String requestId,
    required DateTime observedAt,
    required int inputTokens,
    int? cachedTokens,
    required RouteSignature routeSignature,
  }) {
    final record = _boundaries.reconcilePostBoundaryUsage(
      compactionId: compactionId,
      requestId: requestId,
      observedAt: observedAt,
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      routeSignature: routeSignature,
    );
    if (record == null ||
        record.metrics == null ||
        record.completedAt == null) {
      return false;
    }
    _emit(
      CompactionLifecycleEvent(
        compactionId: record.compactionId,
        sessionId: record.sessionId,
        trigger: record.trigger,
        status: CompactionStatus.completed,
        metrics: record.metrics,
        providerInstanceId: record.routeSignature.providerInstanceId,
        modelId: record.routeSignature.modelId,
        startedAt: record.startedAt,
        completedAt: record.completedAt,
      ),
    );
    return true;
  }

  /// Explicitly records that provider usage was missing on the post-boundary call.
  /// Immutably reserves the exact first dispatched request/step for post-boundary reconciliation.
  bool reservePostBoundaryDispatch({
    required String compactionId,
    required String requestId,
    required RouteSignature routeSignature,
    required DateTime dispatchedAt,
  }) {
    final record = _boundaries.reservePostBoundaryDispatch(
      compactionId: compactionId,
      requestId: requestId,
      routeSignature: routeSignature,
      dispatchedAt: dispatchedAt,
    );
    return record != null;
  }

  bool recordPostBoundaryMissingUsage({
    required String compactionId,
    required String requestId,
    required DateTime observedAt,
    required String missingReason,
    required RouteSignature routeSignature,
  }) {
    final record = _boundaries.recordPostBoundaryMissingUsage(
      compactionId: compactionId,
      requestId: requestId,
      observedAt: observedAt,
      missingReason: missingReason,
      routeSignature: routeSignature,
    );
    return record != null;
  }

  bool reconcileLatestProviderUsage({
    required String sessionId,
    required RouteSignature routeSignature,
    required int inputTokens,
  }) {
    for (final record in _boundaries.listCompletedForSession(sessionId)) {
      final metrics = record.metrics;
      if (record.routeSignature == routeSignature &&
          metrics != null &&
          metrics.providerConfirmedRequestTokensAfter == null) {
        final now = DateTime.now().toUtc();
        _boundaries.reservePostBoundaryDispatch(
          compactionId: record.compactionId,
          requestId: 'reconcile_latest',
          routeSignature: routeSignature,
          dispatchedAt: now,
        );
        return reconcilePostBoundaryUsage(
          compactionId: record.compactionId,
          requestId: 'reconcile_latest',
          observedAt: now,
          inputTokens: inputTokens,
          routeSignature: routeSignature,
        );
      }
    }
    return false;
  }

  Future<CompactionOutcome?> runCompaction({
    required CompactionEngineRequest request,
    bool force = false,
  }) async {
    final compactionId = request.compactionId.isNotEmpty
        ? request.compactionId
        : const Uuid().v4();
    final engineRequest = CompactionEngineRequest(
      compactionId: compactionId,
      sessionId: request.sessionId,
      trigger: request.trigger,
      sourceRevision: request.sourceRevision,
      routeSignature: request.routeSignature,
      contextWindowTokens: request.contextWindowTokens,
      inputLimitTokens: request.inputLimitTokens,
      confirmedInputUsage: request.confirmedInputUsage,
      preflightPressure: request.preflightPressure,
      timeline: request.timeline,
      systemPrompt: request.systemPrompt,
      runtimeContext: request.runtimeContext,
      toolSchemas: request.toolSchemas,
      providerProjection: request.providerProjection,
      providerTools: request.providerTools,
      providerRequestOptions: request.providerRequestOptions,
      projectionRevision: request.projectionRevision,
      previousSummary: request.previousSummary,
      previousSourceRange: request.previousSourceRange,
      targetRequestTokens: request.targetRequestTokens,
      thresholdRatio: request.thresholdRatio,
      targetRatio: request.targetRatio,
      wireMeter: request.wireMeter ?? _wireMeterFor(request),
    );

    // Measuring precedes selection; selection and the claim stay synchronous.
    final measurement = await _engine.measureRequest(engineRequest);
    final selection = _engine.prepareSelection(
      engineRequest,
      force: force,
      measurement: measurement,
    );
    if (selection == null) return null;

    final startedAt = DateTime.now().toUtc();
    final claim = _boundaries.tryClaim(
      compactionId: compactionId,
      sessionId: request.sessionId,
      trigger: request.trigger,
      sourceRange: selection.sourceRange,
      retainedTailRange: selection.retainedTailRange,
      routeSignature: request.routeSignature,
      startedAt: startedAt,
    );
    if (claim.outcome != CompactionClaimOutcome.claimed) {
      return CompactionOutcome.failed(
        compactionId: compactionId,
        trigger: request.trigger,
        failureReason:
            claim.outcome == CompactionClaimOutcome.compactionInProgress
            ? CompactionFailureReason.compactionInProgress
            : CompactionFailureReason.claimLost,
      );
    }

    _emit(
      CompactionLifecycleEvent(
        compactionId: compactionId,
        sessionId: request.sessionId,
        trigger: request.trigger,
        status: CompactionStatus.started,
        providerInstanceId: request.routeSignature.providerInstanceId,
        modelId: request.routeSignature.modelId,
        startedAt: startedAt,
      ),
    );

    CompactionCandidate candidate;
    try {
      final built = await _engine.buildCandidate(
        engineRequest,
        force: force,
        preparedSelection: selection,
      );
      if (built == null) {
        return _failClaimed(
          request: request,
          compactionId: compactionId,
          startedAt: startedAt,
          failureReason: CompactionFailureReason.summarizationFailed,
          failureStage: CompactionFailureStage.provider,
          failureCause: CompactionFailureCause.summarizationFailed,
        );
      }
      candidate = built;
    } on CompactionEngineFailure catch (error) {
      final diagnostics = CompactionDiagnostics.classify(error);
      return _failClaimed(
        request: request,
        compactionId: compactionId,
        failureReason: error.reason,
        failureStage: error.stage ?? diagnostics.stage,
        failureCause: error.cause ?? diagnostics.cause,
        startedAt: startedAt,
        diagnostics: error.diagnostics,
      );
    } catch (error) {
      final diagnostics = CompactionDiagnostics.classify(error);
      return _failClaimed(
        request: request,
        compactionId: compactionId,
        failureReason: diagnostics.failureReason,
        failureStage: diagnostics.stage,
        failureCause: diagnostics.cause,
        startedAt: startedAt,
      );
    }

    if (!_activationFenceMatches(request)) {
      return _failClaimed(
        request: request,
        compactionId: compactionId,
        startedAt: startedAt,
        failureReason: CompactionFailureReason.sourceRevisionStale,
        failureStage: CompactionFailureStage.persistence,
        failureCause: CompactionFailureCause.sourceRevisionStale,
      );
    }
    final activation = _activation.activateCandidate(
      candidate: candidate.copyWithCompactionId(compactionId),
      startedAt: startedAt,
      completedAt: DateTime.now().toUtc(),
    );
    if (activation.outcome != CompactionTerminalOutcome.completed) {
      final cause = switch (activation.outcome) {
        CompactionTerminalOutcome.sourceRevisionStale =>
          CompactionFailureCause.sourceRevisionStale,
        CompactionTerminalOutcome.staleOperation =>
          CompactionFailureCause.staleOperation,
        CompactionTerminalOutcome.supersededByNewerBoundary =>
          CompactionFailureCause.superseded,
        CompactionTerminalOutcome.missingMessageRows =>
          CompactionFailureCause.missingMessageRows,
        _ => CompactionFailureCause.persistenceFailed,
      };
      final detail = {
        'stage': CompactionFailureStage.persistence,
        'cause': cause,
        'activation_outcome': activation.outcome.name,
      };
      _activation.failOperation(
        compactionId: compactionId,
        failureReason: CompactionFailureReason.persistenceFailed,
        completedAt: DateTime.now().toUtc(),
        failureDetail: detail,
      );
      _emit(
        CompactionLifecycleEvent(
          compactionId: compactionId,
          sessionId: request.sessionId,
          trigger: request.trigger,
          status: CompactionStatus.failed,
          failureReason: CompactionFailureReason.persistenceFailed,
          failureStage: CompactionFailureStage.persistence,
          failureCause: cause,
          failureDetail: detail,
          providerInstanceId: request.routeSignature.providerInstanceId,
          modelId: request.routeSignature.modelId,
          startedAt: startedAt,
          completedAt: DateTime.now().toUtc(),
        ),
      );
      return CompactionOutcome.failed(
        compactionId: compactionId,
        trigger: request.trigger,
        failureReason: CompactionFailureReason.persistenceFailed,
        failureStage: CompactionFailureStage.persistence,
        failureCause: cause,
        failureDetail: detail,
      );
    }

    _emit(
      CompactionLifecycleEvent(
        compactionId: compactionId,
        sessionId: request.sessionId,
        trigger: request.trigger,
        status: CompactionStatus.completed,
        metrics: candidate.metrics,
        providerInstanceId: request.routeSignature.providerInstanceId,
        modelId: request.routeSignature.modelId,
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
      ),
    );
    return CompactionOutcome.completed(candidate: candidate);
  }

  /// The active route's own wire measurement of a provider projection, with
  /// the request's exact tools and options (Task 118 Stage3A), or `null` when
  /// the route's adapter cannot measure its wire projection.
  CompactionWireMeter? _wireMeterFor(CompactionEngineRequest request) {
    final runtime = _runtime;
    if (runtime == null) return null;
    final LLMAdapter adapter;
    try {
      adapter = runtime.adapterFor(request.routeSignature);
    } catch (_) {
      return null;
    }
    final provider = adapter is RateLimitedLLMAdapter
        ? adapter.providerAdapter
        : adapter;
    if (provider is! WireInputUsageMeasurer) return null;
    final measurer = provider as WireInputUsageMeasurer;
    return (projection) => measurer.measureInput(
      projection,
      tools: request.providerTools,
      modelOverride: request.routeSignature.modelId,
      options: request.providerRequestOptions,
    );
  }

  bool _activationFenceMatches(CompactionEngineRequest request) {
    final projections = _projectionRevisions;
    if (projections != null) {
      final current = projections.read(request.sessionId);
      if (current == null || current.value != request.projectionRevision) {
        return false;
      }
    }
    final runtime = _runtime;
    if (runtime != null) {
      try {
        final current = runtime.resolveSignature(
          providerId: request.routeSignature.providerInstanceId,
          modelId: request.routeSignature.modelId,
        );
        if (current != request.routeSignature) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  void _emit(CompactionLifecycleEvent event) {
    onLifecycleEvent?.call(event);
  }

  CompactionOutcome _failClaimed({
    required CompactionEngineRequest request,
    required String compactionId,
    required DateTime startedAt,
    required CompactionFailureReason failureReason,
    String? failureStage,
    String? failureCause,
    Map<String, dynamic>? failureDetail,
    CompactionDurableDiagnostics? diagnostics,
  }) {
    final completedAt = DateTime.now().toUtc();
    final detail = <String, dynamic>{
      'stage': ?failureStage,
      'cause': ?failureCause,
      ...?failureDetail,
    };
    _activation.failOperation(
      compactionId: compactionId,
      failureReason: failureReason,
      completedAt: completedAt,
      failureDetail: detail.isNotEmpty ? detail : null,
      diagnostics: diagnostics,
    );
    _emit(
      CompactionLifecycleEvent(
        compactionId: compactionId,
        sessionId: request.sessionId,
        trigger: request.trigger,
        status: CompactionStatus.failed,
        failureReason: failureReason,
        failureStage: failureStage,
        failureCause: failureCause,
        failureDetail: detail.isNotEmpty ? detail : null,
        providerInstanceId: request.routeSignature.providerInstanceId,
        modelId: request.routeSignature.modelId,
        startedAt: startedAt,
        completedAt: completedAt,
      ),
    );
    return CompactionOutcome.failed(
      compactionId: compactionId,
      trigger: request.trigger,
      failureReason: failureReason,
      failureStage: failureStage,
      failureCause: failureCause,
      failureDetail: detail.isNotEmpty ? detail : null,
    );
  }
}

extension on CompactionCandidate {
  CompactionCandidate copyWithCompactionId(String compactionId) {
    return CompactionCandidate(
      compactionId: compactionId,
      sessionId: sessionId,
      trigger: trigger,
      sourceRevision: sourceRevision,
      sourceRange: sourceRange,
      retainedTailRange: retainedTailRange,
      internalSummary: internalSummary,
      continuityResult: continuityResult,
      metrics: metrics,
      routeSignature: routeSignature,
      diagnostics: diagnostics,
    );
  }
}
