import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context_compaction_engine.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:uuid/uuid.dart';

import 'local_runtime_orchestrator.dart';

/// Admits one manual `/compact` request for an idle session and reports the
/// typed outcome the command answers with.
///
/// Admission reads the session's provider projection, ordinary tool list, and
/// request settings from a session-scoped `AgentRunner` seed without admitting
/// or inventing a user turn. The orchestrator stays the sole admission and
/// active-run authority: it supplies the busy and compaction-barrier
/// projections, and it owns the compaction-owner entry that keeps queued work
/// blocked for the duration of the mutation.
class SessionCompactAdmission {
  const SessionCompactAdmission({
    required bool Function(String sessionId) isSessionBusy,
    required bool Function(String sessionId) isSessionCompacting,
    required void Function(String sessionId, String compactionId)
    beginCompaction,
    required void Function(String sessionId, String compactionId)
    releaseCompaction,
  }) : _isSessionBusy = isSessionBusy,
       _isSessionCompacting = isSessionCompacting,
       _beginCompaction = beginCompaction,
       _releaseCompaction = releaseCompaction;

  final bool Function(String sessionId) _isSessionBusy;
  final bool Function(String sessionId) _isSessionCompacting;
  final void Function(String sessionId, String compactionId) _beginCompaction;
  final void Function(String sessionId, String compactionId) _releaseCompaction;

  /// Plan 53d — manual `/compact` admission when the session is idle.
  Future<Map<String, dynamic>> admit({
    required String sessionId,
    required String requestId,
  }) async {
    if (_isSessionBusy(sessionId)) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': CompactionFailureReason.sessionBusy.wireValue,
        'failure_reason': CompactionFailureReason.sessionBusy.wireValue,
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.sessionBusy,
      };
    }
    if (_isSessionCompacting(sessionId)) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': CompactionFailureReason.compactionInProgress.wireValue,
        'failure_reason': CompactionFailureReason.compactionInProgress.wireValue,
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.compactionInProgress,
      };
    }
    if (getIt.isRegistered<CompactionBoundaryRepository>()) {
      final started = getIt<CompactionBoundaryRepository>()
          .findStartedForSession(sessionId);
      if (started != null) {
        return {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': CompactionFailureReason.compactionInProgress.wireValue,
          'failure_reason': CompactionFailureReason.compactionInProgress.wireValue,
          'failure_stage': CompactionFailureStage.preparation,
          'failure_cause': CompactionFailureCause.compactionInProgress,
        };
      }
    }
    if (!getIt.isRegistered<CompactionCoordinator>() ||
        !getIt.isRegistered<CompactionBoundaryRepository>()) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'unavailable',
        'failure_reason': 'unavailable',
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.unavailable,
      };
    }

    final compactionId = const Uuid().v4();
    final CompactionEngineRequest? engineRequest;
    try {
      final compactionRunner = getIt<AgentRunner>(param1: sessionId);
      // Task 118b: the seed carries the per-turn tools and runtime context of
      // the next ordinary request, so its fixed overhead is what that request
      // will transmit and the summary pass keeps the ordinary tool list.
      final runtimeSystemPrompt =
          getIt.isRegistered<LocalRuntimeOrchestrator>()
          ? await getIt<LocalRuntimeOrchestrator>().prepareIdleRequest(
              agentRunner: compactionRunner,
              sessionId: sessionId,
            )
          : null;
      final providerSeed = await compactionRunner.prepareCompactionProviderSeed(
        runtimeSystemPrompt: runtimeSystemPrompt,
      );
      engineRequest = await CompactionRequestFactory.forSession(
        sessionId: sessionId,
        trigger: CompactionTrigger.manual,
        compactionId: compactionId,
        providerProjection: providerSeed.projection,
        providerTools: providerSeed.tools,
        providerRequestOptions: providerSeed.options,
      );
    } catch (error) {
      final diagnostics = CompactionDiagnostics.classify(
        error,
        stageHint: CompactionFailureStage.preparation,
      );
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'failed',
        'failure_reason': diagnostics.failureReason.wireValue,
        'failure_stage': diagnostics.stage,
        'failure_cause': diagnostics.cause,
      };
    }
    if (engineRequest == null) {
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'invalid_request',
        'failure_reason': 'invalid_request',
        'failure_stage': CompactionFailureStage.preparation,
        'failure_cause': CompactionFailureCause.invalidRequest,
      };
    }

    _beginCompaction(sessionId, compactionId);
    try {
      final outcome = await getIt<CompactionCoordinator>().runCompaction(
        request: engineRequest,
        force: true,
      );
      if (outcome == null) {
        return {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': 'no_op',
        };
      }
      if (outcome.status == CompactionStatus.completed) {
        return {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': 'accepted',
          'compaction_id': outcome.compactionId,
        };
      }
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'failed',
        'failure_reason': outcome.failureReason?.wireValue,
        'compaction_id': outcome.compactionId,
        if (outcome.failureStage != null) 'failure_stage': outcome.failureStage,
        if (outcome.failureCause != null) 'failure_cause': outcome.failureCause,
      };
    } catch (error) {
      final diagnostics = CompactionDiagnostics.classify(error);
      return {
        'session_id': sessionId,
        'request_id': requestId,
        'outcome': 'failed',
        'failure_reason': diagnostics.failureReason.wireValue,
        'compaction_id': compactionId,
        'failure_stage': diagnostics.stage,
        'failure_cause': diagnostics.cause,
      };
    } finally {
      _releaseCompaction(sessionId, compactionId);
    }
  }
}
