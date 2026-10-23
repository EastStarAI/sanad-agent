import 'dart:async';

import 'package:logging/logging.dart';

import '../../capabilities/models/tool_schema.dart';
import '../../core/agent_runtime_service.dart';
import '../../core/config.dart';
import '../../core/di.dart';
import '../../core/models/llm_provider_state.dart';
import '../../core/models/message.dart';
import '../../core/provider_runtime/route_capability_resolver.dart';
import '../../core/provider_runtime/runtime_failure_reason.dart';
import '../../core/provider_runtime/runtime_notice.dart';
import '../../core/provider_runtime/runtime_recovery_exception.dart';
import '../../core/provider_runtime/runtime_recovery_service.dart';
import '../../core/provider_thinking/thinking_route_session_sync.dart';
import '../../core/provider_thinking/thinking_wire_vocabulary.dart';
import '../../core/secrets_redactor.dart';
import '../../evolution/compaction/model_projection_builder.dart';
import '../../evolution/db/persisted_runtime_state_repository.dart';
import '../../evolution/db/runtime/session_route_mutation_coordinator.dart';
import '../../evolution/db/session_history_revision_repository.dart';
import '../../evolution/models/session_route_transition.dart';
import '../adapters/llm_http_exception.dart';
import '../adapters/llm_request_options.dart';
import '../adapters/provider_history_projection_exception.dart';
import '../adapters/provider_request_cancelled_exception.dart';
import '../adapters/provider_state_rejected_exception.dart';
import '../adapters/rate_limited_llm_adapter.dart';
import '../compaction/compaction.dart';
import '../context/context.dart';
import 'compaction_coordinator.dart';
import 'response_continuation_coordinator.dart';
import 'turn_route_state.dart';

/// Host interface providing state and callbacks to [RunnerRecoveryCoordinator]
/// so the recovery coordinator does not own the runner or history directly.
abstract class RunnerRecoveryHost {
  String get sessionId;
  String? get authoritativeRunId;
  String? get authoritativeWorkItemId;
  int? get authoritativeGeneration;
  TurnRouteState get turnRoute;
  List<Message> get history;
  set history(List<Message> newHistory);

  /// `message_id` of the newest durable history row; anchors an automatic
  /// failover notice to the timeline position the user saw it at.
  String? latestPersistedMessageId();
  void saveHistory();
  Future<int?> getContextTokens();
  String assembleSystemPrompt();
  List<IndexedConversationMessage> compactionTimelineForSession();
  int currentProjectionRevision();
  LLMRequestOptions compactionRequestOptions(
    String? providerInstanceId, {
    required String compactionId,
  });
  void refreshCanonicalHistoryAfterCompaction();
  bool claimOwnedAutomaticRetry();
  void updateSessionProviderId(String candidateId);

  /// Whether the admitted turn capability profile already belongs to
  /// [providerInstanceId]/[modelId].
  bool turnCapabilityProfileMatchesRoute(
    String? providerInstanceId,
    String? modelId,
  );

  /// Re-resolves the turn capability profile for a recovery route change
  /// (auto-failover candidate or a changed route on a retry wake).
  void resolveTurnCapabilityProfile({
    required String providerInstanceId,
    required String modelId,
  });

  /// Clears the turn capability profile when a retry wake has no route.
  void clearTurnCapabilityProfile();

  /// Per-run automatic-compaction breaker owned by the compaction
  /// orchestrator; overflow compaction is automatic too.
  bool get autoCompactionBlockedForRun;

  /// Opens the per-run automatic-compaction breaker.
  void markCompactionFailure();
}

/// Coordinates runtime error handling, automatic failover, retry budgets,
/// recovery notices, and provider state clearance for the agent runner.
class RunnerRecoveryCoordinator {
  static const SecretsRedactor _secretsRedactor = SecretsRedactor();

  final RunnerRecoveryHost host;
  final Logger _logger;
  bool overflowCompactionRetried = false;

  RunnerRecoveryCoordinator(this.host, {Logger? logger})
    : _logger = logger ?? Logger('RunnerRecoveryCoordinator');

  RuntimeRecoveryService? get _recoveryService =>
      getIt.isRegistered<RuntimeRecoveryService>()
      ? getIt<RuntimeRecoveryService>()
      : null;

  void clearResumingOnProviderProgress() {
    _recoveryService?.clearResumingOnProgress(
      host.sessionId,
      runId: host.authoritativeRunId,
    );
  }

  /// Per-reason automatic retry budget (Plan 30 Phase H §5).
  int automaticRetryBudget(RuntimeFailureReason reason) {
    switch (reason) {
      case RuntimeFailureReason.networkError:
        return 2;
      case RuntimeFailureReason.timeout:
        return 1;
      case RuntimeFailureReason.rateLimit:
      case RuntimeFailureReason.upstreamRateLimit:
      case RuntimeFailureReason.overloaded:
        return 3;
      case RuntimeFailureReason.toolRuntimeError:
      case RuntimeFailureReason.localRuntimeError:
        return 1;
      case RuntimeFailureReason.auth:
      case RuntimeFailureReason.billing:
      case RuntimeFailureReason.tlsCertificate:
      case RuntimeFailureReason.modelNotFound:
      case RuntimeFailureReason.contentPolicyBlocked:
      case RuntimeFailureReason.contextOverflow:
      case RuntimeFailureReason.payloadTooLarge:
      case RuntimeFailureReason.invalidRequest:
      case RuntimeFailureReason.unknown:
        return 0;
    }
  }

  Duration fallbackRetryDelay(RuntimeFailureReason reason, int attempt) {
    final baseSeconds = switch (reason) {
      RuntimeFailureReason.rateLimit => 60,
      RuntimeFailureReason.upstreamRateLimit => 60,
      RuntimeFailureReason.overloaded => 3,
      _ => 2,
    };
    final multiplier = attempt < 1 ? 1 : (1 << attempt);
    final seconds = (baseSeconds * multiplier).clamp(1, 60);
    return Duration(seconds: seconds);
  }

  /// One sentence describing what the agent already did automatically.
  ///
  /// A blocked notice that says nothing about the automatic retry reads like a
  /// first failure that is still being retried. That is how a headless worker
  /// stayed blocked for ten minutes: its per-reason budget (one attempt for a
  /// provider timeout) was already spent, so no further attempt was scheduled,
  /// and nothing in the notice said so. The note is empty when the failure was
  /// never eligible for an automatic retry.
  String automaticRetryNote({
    required int attempt,
    required int budget,
    required bool streamStarted,
  }) {
    if (budget <= 0) return '';
    if (streamStarted) {
      return '\n\nNo automatic retry: the response had already started '
          'streaming.';
    }
    if (attempt < budget) return '';
    return '\n\nAutomatic retry gave up after $budget '
        '${budget == 1 ? 'attempt' : 'attempts'}; retry manually or choose '
        'another provider.';
  }

  String buildNoticeMessage(
    RuntimeFailureReason reason,
    String? providerBody,
    String? providerDisplayName,
  ) {
    final base = defaultAppMessage(reason, providerDisplayName);
    final raw = providerBody?.trim();
    if (raw == null || raw.isEmpty) return base;
    final redacted = _secretsRedactor.redact(raw);
    return '$base\n\nProvider response: $redacted';
  }

  String defaultAppMessage(
    RuntimeFailureReason reason,
    String? providerDisplayName,
  ) {
    final p = providerDisplayName == null ? '' : '$providerDisplayName ';
    switch (reason) {
      case RuntimeFailureReason.auth:
        return 'The API key or token for $p is invalid or expired.';
      case RuntimeFailureReason.billing:
        return 'This ${p}account has insufficient credits or quota.';
      case RuntimeFailureReason.rateLimit:
      case RuntimeFailureReason.upstreamRateLimit:
        return 'Too many requests to $p. Wait or switch provider.';
      case RuntimeFailureReason.overloaded:
        return '${p}is currently overloaded. Retry shortly.';
      case RuntimeFailureReason.timeout:
        return 'The request to ${p}took too long to complete.';
      case RuntimeFailureReason.networkError:
        return 'The agent could not reach $p.';
      case RuntimeFailureReason.tlsCertificate:
        return 'The TLS/SSL certificate for ${p}could not be verified.';
      case RuntimeFailureReason.contextOverflow:
        return 'The conversation exceeds the model context window.';
      case RuntimeFailureReason.payloadTooLarge:
        return 'The request payload is too large.';
      case RuntimeFailureReason.invalidRequest:
        return 'The request format was rejected by $p.';
      case RuntimeFailureReason.modelNotFound:
        return 'The selected model is not available on $p.';
      case RuntimeFailureReason.contentPolicyBlocked:
        return 'The request was blocked by the provider content policy.';
      case RuntimeFailureReason.toolRuntimeError:
        return 'A tool execution error occurred. Retry when ready.';
      case RuntimeFailureReason.localRuntimeError:
        return 'A local runtime error occurred. Retry when ready.';
      case RuntimeFailureReason.unknown:
        return 'An unexpected error occurred while contacting $p.';
    }
  }

  LlmHttpException? asHttpFailure(Object error) => switch (error) {
    LlmHttpException failure => failure,
    ProviderStateRejectedException rejected => rejected.httpFailure,
    _ => null,
  };

  List<Message>? recoverRejectedProviderState(
    Object error,
    ResponseContinuationCoordinator continuation,
    List<Message> effectiveHistory,
  ) {
    if (error is! ProviderStateRejectedException ||
        !continuation.claimProviderStateFallback()) {
      return null;
    }

    final updatedHistory = clearRejectedProviderState(host.history, error);
    final updatedEffectiveHistory = clearRejectedProviderState(
      effectiveHistory,
      error,
    );
    final historyChanged = !sameMessageIdentities(host.history, updatedHistory);
    host.history = updatedHistory;
    if (historyChanged) host.saveHistory();
    return updatedEffectiveHistory;
  }

  List<Message> clearRejectedProviderState(
    List<Message> messages,
    ProviderStateRejectedException rejection,
  ) {
    return messages
        .map((message) {
          final state = message.providerState;
          if (state?.namespace != rejection.namespace ||
              state?.issuer != rejection.issuer) {
            return message;
          }
          final data = Map<String, dynamic>.from(state!.data);
          var changed = false;
          for (final key in rejection.dataKeysToClear) {
            changed = data.remove(key) != null || changed;
          }
          if (!changed) return message;
          if (data.isEmpty) return message.copyWith(clearProviderState: true);
          return message.copyWith(
            providerState: LLMProviderState(
              namespace: state.namespace,
              issuer: state.issuer,
              data: data,
            ),
          );
        })
        .toList(growable: true);
  }

  static bool sameMessageIdentities(List<Message> left, List<Message> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!identical(left[index], right[index])) return false;
    }
    return true;
  }

  Future<bool> handleRuntimeFailure(
    Object error, {
    required String? providerInstanceId,
    required String? modelId,
    required int attempt,
    required bool streamStarted,
    required Set<String> failedProviderInstanceIds,
    List<Message>? failedProviderProjection,
    List<ToolSchema>? failedProviderTools,
  }) async {
    if (error is RateLimitCancelled ||
        error is ProviderRequestCancelledException) {
      throw RuntimeRecoveryCancelled(host.sessionId);
    }
    final recovery = _recoveryService;
    if (recovery == null ||
        providerInstanceId == null ||
        providerInstanceId.isEmpty) {
      return false;
    }
    if (error is LocalImageCapabilityException) {
      const reason = RuntimeFailureReason.invalidRequest;
      final displayName = recovery.providerDisplayName(providerInstanceId);
      recovery.reportFailure(
        sessionId: host.sessionId,
        reason: reason,
        title: 'Image input not supported',
        message: error.userMessage,
        providerInstanceId: providerInstanceId,
        providerDisplayName: displayName,
        requestId: host.turnRoute.turnRequestId,
        retryAfter: null,
        forceBlocked: true,
        runId: host.authoritativeRunId,
      );
      throw RuntimeRecoveryRequired(host.sessionId, reason);
    }
    // History with no truthful wire representation for this route is rejected
    // before dispatch: no failover, retry, thinking change or history change.
    if (error is ProviderHistoryProjectionException) {
      const reason = RuntimeFailureReason.invalidRequest;
      final displayName = recovery.providerDisplayName(providerInstanceId);
      recovery.reportFailure(
        sessionId: host.sessionId,
        reason: reason,
        title: 'Conversation history not supported by this model',
        message: error.userMessage(
          providerDisplayName: displayName ?? 'this provider',
          modelId: modelId,
        ),
        providerInstanceId: providerInstanceId,
        providerDisplayName: displayName,
        requestId: host.turnRoute.turnRequestId,
        retryAfter: null,
        forceBlocked: true,
        runId: host.authoritativeRunId,
      );
      throw RuntimeRecoveryRequired(host.sessionId, reason);
    }
    // A local thinking-wire rejection (an explicitly selected budget the request
    // cannot honour) is decided before dispatch, so it must be presented as the
    // actionable configuration problem it is rather than as a provider failure.
    if (error is ThinkingWireSerializationException) {
      const reason = RuntimeFailureReason.invalidRequest;
      final displayName = recovery.providerDisplayName(providerInstanceId);
      recovery.reportFailure(
        sessionId: host.sessionId,
        reason: reason,
        title: 'Thinking option not supported',
        message: error.message,
        providerInstanceId: providerInstanceId,
        providerDisplayName: displayName,
        requestId: host.turnRoute.turnRequestId,
        retryAfter: null,
        forceBlocked: true,
        runId: host.authoritativeRunId,
      );
      throw RuntimeRecoveryRequired(host.sessionId, reason);
    }
    final httpFailure = asHttpFailure(error);
    final httpRetryAfter = httpFailure?.retryAfter;
    final providerBody = httpFailure?.body ?? error.toString();
    final reason = RuntimeFailureReason.classify(
      statusCode: httpFailure?.statusCode,
      body: providerBody,
      hasTrustedTemporaryReset: httpRetryAfter != null,
    );
    // Overflow compaction is automatic too: the per-run breaker opened by a
    // failed automatic or overflow compaction blocks it for the rest of the
    // run (Task 118), and the overflow falls through to the recovery notice.
    if (reason == RuntimeFailureReason.contextOverflow &&
        !streamStarted &&
        !overflowCompactionRetried &&
        !host.autoCompactionBlockedForRun &&
        getIt.isRegistered<CompactionCoordinator>() &&
        getIt.isRegistered<SessionHistoryRevisionRepository>() &&
        getIt.isRegistered<AgentRuntimeService>()) {
      overflowCompactionRetried = true;
      final coordinator = getIt<CompactionCoordinator>();
      final revisionRepo = getIt<SessionHistoryRevisionRepository>();
      final revision = revisionRepo.read(host.sessionId);
      final projectionRevision = host.currentProjectionRevision();
      if (revision != null) {
        final timeline = host.compactionTimelineForSession();
        if (timeline.isNotEmpty) {
          final activeBoundary = getIt<ModelProjectionBuilder>()
              .buildForSession(host.sessionId)
              .activeBoundary;
          final contextWindow = await host.getContextTokens() ?? 128_000;
          final policy = getIt.isRegistered<Config>()
              ? getIt<Config>().compactionPolicyForModel(modelId ?? '')
              : const CompactionPolicy(threshold: 0.90, targetRatio: 0.10);
          final targetRequestTokens =
              CompactionTargetPolicy.targetRequestTokens(
                windowTokens: contextWindow,
                ratio: policy.targetRatio,
              );
          final routeSignature = getIt<AgentRuntimeService>().resolveSignature(
            providerId: providerInstanceId,
            modelId: modelId,
          );
          try {
            final request = CompactionEngineRequest(
              compactionId: '',
              sessionId: host.sessionId,
              trigger: CompactionTrigger.overflow,
              sourceRevision: revision.toCompactionRevision(),
              routeSignature: routeSignature,
              contextWindowTokens: contextWindow,
              timeline: timeline,
              systemPrompt: host.assembleSystemPrompt(),
              runtimeContext: '',
              toolSchemas: const [],
              providerProjection: failedProviderProjection,
              providerTools: failedProviderTools ?? const [],
              providerRequestOptions: host.compactionRequestOptions(
                providerInstanceId,
                compactionId: 'overflow',
              ),
              projectionRevision: projectionRevision,
              previousSummary: activeBoundary?.internalSummary,
              previousSourceRange: activeBoundary?.sourceRange,
              targetRequestTokens: targetRequestTokens,
              thresholdRatio: policy.threshold,
              targetRatio: policy.targetRatio,
            );
            final outcome = await coordinator.runCompaction(
              request: request,
              force: true,
            );
            if (outcome?.status == CompactionStatus.completed) {
              host.refreshCanonicalHistoryAfterCompaction();
              return true;
            }
            if (outcome?.status == CompactionStatus.failed) {
              host.markCompactionFailure();
            }
          } catch (_) {
            host.markCompactionFailure();
          }
        }
      }
    }

    final retryAfter = httpRetryAfter ?? fallbackRetryDelay(reason, attempt);
    final decision = reason.decision();
    final budget = automaticRetryBudget(reason);
    final exhaustedAutomaticRetries = attempt >= budget;
    if (reason == RuntimeFailureReason.rateLimit ||
        reason == RuntimeFailureReason.upstreamRateLimit) {
      recovery.recordProviderCooldown(providerInstanceId, retryAfter);
    }

    if (!streamStarted && decision.allowAutoFailover) {
      failedProviderInstanceIds.add(providerInstanceId);
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: providerInstanceId,
        requestedModelId: modelId ?? '',
        excludedInstanceIds: failedProviderInstanceIds,
      );
      if (candidate != null) {
        recovery.reportFailure(
          sessionId: host.sessionId,
          reason: reason,
          providerInstanceId: providerInstanceId,
          requestId: host.turnRoute.turnRequestId,
          retryAfter: retryAfter,
          runId: host.authoritativeRunId,
        );
        if (getIt.isRegistered<SessionRouteMutationCoordinator>()) {
          final routeCoordinator = getIt<SessionRouteMutationCoordinator>();
          final anchorMessageId = host.latestPersistedMessageId();
          final persisted = getIt
              .isRegistered<PersistedRuntimeStateRepository>();
          final claimed = persisted
              ? routeCoordinator.claimAutoFailover(
                  sessionId: host.sessionId,
                  workItemId: host.authoritativeWorkItemId,
                  runId: host.authoritativeRunId,
                  generation: host.authoritativeGeneration,
                  expectedProviderInstanceId: providerInstanceId,
                  providerInstanceId: candidate.id,
                  model: modelId!,
                  reason: reason.name.replaceAllMapped(
                    RegExp(r'([A-Z])'),
                    (match) => '_${match.group(1)!.toLowerCase()}',
                  ),
                  requestId: host.turnRoute.turnRequestId,
                  anchorMessageId: anchorMessageId,
                  publish: true,
                )
              : routeCoordinator.mutate(
                  sessionId: host.sessionId,
                  providerInstanceId: candidate.id,
                  model: modelId!,
                  source: SessionRouteSource.autoFailover,
                  reason: reason.name.replaceAllMapped(
                    RegExp(r'([A-Z])'),
                    (match) => '_${match.group(1)!.toLowerCase()}',
                  ),
                  requestId: host.turnRoute.turnRequestId,
                  anchorMessageId: anchorMessageId,
                  publish: true,
                );
          if (persisted && claimed == null) {
            throw RuntimeRecoveryRequired(host.sessionId, reason);
          }
        } else {
          host.updateSessionProviderId(candidate.id);
        }
        if (getIt.isRegistered<ThinkingRouteSessionSync>()) {
          final revalidated = getIt<ThinkingRouteSessionSync>()
              .revalidateAndApplySession(
                sessionId: host.sessionId,
                providerInstanceId: candidate.id,
                modelId: modelId!,
              );
          host.turnRoute.updateTurnThinkingMode(revalidated.selectionId);
        }
        host.turnRoute.rewriteQueuedProvider(candidate.id);
        host.resolveTurnCapabilityProfile(
          providerInstanceId: candidate.id,
          modelId: modelId!,
        );
        recovery.emitResuming(
          sessionId: host.sessionId,
          reason: 'auto_failover',
          requestId: host.turnRoute.turnRequestId,
          providerInstanceId: candidate.id,
          providerDisplayName: candidate.displayName,
          message: 'Continuing automatically with ${candidate.displayName}.',
          runId: host.authoritativeRunId,
        );
        return true;
      }
    }

    if (!streamStarted && budget > 0 && !exhaustedAutomaticRetries) {
      recovery.reportFailure(
        sessionId: host.sessionId,
        reason: reason,
        providerInstanceId: providerInstanceId,
        requestId: host.turnRoute.turnRequestId,
        retryAfter: retryAfter,
        runId: host.authoritativeRunId,
      );
      final resumed = await recovery.waitForRetry(
        host.sessionId,
        retryAfter,
        runId: host.authoritativeRunId,
      );
      if (!resumed) {
        if (recovery.isStopped(
          host.sessionId,
          runId: host.authoritativeRunId,
        )) {
          throw RuntimeRecoveryCancelled(host.sessionId);
        }
        if (!host.claimOwnedAutomaticRetry()) {
          _logger.info(
            'Interrupted retry lost durable ownership for session ${host.sessionId}; '
            'leaving recovery state authoritative.',
          );
          throw RuntimeRecoveryRequired(host.sessionId, reason);
        }
        host.turnRoute.refreshFromSession();
        final routing = host.turnRoute.resolveTurnRouting();
        final pId = routing.providerId;
        final mId = routing.model ?? host.turnRoute.effectiveModel;
        if (host.turnCapabilityProfileMatchesRoute(pId, mId)) {
          // Same-route wake (manual retry, queued handoff, or a timer abort
          // without a provider change): the admitted snapshot stays frozen.
        } else if (pId != null && mId != null) {
          if (getIt.isRegistered<ThinkingRouteSessionSync>()) {
            final revalidated = getIt<ThinkingRouteSessionSync>()
                .revalidateAndApplySession(
                  sessionId: host.sessionId,
                  providerInstanceId: pId,
                  modelId: mId,
                );
            host.turnRoute.updateTurnThinkingMode(revalidated.selectionId);
          }
          host.resolveTurnCapabilityProfile(
            providerInstanceId: pId,
            modelId: mId,
          );
        } else {
          host.clearTurnCapabilityProfile();
        }
        return true;
      }
      if (!host.claimOwnedAutomaticRetry()) {
        _logger.info(
          'Automatic retry lost durable ownership for session ${host.sessionId}; '
          'leaving recovery state authoritative.',
        );
        throw RuntimeRecoveryRequired(host.sessionId, reason);
      }
      recovery.emitResuming(
        sessionId: host.sessionId,
        reason: 'retrying',
        requestId: host.turnRoute.turnRequestId,
        providerInstanceId: providerInstanceId,
        message: 'Retrying the last request.',
        runId: host.authoritativeRunId,
      );
      return true;
    }

    final budgetExhaustedWaiting =
        exhaustedAutomaticRetries &&
        reason.decision().noticeStatus == RuntimeNoticeStatus.waiting;
    final displayName = recovery.providerDisplayName(providerInstanceId);
    final retryNote = automaticRetryNote(
      attempt: attempt,
      budget: budget,
      streamStarted: streamStarted,
    );
    recovery.reportFailure(
      sessionId: host.sessionId,
      reason: reason,
      providerInstanceId: providerInstanceId,
      requestId: host.turnRoute.turnRequestId,
      retryAfter: budgetExhaustedWaiting ? null : retryAfter,
      message: '${buildNoticeMessage(reason, providerBody, displayName)}'
          '$retryNote',
      forceBlocked: budgetExhaustedWaiting,
      runId: host.authoritativeRunId,
    );
    throw RuntimeRecoveryRequired(host.sessionId, reason);
  }
}
