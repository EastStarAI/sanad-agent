import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
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
  final CompactionMetrics? metrics;
  final DateTime startedAt;
  final DateTime? completedAt;

  const CompactionLifecycleEvent({
    required this.compactionId,
    required this.sessionId,
    required this.trigger,
    required this.status,
    this.failureReason,
    this.metrics,
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
  final void Function(CompactionLifecycleEvent event)? onLifecycleEvent;

  CompactionCoordinator({
    required ContextCompactionEngine engine,
    required CompactionBoundaryRepository boundaries,
    required CompactionActivationService activation,
    required ModelProjectionBuilder projectionBuilder,
    this.onLifecycleEvent,
  }) : _engine = engine,
       _boundaries = boundaries,
       _activation = activation,
       _projectionBuilder = projectionBuilder;

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
        startedAt: record.startedAt,
        completedAt: record.completedAt,
      ),
    );
    return true;
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
        return reconcileProviderUsage(
          compactionId: record.compactionId,
          inputTokens: inputTokens,
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
      previousSummary: request.previousSummary,
      previousSourceRange: request.previousSourceRange,
      targetRequestTokens: request.targetRequestTokens,
      thresholdRatio: request.thresholdRatio,
    );

    final selection = _engine.prepareSelection(engineRequest, force: force);
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
        );
      }
      candidate = built;
    } on CompactionEngineFailure catch (error) {
      return _failClaimed(
        request: request,
        compactionId: compactionId,
        failureReason: error.reason,
        startedAt: startedAt,
      );
    } catch (_) {
      return _failClaimed(
        request: request,
        compactionId: compactionId,
        failureReason: CompactionFailureReason.summarizationFailed,
        startedAt: startedAt,
      );
    }

    final activation = _activation.activateCandidate(
      candidate: candidate.copyWithCompactionId(compactionId),
      startedAt: startedAt,
      completedAt: DateTime.now().toUtc(),
    );
    if (activation.outcome != CompactionTerminalOutcome.completed) {
      _activation.failOperation(
        compactionId: compactionId,
        failureReason: CompactionFailureReason.persistenceFailed,
        completedAt: DateTime.now().toUtc(),
        failureDetail: {'activation_outcome': activation.outcome.name},
      );
      _emit(
        CompactionLifecycleEvent(
          compactionId: compactionId,
          sessionId: request.sessionId,
          trigger: request.trigger,
          status: CompactionStatus.failed,
          failureReason: CompactionFailureReason.persistenceFailed,
          startedAt: startedAt,
          completedAt: DateTime.now().toUtc(),
        ),
      );
      return CompactionOutcome.failed(
        compactionId: compactionId,
        trigger: request.trigger,
        failureReason: CompactionFailureReason.persistenceFailed,
      );
    }

    _emit(
      CompactionLifecycleEvent(
        compactionId: compactionId,
        sessionId: request.sessionId,
        trigger: request.trigger,
        status: CompactionStatus.completed,
        metrics: candidate.metrics,
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
      ),
    );
    return CompactionOutcome.completed(candidate: candidate);
  }

  void _emit(CompactionLifecycleEvent event) {
    onLifecycleEvent?.call(event);
  }

  CompactionOutcome _failClaimed({
    required CompactionEngineRequest request,
    required String compactionId,
    required DateTime startedAt,
    required CompactionFailureReason failureReason,
  }) {
    final completedAt = DateTime.now().toUtc();
    _activation.failOperation(
      compactionId: compactionId,
      failureReason: failureReason,
      completedAt: completedAt,
    );
    _emit(
      CompactionLifecycleEvent(
        compactionId: compactionId,
        sessionId: request.sessionId,
        trigger: request.trigger,
        status: CompactionStatus.failed,
        failureReason: failureReason,
        startedAt: startedAt,
        completedAt: completedAt,
      ),
    );
    return CompactionOutcome.failed(
      compactionId: compactionId,
      trigger: request.trigger,
      failureReason: failureReason,
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
    );
  }
}
