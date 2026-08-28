import '../../core/di.dart';
import '../../core/secrets_redactor.dart';
import '../../core/models/tool_call.dart';
import '../../evolution/db/persisted_runtime_state_repository.dart';
import 'deferred_tool_result.dart';

/// Builds, persists, and restores per-turn continuation checkpoints so a
/// daemon crash mid-tool-batch can be safely resumed without replaying
/// non-idempotent side effects or corrupting history.
///
/// **Ownership boundaries (Gate C refactor):**
/// - The coordinator owns the *schema* and *write/read* logic for checkpoint
///   metadata stored on the active `SessionWorkItem`. It is the single writer
///   to `continuation_metadata` checkpoint fields.
/// - It does **not** own `history` or `_currentTurnStartIndex`. Those live on
///   `AgentRunner`. The runner passes the current values in via the
///   [CheckpointContext] record and receives restored values via [ResumeResult].
/// - No independent source of truth is created: the coordinator reads the
///   active work item from `PersistedRuntimeStateRepository` (the existing
///   persistence owner) and writes back to the same item.
///
/// All public methods are no-ops when no `PersistedRuntimeStateRepository` is
/// registered in DI (e.g. isolated unit tests that don't test durability).
class ContinuationCheckpointCoordinator {
  static const String checkpointKindModelRequestInFlight =
      'model_request_in_flight';
  static const String checkpointKindInitialModelRequest =
      'initial_model_request';
  static const String checkpointKindAfterToolResult = 'after_tool_result';

  /// Allowed checkpoint kinds for safe resume (Gate D.1).
  static const Set<String> _allowedKinds = {
    checkpointKindInitialModelRequest,
    checkpointKindAfterToolResult,
  };

  final String sessionId;

  /// Secrets redactor applied to every tool-output record persisted in the
  /// checkpoint so replay/diagnostics never leak credentials.
  final SecretsRedactor _secretsRedactor;

  ContinuationCheckpointCoordinator({
    required this.sessionId,
    SecretsRedactor? secretsRedactor,
  }) : _secretsRedactor = secretsRedactor ?? const SecretsRedactor();

  /// Lazily resolves the repository, returning null when unregistered so
  /// isolated tests (and non-durable runs) silently skip checkpointing.
  PersistedRuntimeStateRepository? get _repo =>
      getIt.isRegistered<PersistedRuntimeStateRepository>()
      ? getIt<PersistedRuntimeStateRepository>()
      : null;

  /// Saves (or merges) checkpoint metadata onto the active work item.
  ///
  /// Passing [ctx] keeps the coordinator free of history ownership: the
  /// runner supplies the live `historyLength`-independent values it needs
  /// persisted (turn start index, model-step id).
  void saveCheckpoint({
    required CheckpointContext ctx,
    List<String>? currentlyExecutingToolCallIds,
    Map<String, String>? additionalToolResults,
    Map<String, Map<String, dynamic>>? additionalToolOutputs,
    Map<String, Map<String, dynamic>>? additionalDeferredToolResults,
    Iterable<String>? removeDeferredToolCallIds,
    Map<String, bool>? toolReplaySafety,
    String? checkpointKind,
    int? resumeHistoryLength,
  }) {
    final repo = _repo;
    if (repo == null) return;

    final activeItem = repo.findActiveWorkItem(sessionId);
    if (activeItem == null) return;

    final meta = Map<String, dynamic>.from(activeItem.continuationMetadata);

    meta['currentTurnStartIndex'] = ctx.currentTurnStartIndex;
    if (ctx.currentModelStepId != null) {
      meta['model_step_id'] = ctx.currentModelStepId;
    }
    if (checkpointKind != null) {
      if (checkpointKind == checkpointKindModelRequestInFlight &&
          meta['checkpoint_kind'] != checkpointKindModelRequestInFlight) {
        meta['checkpoint_before_model_request'] = meta['checkpoint_kind'];
      } else if (checkpointKind != checkpointKindModelRequestInFlight) {
        meta.remove('checkpoint_before_model_request');
      }
      meta['checkpoint_kind'] = checkpointKind;
    }
    if (resumeHistoryLength != null) {
      meta['resume_history_length'] = resumeHistoryLength;
    }

    final results = Map<String, dynamic>.from(
      meta['completed_tool_results'] as Map? ?? const {},
    );
    if (additionalToolResults != null) {
      results.addAll(additionalToolResults);
    }
    meta['completed_tool_results'] = results;

    final outputs = Map<String, dynamic>.from(
      meta['completed_tool_outputs'] as Map? ?? const {},
    );
    if (additionalToolOutputs != null) {
      outputs.addAll(
        additionalToolOutputs.map(
          (key, value) => MapEntry(key, _redactedToolOutput(value)),
        ),
      );
    }
    if (outputs.isNotEmpty) {
      meta['completed_tool_outputs'] = outputs;
    }

    final deferredResults = Map<String, dynamic>.from(
      meta['deferred_tool_results'] as Map? ?? const {},
    );
    if (additionalDeferredToolResults != null) {
      deferredResults.addAll(additionalDeferredToolResults);
    }
    if (removeDeferredToolCallIds != null) {
      for (final toolCallId in removeDeferredToolCallIds) {
        deferredResults.remove(toolCallId);
      }
    }
    if (deferredResults.isEmpty) {
      meta.remove('deferred_tool_results');
    } else {
      meta['deferred_tool_results'] = deferredResults;
    }

    if (currentlyExecutingToolCallIds != null &&
        currentlyExecutingToolCallIds.isNotEmpty) {
      meta['currently_executing_tools'] = currentlyExecutingToolCallIds;
      final startedAt = Map<String, dynamic>.from(
        meta['tool_started_at'] as Map? ?? const {},
      );
      final now = DateTime.now().toUtc().toIso8601String();
      for (final toolCallId in currentlyExecutingToolCallIds) {
        startedAt.putIfAbsent(toolCallId, () => now);
      }
      startedAt.removeWhere(
        (toolCallId, _) => !currentlyExecutingToolCallIds.contains(toolCallId),
      );
      meta['tool_started_at'] = startedAt;
    } else {
      meta.remove('currently_executing_tools');
      if (currentlyExecutingToolCallIds != null) {
        meta.remove('tool_started_at');
      }
    }

    final replaySafety = Map<String, dynamic>.from(
      meta['tool_replay_safety'] as Map? ?? const {},
    );
    if (toolReplaySafety != null) {
      replaySafety.addAll(toolReplaySafety);
    }
    if (replaySafety.isNotEmpty) {
      meta['tool_replay_safety'] = replaySafety;
    }

    repo.transitionWorkItemState(
      workItemId: activeItem.workItemId,
      fromState: activeItem.state,
      toState: activeItem.state,
      continuationMetadata: meta,
    );
  }

  /// Restores the checkpoint that owned progression before the provider call.
  ///
  /// This is valid after either a durable provider response or a known request
  /// failure. A restart-timeout interruption keeps the in-flight marker so its
  /// unknown provider outcome cannot be mistaken for replay-safe work.
  void markModelRequestSettled({required CheckpointContext ctx}) {
    final repo = _repo;
    if (repo == null) return;
    final activeItem = repo.findActiveWorkItem(sessionId);
    if (activeItem == null) return;
    final meta = Map<String, dynamic>.from(activeItem.continuationMetadata);
    if (meta['checkpoint_kind'] != checkpointKindModelRequestInFlight ||
        meta['restart_interrupted_provider_request'] == true) {
      return;
    }
    final previousKind = meta
        .remove('checkpoint_before_model_request')
        ?.toString();
    meta['checkpoint_kind'] = previousKind == checkpointKindAfterToolResult
        ? checkpointKindAfterToolResult
        : checkpointKindInitialModelRequest;
    meta['currentTurnStartIndex'] = ctx.currentTurnStartIndex;
    if (ctx.currentModelStepId != null) {
      meta['model_step_id'] = ctx.currentModelStepId;
    }
    repo.transitionWorkItemState(
      workItemId: activeItem.workItemId,
      fromState: activeItem.state,
      toState: activeItem.state,
      continuationMetadata: meta,
    );
  }

  /// Restores checkpoint state for a resume operation.
  ///
  /// Validates the persisted checkpoint is safe to resume from (Gate D.1/D.2)
  /// and returns the values the runner needs to trim/restore its own state.
  /// Throws [StateError] on any unsafe resume condition. The caller is
  /// responsible for applying [ResumeResult] to its own history/index.
  ///
  /// [currentHistoryLength] is the runner's live history length, used to
  /// validate the persisted `resume_history_length` is still consistent.
  ResumeResult restoreCheckpointForResume({
    required int currentHistoryLength,
    bool allowAmbiguousToolInterruption = false,
  }) {
    final repo = _repo;
    if (repo == null) {
      return ResumeResult.empty;
    }

    final activeItem = repo.findActiveWorkItem(sessionId);
    if (activeItem == null) {
      return ResumeResult.empty;
    }

    final meta = Map<String, dynamic>.from(activeItem.continuationMetadata);
    final checkpointKind = meta['checkpoint_kind']?.toString();

    // Gate D.1: never classify an ambiguous event as one of the safe kinds.
    if (checkpointKind == null || !_allowedKinds.contains(checkpointKind)) {
      throw StateError(
        'Cannot safely resume session $sessionId without a recognized checkpoint kind.',
      );
    }

    // Gate D.2: do not resume a side-effect tool call without a trustworthy
    // checkpoint (completed result) or idempotency contract.
    final currentlyExecuting = List<String>.from(
      meta['currently_executing_tools'] as List? ?? const [],
    );
    final completedResults = Map<String, dynamic>.from(
      meta['completed_tool_results'] as Map? ?? const {},
    );
    final toolReplaySafety = Map<String, dynamic>.from(
      meta['tool_replay_safety'] as Map? ?? const {},
    );
    final ambiguousToolCallIds = <String>[];
    final deferredToolCallIds = <String>[];
    final deferredResults = Map<String, dynamic>.from(
      meta['deferred_tool_results'] as Map? ?? const {},
    );
    for (final toolId in currentlyExecuting) {
      if (completedResults.containsKey(toolId)) continue;
      final deferred = DeferredToolResultDescriptor.tryParseMetadata(
        deferredResults[toolId],
      );
      if (deferred != null &&
          deferred.requesterSessionId == sessionId &&
          deferred.requesterToolCallId == toolId) {
        deferredToolCallIds.add(toolId);
        continue;
      }
      final isReplaySafe = toolReplaySafety[toolId] == true;
      if (!isReplaySafe) {
        if (allowAmbiguousToolInterruption) {
          ambiguousToolCallIds.add(toolId);
          continue;
        }
        throw StateError(
          'Cannot safely resume session $sessionId: tool $toolId has ambiguous execution state and is not idempotent.',
        );
      }
    }

    final resumeHistoryLengthRaw = meta['resume_history_length'];
    final resumeHistoryLength = switch (resumeHistoryLengthRaw) {
      int() => resumeHistoryLengthRaw,
      String() => int.tryParse(resumeHistoryLengthRaw),
      _ => null,
    };
    if (resumeHistoryLength == null ||
        resumeHistoryLength < 0 ||
        resumeHistoryLength > currentHistoryLength) {
      throw StateError(
        'Cannot safely resume session $sessionId with invalid checkpoint history length.',
      );
    }

    final savedTurnStartRaw = meta['currentTurnStartIndex'];
    final savedTurnStart = switch (savedTurnStartRaw) {
      int() => savedTurnStartRaw,
      String() => int.tryParse(savedTurnStartRaw),
      _ => null,
    };

    final savedModelStepId =
        (meta['model_step_id'] ?? meta['currentModelRunId'])?.toString();

    return ResumeResult(
      resumeHistoryLength: resumeHistoryLength,
      ambiguousToolCallIds: ambiguousToolCallIds,
      deferredToolCallIds: deferredToolCallIds,
      savedTurnStartIndex:
          (savedTurnStart != null &&
              savedTurnStart >= 0 &&
              savedTurnStart <= currentHistoryLength)
          ? savedTurnStart
          : null,
      savedModelStepId:
          (savedModelStepId != null && savedModelStepId.isNotEmpty)
          ? savedModelStepId
          : null,
    );
  }

  /// Converts a tool execution failure into a durable blocked state instead
  /// of silently swallowing the work item (Gate D.3).
  ///
  /// Called when resume or checkpoint restoration fails. Leaves the active
  /// work item in `blocked` so the user can act on it.
  void blockWorkItemOnResumeFailure(Object error) {
    final repo = _repo;
    if (repo == null) return;
    final activeItem = repo.findActiveWorkItem(sessionId);
    if (activeItem == null) return;

    const allowedBlockedFrom = {
      SessionWorkState.running,
      SessionWorkState.resuming,
      SessionWorkState.waiting,
    };
    if (!allowedBlockedFrom.contains(activeItem.state)) return;

    final meta = Map<String, dynamic>.from(activeItem.continuationMetadata);
    meta['resume_failure_reason'] = error.toString();

    repo.transitionWorkItemState(
      workItemId: activeItem.workItemId,
      fromState: activeItem.state,
      toState: SessionWorkState.blocked,
      continuationMetadata: meta,
    );
  }

  /// Builds a redacted tool-output record for checkpoint persistence.
  Map<String, dynamic> toolOutputRecord(
    ToolCall toolCall,
    String result, {
    required bool isError,
    required bool sentToProvider,
  }) {
    return _redactedToolOutput({
      'tool_call_id': toolCall.id,
      'tool_name': toolCall.name,
      'arguments': toolCall.arguments,
      'result': result,
      'is_error': isError,
      'sent_to_provider': sentToProvider,
    });
  }

  Map<String, dynamic> _redactedToolOutput(Map<String, dynamic> output) =>
      _secretsRedactor.redactMap(output);
}

/// Snapshot of runner-owned state passed into checkpoint saves so the
/// coordinator never holds a reference to `history` or the runner itself.
typedef CheckpointContext = ({
  int currentTurnStartIndex,
  String? currentModelStepId,
});

/// Values restored from a persisted checkpoint that the runner applies to its
/// own state (history trimming, turn index, model-step id).
class ResumeResult {
  final int resumeHistoryLength;
  final int? savedTurnStartIndex;
  final String? savedModelStepId;
  final List<String> ambiguousToolCallIds;
  final List<String> deferredToolCallIds;

  const ResumeResult({
    required this.resumeHistoryLength,
    this.savedTurnStartIndex,
    this.savedModelStepId,
    this.ambiguousToolCallIds = const [],
    this.deferredToolCallIds = const [],
  });

  static const ResumeResult empty = ResumeResult(resumeHistoryLength: -1);
}
