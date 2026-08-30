import 'package:meta/meta.dart';
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
  })  : _engine = engine,
        _boundaries = boundaries,
        _activation = activation,
        _projectionBuilder = projectionBuilder;

  ModelProjectionBuilder get projectionBuilder => _projectionBuilder;

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
      confirmedInputTokens: request.confirmedInputTokens,
      timeline: request.timeline,
      systemPrompt: request.systemPrompt,
      runtimeContext: request.runtimeContext,
      toolSchemas: request.toolSchemas,
      previousSummary: request.previousSummary,
      targetRequestTokens: request.targetRequestTokens,
    );

    if (!force) {
      final pressure = _engine.measurePressure(engineRequest);
      if (!pressure.exceedsThreshold &&
          pressure.estimatedRequestTokens <= engineRequest.targetRequestTokens) {
        return null;
      }
    }

    CompactionCandidate candidate;
    try {
      final built = await _engine.buildCandidate(engineRequest, force: force);
      if (built == null) {
        return null;
      }
      candidate = built;
    } on CompactionEngineFailure catch (error) {
      if (force &&
          request.trigger == CompactionTrigger.manual &&
          error.reason == CompactionFailureReason.projectionStillOverBudget) {
        return null;
      }
      return CompactionOutcome.failed(
        compactionId: compactionId,
        trigger: request.trigger,
        failureReason: error.reason,
      );
    }

    final startedAt = DateTime.now().toUtc();
    final claim = _boundaries.tryClaim(
      compactionId: compactionId,
      sessionId: request.sessionId,
      trigger: request.trigger,
      sourceRange: candidate.sourceRange,
      retainedTailRange: candidate.retainedTailRange,
      routeSignature: request.routeSignature,
      startedAt: startedAt,
    );
    if (claim.outcome != CompactionClaimOutcome.claimed) {
      return CompactionOutcome.failed(
        compactionId: compactionId,
        trigger: request.trigger,
        failureReason: claim.outcome == CompactionClaimOutcome.compactionInProgress
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
