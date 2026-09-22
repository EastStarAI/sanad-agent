import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';

import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'provider_instance.dart';
import 'provider_instance_repository.dart';
import 'provider_protocol_constants.dart';
import 'provider_rate_limiter.dart';
import 'runtime_failure_reason.dart';
import 'runtime_notice.dart';

/// Holds the active recovery state per session and broadcasts runtime notices
/// (Plan 30 §5, §8).
///
/// The agent runtime calls into this service when a rate-limit wait is needed,
/// when an LLM error is classified, and when a client issues a
/// retry/stop/continue-with-provider command. It owns the in-memory recovery
/// map (Plan 30 §5.1 — persistence is deferred to a later phase) and is the
/// single source of truth for the active `RuntimeNotice` per session.
///
/// Broadcasting to actual clients (Socket.IO / local daemon) is delegated to
/// [noticeSink] so this class stays transport-agnostic and unit-testable.
class RuntimeRecoveryService {
  final _logger = Logger('RuntimeRecoveryService');

  final ProviderInstanceRepository _repo;
  final ProviderRateLimiter _limiter;
  final Random _random;

  /// Sink for emitting notice/cleared events to clients. Called with the
  /// transport-safe payload. The runtime wires this to the gateway.
  void Function(Map<String, dynamic> payload)? _noticeSink;

  /// Per-session active recovery state.
  final Map<String, RuntimeNotice> _active = {};

  /// Cancellation and stop state are scoped to an immutable run id. Legacy
  /// callers without a run id resolve to the current run for the session.
  final Map<String, Completer<void>> _cancelTokens = {};
  final Map<String, String> _currentRunIds = {};

  /// Auto-resume timers restored from persisted `resume_at` values after a
  /// daemon restart. Only the latest timer for a session is kept.
  final Map<String, Timer> _resumeTimers = {};

  /// Sessions currently executing an automatic resume callback. Prevents
  /// duplicate callbacks when restore/bootstrap paths overlap.
  final Set<String> _resumeInFlight = <String>{};

  /// Track the last clear reason per session to help runner distinguish
  /// between stop and resume/retry when a wait is aborted.
  final Map<String, String> _lastClearReason = {};

  String _runKey(String sessionId, String? runId) =>
      '$sessionId\u0000${runId ?? _currentRunIds[sessionId] ?? 'legacy'}';

  bool _acceptsRun(String sessionId, String? runId) {
    return runId == null ||
        _currentRunIds[sessionId] == null ||
        _currentRunIds[sessionId] == runId;
  }

  void beginRun(
    String sessionId,
    String runId, {
    bool adoptExistingNotice = false,
  }) {
    _currentRunIds[sessionId] = runId;
    final existing = _active[sessionId];
    if (adoptExistingNotice && existing != null && existing.runId != runId) {
      _active[sessionId] = RuntimeNotice(
        sessionId: existing.sessionId,
        requestId: existing.requestId,
        runId: runId,
        status: existing.status,
        reason: existing.reason,
        severity: existing.severity,
        title: existing.title,
        message: existing.message,
        providerInstanceId: existing.providerInstanceId,
        providerDisplayName: existing.providerDisplayName,
        resumeAt: existing.resumeAt,
        limit: existing.limit,
        actions: existing.actions,
        createdAt: existing.createdAt,
        updatedAt: existing.updatedAt,
      );
    }
    _ensureCancelToken(sessionId, runId: runId);
  }

  void endRun(String sessionId, String runId) {
    if (_currentRunIds[sessionId] != runId) return;
    final notice = _active[sessionId];
    if (notice != null && notice.runId == runId) return;
    // Keep the latest run identity as a tombstone so a callback from an older
    // generation can never become authoritative after the current run ends.
    _cancelTokens.remove(_runKey(sessionId, runId));
  }

  /// Whether automatic provider failover is enabled (Plan 30 §8.1).
  bool autoFailoverEnabled;

  /// Optional durable store for runtime notices (post-Plan 30). When set,
  /// every emitted notice is written through to SQLite so a daemon restart
  /// can restore the active banner via `get_session_history`.
  PersistedRuntimeStateRepository? _persistedState;

  /// Callback invoked when a restored waiting notice reaches its `resume_at`
  /// boundary after a daemon restart.
  Future<void> Function(RuntimeNotice notice)? _resumeHandler;

  RuntimeRecoveryService(
    this._repo,
    this._limiter, {
    void Function(Map<String, dynamic> payload)? noticeSink,
    this.autoFailoverEnabled = false,
    Random? random,
  }) : _noticeSink = noticeSink,
       _random = random ?? Random();

  void attachNoticeSink(void Function(Map<String, dynamic> payload)? sink) {
    _noticeSink = sink;
  }

  /// Wires the optional persisted state store. When set, the service mirrors
  /// every active notice into SQLite.
  void attachPersistedState(PersistedRuntimeStateRepository? store) {
    _persistedState = store;
  }

  /// Registers the runtime-owned resume callback used only for restored waits.
  /// The callback is expected to claim/rebuild the suspended turn and call
  /// `resumeSuspended` exactly once.
  void attachResumeHandler(
    Future<void> Function(RuntimeNotice notice)? handler,
  ) {
    _resumeHandler = handler;
  }

  /// Restores active notices from the database during startup (Gate E.1).
  /// Re-creates cancellation tokens, provider cooldowns, and schedules
  /// timers if resume_at is in the future.
  void restoreActiveNotices() {
    final store = _persistedState;
    if (store == null) return;

    final notices = store.findAllNotices();
    final now = DateTime.now();

    for (final entry in notices.entries) {
      final sessionId = entry.key;
      final notice = entry.value;

      // Restore only waiting notices into live runtime memory. Blocked notices
      // remain durable-only and are hydrated lazily from SQLite when the user
      // opens the session or issues a recovery action.
      if (notice.status == 'waiting') {
        final reason = RuntimeFailureReason.values.firstWhere(
          (r) => r.name == notice.reason,
          orElse: () => RuntimeFailureReason.unknown,
        );
        final statusVal = RuntimeNoticeStatus.values.firstWhere(
          (s) => s.name == notice.status,
          orElse: () => RuntimeNoticeStatus.blocked,
        );
        final severityVal = RuntimeNoticeSeverity.values.firstWhere(
          (s) => s.name == notice.severity,
          orElse: () => RuntimeNoticeSeverity.warning,
        );

        DateTime? resumeAt;
        if (notice.resumeAt != null) {
          resumeAt = DateTime.tryParse(notice.resumeAt!);
        }

        final actionsList = notice.actions
            .map(
              (a) => RuntimeNoticeAction.values.firstWhere(
                (av) => av.name == a,
                orElse: () => RuntimeNoticeAction.stop,
              ),
            )
            .toList();

        final effectiveActions = actionsList;

        final restoredNotice = RuntimeNotice(
          sessionId: sessionId,
          requestId: notice.requestId,
          runId: notice.runId,
          status: statusVal,
          reason: reason,
          severity: severityVal,
          title: notice.title,
          message: notice.message,
          providerInstanceId: notice.providerInstanceId,
          providerDisplayName: notice.providerDisplayName,
          resumeAt: resumeAt,
          limit: notice.limitRpm,
          actions: effectiveActions,
          createdAt:
              DateTime.tryParse(notice.createdAt) ?? DateTime.now().toUtc(),
          updatedAt:
              DateTime.tryParse(notice.updatedAt) ?? DateTime.now().toUtc(),
        );

        _active[sessionId] = restoredNotice;
        if (restoredNotice.runId != null) {
          _currentRunIds[sessionId] = restoredNotice.runId!;
        }
        _ensureCancelToken(sessionId, runId: restoredNotice.runId);

        // If it was waiting, we need to restore the cooldown wait and a real
        // auto-resume callback rather than only recording provider cooldown.
        if (statusVal == RuntimeNoticeStatus.waiting && resumeAt != null) {
          if (resumeAt.isAfter(now)) {
            final remaining = resumeAt.difference(now);
            _limiter.recordProviderCooldown(
              restoredNotice.providerInstanceId ?? '',
              remaining,
            );
            _scheduleResume(restoredNotice, remaining);
          } else {
            _limiter.recordProviderCooldown(
              restoredNotice.providerInstanceId ?? '',
              Duration.zero,
            );
            _scheduleResume(restoredNotice, Duration.zero);
          }
        }

        // Gate F.2 — re-broadcast the restored notice to the gateway so
        // every client that reconnects after a daemon restart observes the
        // matching `session.runtime_notice` event instead of an empty
        // banner. The notice row is the source of truth; the client must
        // never have to ask for it via a separate hydration call to
        // discover that a session is in recovery.
        _emit(restoredNotice);
      }
    }
  }

  /// Whether [sessionId] currently has an active (non-cleared) recovery state.
  bool hasActiveNotice(String sessionId) {
    final n = _active[sessionId];
    return n != null && n.status != RuntimeNoticeStatus.cleared;
  }

  /// The active notice for [sessionId], or null.
  RuntimeNotice? activeNotice(String sessionId) => _active[sessionId];

  /// The cancellation token for [sessionId] (used by the rate-limited adapter
  /// and by retry loops). Completing it aborts the active wait.
  Future<void> cancelToken(String sessionId, {String? runId}) {
    _ensureCancelToken(sessionId, runId: runId);
    return _cancelTokens[_runKey(sessionId, runId)]!.future;
  }

  /// Begins (or replaces) a cancellation token for [sessionId]. The previous
  /// one, if any, is left untouched — only the latest is tracked.
  void _ensureCancelToken(String sessionId, {String? runId}) {
    _cancelTokens.putIfAbsent(
      _runKey(sessionId, runId),
      () => Completer<void>(),
    );
  }

  /// Called by [RateLimitedLLMAdapter] right before blocking on a rate-limit
  /// wait. Emits a `waiting` notice and returns the cancellation token the
  /// adapter should race against.
  Future<void> reportRateLimitWait({
    required String sessionId,
    required String providerInstanceId,
    required Duration retryAfter,
    int? limit,
    String? requestId,
    String? runId,
  }) async {
    if (!_acceptsRun(sessionId, runId)) return;
    if (runId != null) _currentRunIds[sessionId] = runId;
    _lastClearReason.remove(_runKey(sessionId, runId));
    final name = _providerDisplayName(providerInstanceId);
    final now = DateTime.now();
    final resumeAt = now.add(retryAfter);
    final notice = RuntimeNotice(
      sessionId: sessionId,
      requestId: requestId,
      runId: runId,
      status: RuntimeNoticeStatus.waiting,
      reason: RuntimeFailureReason.rateLimit,
      severity: RuntimeNoticeSeverity.warning,
      title: '$name rate limit reached',
      message:
          'Continuing automatically in ${(retryAfter.inMilliseconds / 1000).round()}s.',
      providerInstanceId: providerInstanceId,
      providerDisplayName: name,
      resumeAt: resumeAt,
      limit: limit,
      actions: const [
        RuntimeNoticeAction.stop,
        RuntimeNoticeAction.changeProvider,
      ],
      createdAt: now,
      updatedAt: now,
    );
    _active[sessionId] = notice;
    _ensureCancelToken(sessionId, runId: runId);
    // Gate F.2 — promote the durable work item from `running` to `waiting`
    // so a daemon crash inside `waitForRetry` leaves a correct durable
    // snapshot for `restorePersistedState()` to rehydrate. Without this,
    // restore would re-queue the item as a "crashed" turn and re-run the
    // exact request that triggered the 429.
    _transitionActiveWorkItemToWaiting(sessionId, requestId: requestId);
    _emit(notice);
    _logger.info(
      'Rate-limit wait for session $sessionId on $name: ${retryAfter.inSeconds}s',
    );
  }

  /// Promotes the active durable work item for [sessionId] from `running`
  /// to `waiting` when a rate-limit or other waiting-class notice is
  /// reported. Idempotent: a no-op when the work item is already in
  /// `waiting` / `blocked` / `resuming` or when no active item exists.
  void _transitionActiveWorkItemToWaiting(
    String sessionId, {
    String? requestId,
  }) {
    _transitionActiveWorkItemToStatus(
      sessionId,
      target: RuntimeNoticeStatus.waiting,
      requestId: requestId,
    );
  }

  /// Promotes the active durable work item for [sessionId] to the state
  /// matching the runtime notice's [target] status. Idempotent and safe to
  /// call multiple times; ignores requests for terminal notice statuses.
  void _transitionActiveWorkItemToStatus(
    String sessionId, {
    required RuntimeNoticeStatus target,
    String? requestId,
  }) {
    final store = _persistedState;
    if (store == null) return;
    final active = store.findActiveWorkItem(sessionId);
    if (active == null) return;
    final targetState = switch (target) {
      RuntimeNoticeStatus.waiting => SessionWorkState.waiting,
      RuntimeNoticeStatus.blocked ||
      RuntimeNoticeStatus.fatal => SessionWorkState.blocked,
      _ => null,
    };
    if (targetState == null) return;
    if (active.state == targetState) return;
    final canTransition = switch ((active.state, targetState)) {
      (SessionWorkState.running, _) => true,
      (SessionWorkState.resuming, _) => true,
      (SessionWorkState.waiting, SessionWorkState.blocked) => true,
      _ => false,
    };
    if (!canTransition) return;
    try {
      store.transitionWorkItemState(
        workItemId: active.workItemId,
        fromState: active.state,
        toState: targetState,
      );
    } catch (e) {
      _logger.warning(
        'Failed to promote work item ${active.workItemId} to $targetState: $e',
      );
    }
  }

  /// Called when an LLM call fails with a classified reason. Emits the
  /// appropriate notice (blocked/fatal) and returns the decision so the caller
  /// can drive retry / failover.
  FailureDecision reportFailure({
    required String sessionId,
    required RuntimeFailureReason reason,
    String? title,
    String? message,
    String? providerInstanceId,
    String? providerDisplayName,
    String? requestId,
    String? runId,
    Duration? retryAfter,
    int? limit,
    // Plan 30 Phase H P1: when true (budget exhausted for waiting-class reasons)
    // the notice is shown as blocked even though the reason normally means
    // waiting. This converts a waiting-with-no-timer into a proper blocked
    // notice with Stop / Retry / Change Provider actions.
    bool forceBlocked = false,
  }) {
    final decision = reason.decision();
    if (!_acceptsRun(sessionId, runId)) return decision;
    if (runId != null) _currentRunIds[sessionId] = runId;
    _lastClearReason.remove(_runKey(sessionId, runId));
    final resolvedProviderDisplayName =
        providerDisplayName ?? _providerDisplayName(providerInstanceId);
    var effectiveDecision = decision;
    if (effectiveDecision.noticeStatus == RuntimeNoticeStatus.cleared) {
      clear(sessionId, runId: runId);
      return effectiveDecision;
    }
    final now = DateTime.now();
    final resumeAt = retryAfter == null ? null : now.add(retryAfter);
    // Override: waiting + budget exhausted → show as blocked so the client
    // displays Stop / Retry / Change Provider instead of a waiting spinner
    // with no countdown (Plan 30 Phase H §5 P1).
    final effectiveStatus =
        forceBlocked &&
            effectiveDecision.noticeStatus == RuntimeNoticeStatus.waiting
        ? RuntimeNoticeStatus.blocked
        : effectiveDecision.noticeStatus;
    final effectiveSeverity =
        forceBlocked &&
            effectiveDecision.noticeStatus == RuntimeNoticeStatus.waiting
        ? RuntimeNoticeSeverity.error
        : effectiveDecision.severity;
    final effectiveActions = _normalizeActions(
      forceBlocked &&
              effectiveDecision.noticeStatus == RuntimeNoticeStatus.waiting
          ? const [
              RuntimeNoticeAction.stop,
              RuntimeNoticeAction.retry,
              RuntimeNoticeAction.changeProvider,
            ]
          : effectiveDecision.uiActions,
      status: effectiveStatus,
    );
    final notice = RuntimeNotice(
      sessionId: sessionId,
      requestId: requestId,
      runId: runId,
      status: effectiveStatus,
      reason: reason,
      severity: effectiveSeverity,
      title: title ?? _defaultTitle(reason, resolvedProviderDisplayName),
      message: message ?? _defaultMessage(reason, resolvedProviderDisplayName),
      providerInstanceId: providerInstanceId,
      providerDisplayName: resolvedProviderDisplayName,
      resumeAt: resumeAt,
      limit: limit,
      actions: effectiveActions,
      createdAt: now,
      updatedAt: now,
    );
    _active[sessionId] = notice;
    _ensureCancelToken(sessionId, runId: runId);
    // Gate F.2 — promote the durable work item to the same `effectiveStatus`
    // so a daemon crash after `reportFailure` leaves a correct durable
    // snapshot for `restorePersistedState()` to rehydrate.
    _transitionActiveWorkItemToStatus(
      sessionId,
      target: effectiveStatus,
      requestId: requestId,
    );
    _emit(notice);
    return effectiveDecision;
  }

  void emitResuming({
    required String sessionId,
    required String reason,
    String? requestId,
    String? providerInstanceId,
    String? providerDisplayName,
    String? message,
    String? runId,
  }) {
    final effectiveRunId =
        runId ?? _active[sessionId]?.runId ?? _currentRunIds[sessionId];
    if (!_acceptsRun(sessionId, effectiveRunId)) return;
    if (effectiveRunId != null) {
      _currentRunIds[sessionId] = effectiveRunId;
    }
    final now = DateTime.now();
    final resolvedProviderDisplayName =
        providerDisplayName ?? _providerDisplayName(providerInstanceId);
    final notice = RuntimeNotice(
      sessionId: sessionId,
      requestId: requestId,
      runId: effectiveRunId,
      status: RuntimeNoticeStatus.resuming,
      reason: RuntimeFailureReason.unknown,
      severity: RuntimeNoticeSeverity.info,
      title: 'Resuming…',
      message:
          message ??
          'Continuing with ${resolvedProviderDisplayName ?? 'the current provider'}.',
      providerInstanceId: providerInstanceId,
      providerDisplayName: resolvedProviderDisplayName,
      actions: const [],
      createdAt: now,
      updatedAt: now,
    );
    _active[sessionId] = notice;
    _ensureCancelToken(sessionId, runId: effectiveRunId);
    _emit(notice, reasonOverride: reason);
  }

  /// Selects an auto-failover candidate (Plan 30 §8.1) given the failed
  /// instance, the model that was requested, and the set of instance ids
  /// currently known to be rate-limited/exhausted. Returns null when no
  /// qualified candidate exists or auto failover is disabled.
  ///
  /// Priority:
  /// 1. Same template, same model, ready, allowAutoFailover, not excluded.
  /// 2. Any template, same model id, ready, allowAutoFailover, not excluded.
  ProviderInstance? selectFailoverCandidate({
    required String failedInstanceId,
    required String requestedModelId,
    required Set<String> excludedInstanceIds,
  }) {
    if (!autoFailoverEnabled) return null;
    final all = _repo.findAll();
    final candidates = all.where((i) {
      if (i.id == failedInstanceId) return false;
      if (excludedInstanceIds.contains(i.id)) return false;
      if (i.status != InstanceStatus.ready) return false;
      if (!i.allowAutoFailover) return false;
      return true;
    }).toList();

    final failedInstance = _repo.findById(failedInstanceId);
    final failedTemplateId = failedInstance?.templateId;

    // Priority 1: same template + exact model.
    final sameTemplate = candidates
        .where(
          (i) =>
              i.templateId == failedTemplateId &&
              i.defaultModel == requestedModelId,
        )
        .toList();
    if (sameTemplate.isNotEmpty) return sameTemplate.first;

    // Priority 2: any template + exact model.
    final anyTemplate = candidates
        .where((i) => i.defaultModel == requestedModelId)
        .toList();
    if (anyTemplate.isNotEmpty) return anyTemplate.first;

    return null;
  }

  /// Clears the active notice for [sessionId] and emits a `cleared` event.
  void clear(
    String sessionId, {
    bool emit = true,
    String? reasonOverride,
    String? runId,
  }) {
    if (!_acceptsRun(sessionId, runId)) return;
    final current = _active[sessionId];
    final existing = runId == null || current?.runId == runId
        ? _active.remove(sessionId)
        : null;
    _cancelResumeTimer(sessionId);
    _resumeInFlight.remove(sessionId);
    _cancelTokens.remove(_runKey(sessionId, runId));
    if (reasonOverride != null) {
      _lastClearReason[_runKey(sessionId, runId)] = reasonOverride;
    }
    final cleared = RuntimeNotice(
      sessionId: sessionId,
      requestId: existing?.requestId,
      runId: runId ?? existing?.runId,
      status: RuntimeNoticeStatus.cleared,
      reason: existing?.reason ?? RuntimeFailureReason.unknown,
      severity: RuntimeNoticeSeverity.info,
      title: existing?.title ?? 'Cleared',
      message: 'Recovered.',
      actions: const [],
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );
    if (emit) {
      _emit(cleared, reasonOverride: reasonOverride);
    }
  }

  /// Clears a visible `resuming` notice once the resumed turn has shown real
  /// progress (for example the first assistant chunk) or completed.
  void clearResumingOnProgress(
    String sessionId, {
    String? reasonOverride,
    String? runId,
  }) {
    if (!_acceptsRun(sessionId, runId)) return;
    final existing = _active[sessionId];
    if (runId != null && existing?.runId != runId) return;
    if (existing?.status != RuntimeNoticeStatus.resuming) {
      return;
    }
    clear(sessionId, reasonOverride: reasonOverride ?? 'cleared', runId: runId);
  }

  /// Checks whether [sessionId] was cleared due to a stop command.
  bool isStopped(String sessionId, {String? runId}) {
    return _lastClearReason[_runKey(sessionId, runId)] == 'stopped';
  }

  /// Aborts any active wait/retry for [sessionId] (Plan 30 §3.18). Used by
  /// `session.runtime_stop` and by provider changes.
  void abort(String sessionId, {String? runId}) {
    _cancelResumeTimer(sessionId);
    final token = _cancelTokens[_runKey(sessionId, runId)];
    if (token != null && !token.isCompleted) {
      token.complete();
    }
    _limiter.reset(sessionId);
  }

  Future<bool> waitForRetry(
    String sessionId,
    Duration delay, {
    bool addJitter = true,
    String? runId,
  }) async {
    final token = cancelToken(sessionId, runId: runId);
    final jitterMs = addJitter ? _random.nextInt(500) : 0;
    final wait = delay + Duration(milliseconds: jitterMs);
    final completed = await Future.any<bool>([
      token.then((_) => false),
      Future<bool>.delayed(wait, () => true),
    ]);
    return completed;
  }

  void recordProviderCooldown(String providerInstanceId, Duration retryAfter) {
    _limiter.recordProviderCooldown(providerInstanceId, retryAfter);
  }

  void _emit(RuntimeNotice notice, {String? reasonOverride}) {
    // Always log the lifecycle transition so recovery states are visible in
    // daemon logs without noisy per-tick output (Plan 30 §3.19).
    _logger.info(
      'RuntimeNotice [${notice.status.name}] session=${notice.sessionId} '
      "reason=${notice.reason.name} provider=${notice.providerDisplayName ?? '-'} "
      "title='${notice.title}'",
    );
    final payload = notice.toPayload();
    final executionRevision = _persistedState?.executionSnapshots
        .getSnapshot(notice.sessionId)
        .revision;
    if (executionRevision != null) {
      payload['execution_revision'] = executionRevision;
    }
    if (reasonOverride != null && reasonOverride.isNotEmpty) {
      payload['reason'] = reasonOverride;
    }
    _persistNotice(notice);
    final sink = _noticeSink;
    if (sink == null) return;
    try {
      sink(payload);
    } catch (e, st) {
      _logger.warning('Failed to emit runtime notice: $e', e, st);
    }
  }

  /// Mirrors a non-cleared notice into SQLite (write-through). Cleared
  /// notices delete the row instead.
  void _persistNotice(RuntimeNotice notice) {
    final store = _persistedState;
    if (store == null) return;
    try {
      if (notice.status == RuntimeNoticeStatus.cleared) {
        store.deleteNotice(notice.sessionId);
        return;
      }
      store.upsertNotice(
        sessionId: notice.sessionId,
        requestId: notice.requestId,
        runId: notice.runId,
        status: notice.status.name,
        reason: notice.reason.name,
        severity: notice.severity.name,
        title: notice.title,
        message: notice.message,
        providerInstanceId: notice.providerInstanceId,
        providerDisplayName: notice.providerDisplayName,
        retryAfterMs: notice.retryAfterMs,
        resumeAt: notice.resumeAt?.toUtc().toIso8601String(),
        limitRpm: notice.limit,
        actions: notice.actions.map((a) => a.name).toList(),
        createdAt: notice.createdAt,
      );
    } catch (e, st) {
      _logger.warning('Failed to persist runtime notice: $e', e, st);
    }
  }

  String? _providerDisplayName(String? providerInstanceId) {
    if (providerInstanceId == null || providerInstanceId.isEmpty) {
      return null;
    }
    return _repo.findById(providerInstanceId)?.displayName ??
        providerInstanceId;
  }

  /// Public accessor for the display name of a provider instance (Plan 30
  /// Phase H §6: the runtime message builder needs the display name without
  /// duplicating repository lookups).
  String? providerDisplayName(String? providerInstanceId) =>
      _providerDisplayName(providerInstanceId);

  String _defaultTitle(RuntimeFailureReason reason, String? provider) {
    final p = provider == null ? '' : '$provider ';
    switch (reason) {
      case RuntimeFailureReason.auth:
        return '${p}Authentication failed';
      case RuntimeFailureReason.billing:
        return '${p}Insufficient credits';
      case RuntimeFailureReason.rateLimit:
      case RuntimeFailureReason.upstreamRateLimit:
        return '${p}Rate limit reached';
      case RuntimeFailureReason.overloaded:
        return '${p}Provider overloaded';
      case RuntimeFailureReason.timeout:
        return 'Request timed out';
      case RuntimeFailureReason.networkError:
        return 'Connection failed';
      case RuntimeFailureReason.tlsCertificate:
        return 'SSL certificate error';
      case RuntimeFailureReason.contextOverflow:
        return 'Context too long';
      case RuntimeFailureReason.payloadTooLarge:
        return 'Request too large';
      case RuntimeFailureReason.invalidRequest:
        return 'Invalid request';
      case RuntimeFailureReason.modelNotFound:
        return '${p}Model not found';
      case RuntimeFailureReason.contentPolicyBlocked:
        return 'Blocked by content policy';
      case RuntimeFailureReason.toolRuntimeError:
        return 'Tool execution failed';
      case RuntimeFailureReason.localRuntimeError:
        return 'Runtime error';
      case RuntimeFailureReason.unknown:
        return '${p}Error';
    }
  }

  String _defaultMessage(RuntimeFailureReason reason, String? provider) {
    switch (reason) {
      case RuntimeFailureReason.auth:
        return 'The API key or token is invalid or expired.';
      case RuntimeFailureReason.billing:
        return 'This account has insufficient credits or quota.';
      case RuntimeFailureReason.rateLimit:
      case RuntimeFailureReason.upstreamRateLimit:
        return 'Too many requests. Wait or switch provider.';
      case RuntimeFailureReason.overloaded:
        return 'The provider is currently overloaded. Retry shortly.';
      case RuntimeFailureReason.timeout:
        return 'The request took too long to complete.';
      case RuntimeFailureReason.networkError:
        return 'The agent could not reach the runtime service.';
      case RuntimeFailureReason.tlsCertificate:
        return 'The TLS/SSL certificate could not be verified.';
      case RuntimeFailureReason.contextOverflow:
        return 'The conversation exceeds the model context window.';
      case RuntimeFailureReason.payloadTooLarge:
        return 'The request payload is too large.';
      case RuntimeFailureReason.invalidRequest:
        return 'The provider rejected the request format or parameters.';
      case RuntimeFailureReason.modelNotFound:
        return 'The selected model is not available on this provider.';
      case RuntimeFailureReason.contentPolicyBlocked:
        return 'The request was blocked by the provider content policy.';
      case RuntimeFailureReason.toolRuntimeError:
        return 'A tool execution error occurred. Retry when ready.';
      case RuntimeFailureReason.localRuntimeError:
        return 'A local runtime error occurred. Retry when ready.';
      case RuntimeFailureReason.unknown:
        return 'An unexpected error occurred.';
    }
  }

  List<RuntimeNoticeAction> _normalizeActions(
    List<RuntimeNoticeAction> actions, {
    required RuntimeNoticeStatus status,
  }) {
    if (status != RuntimeNoticeStatus.waiting &&
        status != RuntimeNoticeStatus.blocked &&
        status != RuntimeNoticeStatus.fatal) {
      return actions;
    }
    if (actions.contains(RuntimeNoticeAction.stop)) {
      return actions;
    }
    return [RuntimeNoticeAction.stop, ...actions];
  }

  void _cancelResumeTimer(String sessionId) {
    _resumeTimers.remove(sessionId)?.cancel();
  }

  void _scheduleResume(RuntimeNotice notice, Duration delay) {
    final handler = _resumeHandler;
    if (handler == null) return;
    _cancelResumeTimer(notice.sessionId);
    final safeDelay = delay.isNegative ? Duration.zero : delay;
    _resumeTimers[notice.sessionId] = Timer(safeDelay, () async {
      _resumeTimers.remove(notice.sessionId);
      final active = _active[notice.sessionId];
      if (active == null || active.status != RuntimeNoticeStatus.waiting) {
        return;
      }
      if (_resumeInFlight.contains(notice.sessionId)) {
        return;
      }
      _resumeInFlight.add(notice.sessionId);
      try {
        await handler(active);
      } finally {
        _resumeInFlight.remove(notice.sessionId);
      }
    });
  }
}
