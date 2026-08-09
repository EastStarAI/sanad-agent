import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import '../core/models/message.dart';
import '../core/models/agent_response.dart';
import '../core/models/llm_provider_state.dart';
import '../capabilities/registry/tools_registry.dart';
import '../capabilities/tools/memory_tool.dart';
import 'adapters/llm_adapter.dart';
import 'adapters/llm_request_options.dart';
import '../core/di.dart';
import '../core/config.dart';
import '../evolution/session_manager.dart';
import '../evolution/db/runtime/session_route_mutation_coordinator.dart';
import '../evolution/db/persisted_runtime_state_repository.dart';
import '../evolution/models/pending_steer_record.dart';
import '../evolution/models/session_route_transition.dart';
import '../evolution/memory/file_memory_store.dart';
import '../plugins/plugin_manager.dart';
import '../core/models/tool_call.dart';
import '../core/utils/scrubber.dart';
import '../core/provider_runtime/runtime_failure_reason.dart';
import '../core/provider_runtime/runtime_notice.dart';
import '../core/provider_runtime/runtime_recovery_exception.dart';
import '../core/provider_runtime/runtime_recovery_service.dart';
import '../core/secrets_redactor.dart';
import 'agent_context_assembler.dart';
import 'context_engine.dart';
import 'llm_request_dumper.dart';
import 'history_healer.dart';
import 'metrics_tracker.dart';
import 'tool_concurrency_evaluator.dart';
import 'adapters/llm_http_exception.dart';
import 'adapters/rate_limited_llm_adapter.dart';
import 'adapters/provider_state_rejected_exception.dart';
import 'runtime/continuation_checkpoint_coordinator.dart';
import 'runtime/deferred_tool_result.dart';
import 'runtime/llm_route_snapshot.dart';
import 'runtime/response_continuation_coordinator.dart';
import 'runtime/steer_coordinator.dart' as steer_lib;
import 'runtime/tool_execution_coordinator.dart';
import 'runtime/turn_route_state.dart';

/// Legacy re-exports so existing imports of the steer constants from
/// `agent_runner.dart` continue to work without touching call sites.
export 'runtime/steer_coordinator.dart'
    show steerMarkerOpen, steerMarkerClose, steerChannelNote;

class AgentRunner {
  static final Logger _logger = Logger('AgentRunner');

  final LLMAdapter adapter;
  final ToolsRegistry registry;
  final SessionManager sessionManager;
  final PluginManager pluginManager;
  final ContextEngine contextEngine;
  final DeferredToolResultResolver? _deferredToolResultResolver;
  late final FileMemoryStore memoryStore;
  late final String sessionId;

  List<Message> history = [];
  int _currentTurnStartIndex = 0;
  bool _stopRequested = false;
  bool _allowManualAmbiguousToolRecovery = false;
  Completer<void>? _restartDrainRelease;

  bool get stopRequested => _stopRequested;

  /// Allows one explicit user recovery command to continue past an ambiguous
  /// non-idempotent tool without replaying its side effect. Automatic startup
  /// recovery never enables this policy.
  void allowManualAmbiguousToolRecovery() {
    _allowManualAmbiguousToolRecovery = true;
  }

  void beginControlledRestartDrain() {
    _restartDrainRelease ??= Completer<void>();
  }

  void cancelControlledRestartDrain() {
    final release = _restartDrainRelease;
    _restartDrainRelease = null;
    if (release != null && !release.isCompleted) release.complete();
  }

  Future<void> _waitForControlledRestartDrain() async {
    final release = _restartDrainRelease;
    if (release != null) await release.future;
  }

  static const checkpointKindInitialModelRequest =
      ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest;
  static const checkpointKindAfterToolResult =
      ContinuationCheckpointCoordinator.checkpointKindAfterToolResult;

  void requestStop() {
    _stopRequested = true;
    cancelControlledRestartDrain();
  }

  /// Three-tier context assembler responsible for building the single system
  /// message sent to the LLM on every turn.
  ///
  /// Tiers (stable → context → volatile) are ordered so the longest,
  /// least-changing prefix remains byte-stable across turns, maximizing
  /// LLM prefix-cache reuse. See [AgentContextAssembler] for the full contract.
  final AgentContextAssembler contextAssembler = AgentContextAssembler();

  /// Collaborators extracted in Gate C. Each owns a single cohesive
  /// responsibility and delegates history mutations back to this runner via
  /// callbacks/contracts — no duplicate source of truth.
  late final TurnRouteState _turnRoute;
  late final ContinuationCheckpointCoordinator _checkpointCoordinator;
  late final ToolExecutionCoordinator _toolExecutionCoordinator;
  late final steer_lib.SteerCoordinator _steerCoordinator;

  MetricsTracker? _metricsTracker;
  Future<Map<String, dynamic>?>? _contextUsageSnapshotFuture;
  String? currentModelStepId;
  String? _authoritativeRunId;
  String? _authoritativeWorkItemId;
  int? _authoritativeGeneration;
  LLMRouteSnapshot? _lastSuccessfulLlmRoute;
  void Function(PendingSteerRecord record)? _onPendingSteerChanged;

  /// Exact adapter/provider/model route that completed the latest LLM request
  /// in the current authoritative turn.
  LLMRouteSnapshot? get lastSuccessfulLlmRoute => _lastSuccessfulLlmRoute;

  void beginAuthoritativeRun(
    String? runId, {
    String? workItemId,
    int? generation,
  }) {
    if (runId == null || runId.isEmpty) return;
    _authoritativeRunId = runId;
    _authoritativeWorkItemId = workItemId;
    _authoritativeGeneration = generation;
    _lastSuccessfulLlmRoute = null;
    _turnRoute.setTurnRunId(runId);
  }

  void configurePendingSteerLifecycle({
    required String runId,
    required int generation,
    void Function(PendingSteerRecord record)? onChanged,
  }) {
    _authoritativeRunId = runId;
    _authoritativeGeneration = generation;
    _onPendingSteerChanged = onChanged;
  }

  void endAuthoritativeRun(String? runId) {
    if (runId == null || runId.isEmpty) return;
    if (_authoritativeRunId != runId) return;
    _authoritativeRunId = null;
    _authoritativeWorkItemId = null;
    _authoritativeGeneration = null;
    _onPendingSteerChanged = null;
    _turnRoute.setTurnRunId(null);
  }

  String? get activeModel => _metricsTracker?.activeModel;
  set activeModel(String? value) {
    _metricsTracker ??= MetricsTracker();
    _metricsTracker!.activeModel = value;
  }

  String? get activeProvider => _metricsTracker?.activeProvider;
  set activeProvider(String? value) {
    _metricsTracker ??= MetricsTracker();
    _metricsTracker!.activeProvider = value;
  }

  Map<String, int> get accumulatedUsage =>
      _metricsTracker?.accumulatedUsage ?? const {};

  /// Usage snapshot of the *last* LLM response only (not accumulated).
  /// Use this for UI display so token counts reflect the final context size
  /// rather than summing every intermediate tool-call cycle.
  Map<String, int> get lastUsage => _metricsTracker?.lastUsage ?? const {};
  set accumulatedUsage(Map<String, int> value) {
    _metricsTracker ??= MetricsTracker();
    _metricsTracker!.accumulatedUsage.clear();
    _metricsTracker!.accumulatedUsage.addAll(value);
  }

  DateTime? get runStartTime => _metricsTracker?.runStartTime;
  set runStartTime(DateTime? value) {
    _metricsTracker = MetricsTracker(startTime: value);
  }

  int? get runtimeMs => _metricsTracker?.runtimeMs;

  /// The active model's total context window size, used by the client UI
  /// to compute the "X% ctx" context-fill percentage indicator.
  Future<int?> getContextTokens() async {
    try {
      final routing = _turnRoute.resolveTurnRouting();
      return await _turnRoute.adapterForTurn().getContextLimit(routing.model);
    } catch (_) {
      return null;
    }
  }

  /// Builds one immutable projection for the current model invocation.
  /// Provider values are copied from [lastUsage] without summing or inference.
  Future<Map<String, dynamic>?> getContextUsageSnapshot() {
    return _contextUsageSnapshotFuture ??= _buildContextUsageSnapshot();
  }

  Future<Map<String, dynamic>?> _buildContextUsageSnapshot() async {
    final usage = lastUsage;
    if (usage.isEmpty) return null;
    final contextWindowTokens = await getContextTokens();
    return {
      if (usage['input_tokens'] != null) 'input_tokens': usage['input_tokens'],
      if (usage['output_tokens'] != null)
        'output_tokens': usage['output_tokens'],
      if (usage['total_tokens'] != null) 'total_tokens': usage['total_tokens'],
      if (usage['cached_tokens'] != null)
        'cached_tokens': usage['cached_tokens'],
      if (usage['reasoning_tokens'] != null)
        'reasoning_tokens': usage['reasoning_tokens'],
      'context_window_tokens': ?contextWindowTokens,
      if (activeModel != null) 'model_id': activeModel,
      if (activeProvider != null) 'provider_instance_id': activeProvider,
      if (_authoritativeRunId != null) 'run_id': _authoritativeRunId,
      if (currentModelStepId != null) 'model_step_id': currentModelStepId,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  String? get activeModelDisplay => _metricsTracker?.formatActiveModelDisplay();

  void _updateMetrics(AgentResponse response) {
    _metricsTracker?.updateMetrics(response);
  }

  AgentRunner(
    this.adapter,
    this.registry,
    this.sessionManager, {
    PluginManager? pluginManager,
    ContextEngine? contextEngine,
    String? existingSessionId,
    DeferredToolResultResolver? deferredToolResultResolver,
  }) : pluginManager = pluginManager ?? PluginManager(),
       contextEngine = contextEngine ?? ContextEngine(adapter: adapter),
       _deferredToolResultResolver = deferredToolResultResolver {
    if (existingSessionId != null) {
      final session = sessionManager.getSession(existingSessionId);
      if (session != null) {
        sessionId = session.sessionId;
        history = session.messages.toList();
        _healHistory();
      } else {
        final defaultModel = getIt.isRegistered<Config>()
            ? getIt<Config>().llmModel
            : 'sanad-agent';
        final newSession = sessionManager.createSession(defaultModel);
        sessionId = newSession.sessionId;
      }
    } else {
      final defaultModel = getIt.isRegistered<Config>()
          ? getIt<Config>().llmModel
          : 'sanad-agent';
      final newSession = sessionManager.createSession(defaultModel);
      sessionId = newSession.sessionId;
    }

    _initCollaborators();
    _initPlugins();
    _initMemory();
  }

  void _initCollaborators() {
    _turnRoute = TurnRouteState(
      sessionId: sessionId,
      fallbackAdapter: adapter,
      sessionManager: sessionManager,
      contextAssembler: contextAssembler,
    );
    _checkpointCoordinator = ContinuationCheckpointCoordinator(
      sessionId: sessionId,
    );
    _toolExecutionCoordinator = ToolExecutionCoordinator(
      sessionId: sessionId,
      registry: registry,
      sessionManager: sessionManager,
      pluginManager: pluginManager,
      checkpointCoordinator: _checkpointCoordinator,
      deferredToolResultResolver: _deferredToolResultResolver,
    );
    _steerCoordinator = steer_lib.SteerCoordinator(sessionId: sessionId);
  }

  void _initPlugins() {
    pluginManager.notifySessionStart(sessionId);
  }

  void _initMemory() {
    memoryStore = FileMemoryStore();
    memoryStore.loadFromDisk();
    registry.registerTool(MemoryTool(store: memoryStore));
    final combinedGuidance =
        '${MemoryTool.memoryGuidance}\n\n${steer_lib.steerChannelNote}';
    contextAssembler.setStableGuidance(combinedGuidance);
  }

  void _saveHistory() {
    sessionManager.saveSessionHistory(sessionId, history);
  }

  bool _hasPersistableAssistantState(Message message) {
    return (message.content?.isNotEmpty ?? false) ||
        (message.toolCalls?.isNotEmpty ?? false) ||
        (message.thought?.isNotEmpty ?? false) ||
        (message.reasoning?.isNotEmpty ?? false) ||
        message.providerState != null ||
        message.finishReason != LLMFinishReason.unknown;
  }

  void _healHistory() {
    final suspendedToolCallIds = sessionManager
        .listSuspendedCheckpoints(status: 'awaiting_permission')
        .where((checkpoint) => checkpoint.sessionId == sessionId)
        .map((checkpoint) => checkpoint.toolCallId)
        .toSet();
    final deferredToolCallIds =
        getIt.isRegistered<PersistedRuntimeStateRepository>()
        ? HistoryHealer.deferredToolCallIds(
            workItems: getIt<PersistedRuntimeStateRepository>()
                .findAllWorkItems(sessionId),
            sessionId: sessionId,
          )
        : const <String>{};
    HistoryHealer.healHistory(
      history: history,
      sessionManager: sessionManager,
      sessionId: sessionId,
      suspendedToolCallIds: suspendedToolCallIds,
      deferredToolCallIds: deferredToolCallIds,
    );
  }

  /// Current checkpoint context snapshot for the coordinators.
  CheckpointContext get _checkpointCtx => (
    currentTurnStartIndex: _currentTurnStartIndex,
    currentModelStepId: currentModelStepId,
  );

  void _beginModelStep() {
    currentModelStepId = 'model_step_${const Uuid().v4()}';
    _metricsTracker?.beginInvocation();
    _contextUsageSnapshotFuture = null;
  }

  @visibleForTesting
  Future<void> executeToolCalls(
    List<ToolCall> toolCalls, {
    required bool parallel,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
  }) => _toolExecutionCoordinator.executeToolCalls(
    toolCalls,
    parallel: parallel,
    callbacks: _RunnerToolCallbacks(this),
    ctx: _checkpointCtx,
    onToolEvent: onToolEvent,
  );

  /// Sets the agent's stable identity injected into every LLM request.
  ///
  /// This is NOT stored in [history] or the DB — it is live context that is
  /// rebuilt by [AgentContextAssembler] on each turn so it never accumulates
  /// or duplicates. Maps to the `stable` tier of the assembler.
  void addSystemMessage(String content) {
    contextAssembler.setIdentity(content);
  }

  Future<Message> sendMessage(
    String? userContent, {
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    DateTime? receivedAt,
  }) async {
    _stopRequested = false;
    memoryStore.resetConsolidationFailures();
    _metricsTracker = MetricsTracker();
    final effectiveRequestId = requestId ?? _turnRoute.turnRequestId;
    _turnRoute.configureTurn(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: effectiveRequestId,
    );
    try {
      _turnRoute.applyTurnSwitchIfNeeded();

      _currentTurnStartIndex = history.length;
      final userMessage = Message(
        role: MessageRole.user,
        content: userContent ?? '',
        metadata: {
          if (effectiveRequestId != null && effectiveRequestId.isNotEmpty)
            'request_id': effectiveRequestId,
          'received_at': (receivedAt ?? DateTime.now())
              .toUtc()
              .toIso8601String(),
        },
      );
      history.add(userMessage);
      await pluginManager.notifyMessage(userMessage);
      _saveHistory();
      _beginModelStep();
      _checkpointCoordinator.saveCheckpoint(
        ctx: _checkpointCtx,
        checkpointKind:
            ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest,
        resumeHistoryLength: history.length,
      );

      final response = await _getNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        preserveModelStepId: true,
      );

      // Scrub any hidden context tags from the returned message content for the UI
      if (response.content != null) {
        return response.copyWith(
          content: StreamingScrubber.scrub(response.content!),
        );
      }

      return response;
    } finally {
      _turnRoute.setTurnRequestId(null);
    }
  }

  bool shouldParallelizeToolBatch(List<ToolCall> toolCalls) {
    return ToolConcurrencyEvaluator.shouldParallelizeToolBatch(toolCalls);
  }

  /// Associates an interface request id with the next turn. The id survives
  /// turn configuration and is cleared when the turn completes.
  void setTurnRequestId(String? requestId) {
    _turnRoute.setTurnRequestId(requestId);
  }

  /// Overwrites the active turn's provider/model route mid-flight so that the
  /// next retry loop iteration uses the new route rather than the stale one
  /// (Plan 30 Phase H P1: route override during waiting).
  void updateTurnRoute({String? providerId, String? modelId}) {
    _turnRoute.updateTurnRoute(providerId: providerId, modelId: modelId);
  }

  LLMRequestOptions _requestOptionsForTurn(String? providerInstanceId) {
    return LLMRequestOptions(
      sessionId: sessionId,
      requestId: _turnRoute.turnRequestId,
      providerInstanceId: providerInstanceId,
      thinkingMode: _turnRoute.effectiveThinkingMode,
    );
  }

  void steer(String text) {
    _steerCoordinator.steer(text);
  }

  void steerEvent(String text, {String? requestId, DateTime? receivedAt}) {
    _steerCoordinator.steerEvent(
      text,
      requestId: requestId,
      receivedAt: receivedAt,
    );
  }

  bool cancelBufferedPendingSteer(String requestId) =>
      _steerCoordinator.cancelPendingSteer(requestId);

  void removeBufferedPendingSteers(Iterable<String> requestIds) =>
      _steerCoordinator.removePendingSteers(requestIds);

  bool _reservePendingSteer(steer_lib.PendingSteer steer) {
    final requestId = steer.requestId;
    final runId = _authoritativeRunId;
    final generation = _authoritativeGeneration;
    if (requestId == null ||
        runId == null ||
        generation == null ||
        !getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      return true;
    }
    final mutation = getIt<PersistedRuntimeStateRepository>().pendingInputs
        .reserve(
          sessionId: sessionId,
          requestId: requestId,
          runId: runId,
          generation: generation,
        );
    final record = mutation.record;
    if (record != null) _onPendingSteerChanged?.call(record);
    return mutation.outcome == PendingSteerReserveOutcome.reserved;
  }

  void _markPendingSteerDelivered(steer_lib.PendingSteer steer) {
    final requestId = steer.requestId;
    final runId = _authoritativeRunId;
    final generation = _authoritativeGeneration;
    if (requestId == null ||
        runId == null ||
        generation == null ||
        !getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      return;
    }
    final record = getIt<PersistedRuntimeStateRepository>().pendingInputs
        .markDelivered(
          sessionId: sessionId,
          requestId: requestId,
          runId: runId,
          generation: generation,
        );
    if (record != null) _onPendingSteerChanged?.call(record);
  }

  void _releasePendingSteerAfterDeliveryFailure(steer_lib.PendingSteer steer) {
    final requestId = steer.requestId;
    final runId = _authoritativeRunId;
    final generation = _authoritativeGeneration;
    if (requestId == null ||
        runId == null ||
        generation == null ||
        !getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      return;
    }
    final record = getIt<PersistedRuntimeStateRepository>().pendingInputs
        .releaseDeliveryAfterFailure(
          sessionId: sessionId,
          requestId: requestId,
          runId: runId,
          generation: generation,
        );
    if (record != null) _onPendingSteerChanged?.call(record);
  }

  RuntimeRecoveryService? get _recoveryService =>
      getIt.isRegistered<RuntimeRecoveryService>()
      ? getIt<RuntimeRecoveryService>()
      : null;

  bool _claimOwnedAutomaticRetry() {
    if (!getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      return true;
    }
    final workItemId = _authoritativeWorkItemId;
    final runId = _authoritativeRunId;
    final generation = _authoritativeGeneration;
    if (workItemId == null || runId == null || generation == null) {
      return false;
    }
    return getIt<PersistedRuntimeStateRepository>().claimOwnedAutomaticRetry(
      sessionId: sessionId,
      workItemId: workItemId,
      runId: runId,
      generation: generation,
      requestId: _turnRoute.turnRequestId,
    );
  }

  void _clearResumingOnProviderProgress() {
    _recoveryService?.clearResumingOnProgress(
      sessionId,
      runId: _authoritativeRunId,
    );
  }

  /// Central secrets redactor used when surfacing provider error text in
  /// runtime notices (Plan 30 Phase H §6).
  static const SecretsRedactor _secretsRedactor = SecretsRedactor();

  /// Per-reason automatic retry budget (Plan 30 Phase H §5).
  ///
  /// Deterministic 4xx (auth, billing, model-not-found, content-policy,
  /// payload/format/SSL) and `unknown` get **zero** automatic retries — they
  /// suspend immediately with the original reason. Network/timeout get a small
  /// bounded budget; rate-limit/overloaded retry until they convert to
  /// blocked (handled by the cooldown/retry-after path).
  int _automaticRetryBudget(RuntimeFailureReason reason) {
    switch (reason) {
      case RuntimeFailureReason.networkError:
        // Three total attempts (the initial request plus two retries) absorb
        // short upstream connection resets without creating a long retry loop.
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
      // Deterministic failures: never auto-retry.
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

  Duration _fallbackRetryDelay(RuntimeFailureReason reason, int attempt) {
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

  /// Builds a single user-facing `message` from an app description plus the
  /// redacted provider response when available (Plan 30 Phase H §6). Never
  /// appends raw/un-redacted provider text.
  String _buildNoticeMessage(
    RuntimeFailureReason reason,
    String? providerBody,
    String? providerDisplayName,
  ) {
    final base = _defaultAppMessage(reason, providerDisplayName);
    final raw = providerBody?.trim();
    if (raw == null || raw.isEmpty) return base;
    final redacted = _secretsRedactor.redact(raw);
    // Avoid duplicating the provider text when it is already similar to base.
    return '$base\n\nProvider response: $redacted';
  }

  String _defaultAppMessage(
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

  LlmHttpException? _asHttpFailure(Object error) => switch (error) {
    LlmHttpException failure => failure,
    ProviderStateRejectedException rejected => rejected.httpFailure,
    _ => null,
  };

  List<Message>? _recoverRejectedProviderState(
    Object error,
    ResponseContinuationCoordinator continuation,
    List<Message> effectiveHistory,
  ) {
    if (error is! ProviderStateRejectedException ||
        !continuation.claimProviderStateFallback()) {
      return null;
    }

    final updatedHistory = _clearRejectedProviderState(history, error);
    final updatedEffectiveHistory = _clearRejectedProviderState(
      effectiveHistory,
      error,
    );
    final historyChanged = !_sameMessageIdentities(history, updatedHistory);
    history = updatedHistory;
    if (historyChanged) _saveHistory();
    return updatedEffectiveHistory;
  }

  List<Message> _clearRejectedProviderState(
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

  static bool _sameMessageIdentities(List<Message> left, List<Message> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!identical(left[index], right[index])) return false;
    }
    return true;
  }

  Future<bool> _handleRuntimeFailure(
    Object error, {
    required String? providerInstanceId,
    required String? modelId,
    required int attempt,
    required bool streamStarted,
    required Set<String> failedProviderInstanceIds,
  }) async {
    if (error is RateLimitCancelled) {
      throw RuntimeRecoveryCancelled(sessionId);
    }
    final recovery = _recoveryService;
    if (recovery == null ||
        providerInstanceId == null ||
        providerInstanceId.isEmpty) {
      return false;
    }
    final httpFailure = _asHttpFailure(error);
    final httpRetryAfter = httpFailure?.retryAfter;
    // For HTTP failures, use the raw body for classification and the notice
    // message. For non-HTTP errors (network, SSL, etc.) use toString() for
    // both classification and the redacted notice message (Plan 30 P1 §4).
    final providerBody = httpFailure?.body ?? error.toString();
    final reason = RuntimeFailureReason.classify(
      statusCode: httpFailure?.statusCode,
      body: providerBody,
      hasTrustedTemporaryReset: httpRetryAfter != null,
    );
    // When the failure is non-HTTP (no statusCode), retryAfter comes from
    // the fallback delay only — no header to parse.
    final retryAfter = httpRetryAfter ?? _fallbackRetryDelay(reason, attempt);
    final decision = reason.decision();
    // Per-reason budget (Phase H §5). Deterministic 4xx + unknown get 0.
    final budget = _automaticRetryBudget(reason);
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
          sessionId: sessionId,
          reason: reason,
          providerInstanceId: providerInstanceId,
          requestId: _turnRoute.turnRequestId,
          retryAfter: retryAfter,
          runId: _authoritativeRunId,
        );
        if (getIt.isRegistered<SessionRouteMutationCoordinator>()) {
          final routeCoordinator = getIt<SessionRouteMutationCoordinator>();
          final persisted = getIt
              .isRegistered<PersistedRuntimeStateRepository>();
          final claimed = persisted
              ? routeCoordinator.claimAutoFailover(
                  sessionId: sessionId,
                  workItemId: _authoritativeWorkItemId,
                  runId: _authoritativeRunId,
                  generation: _authoritativeGeneration,
                  expectedProviderInstanceId: providerInstanceId,
                  providerInstanceId: candidate.id,
                  model: modelId!,
                  reason: reason.name.replaceAllMapped(
                    RegExp(r'([A-Z])'),
                    (match) => '_${match.group(1)!.toLowerCase()}',
                  ),
                  requestId: _turnRoute.turnRequestId,
                  publish: true,
                )
              : routeCoordinator.mutate(
                  sessionId: sessionId,
                  providerInstanceId: candidate.id,
                  model: modelId!,
                  source: SessionRouteSource.autoFailover,
                  reason: reason.name.replaceAllMapped(
                    RegExp(r'([A-Z])'),
                    (match) => '_${match.group(1)!.toLowerCase()}',
                  ),
                  requestId: _turnRoute.turnRequestId,
                  publish: true,
                );
          if (persisted && claimed == null) {
            throw RuntimeRecoveryRequired(sessionId, reason);
          }
        } else {
          // Isolated runner tests may omit the production persistence graph.
          sessionManager.updateSessionProviderId(sessionId, candidate.id);
        }
        _turnRoute.rewriteQueuedProvider(candidate.id);
        recovery.emitResuming(
          sessionId: sessionId,
          reason: 'auto_failover',
          requestId: _turnRoute.turnRequestId,
          providerInstanceId: candidate.id,
          providerDisplayName: candidate.displayName,
          message: 'Continuing automatically with ${candidate.displayName}.',
          runId: _authoritativeRunId,
        );
        return true;
      }
    }

    // Only reasons with a budget > 0 and retryable may auto-retry, and only
    // before the budget is exhausted (Phase H §5). Deterministic 4xx and
    // unknown fall straight through to a suspended blocked/fatal notice.
    if (!streamStarted && budget > 0 && !exhaustedAutomaticRetries) {
      recovery.reportFailure(
        sessionId: sessionId,
        reason: reason,
        providerInstanceId: providerInstanceId,
        requestId: _turnRoute.turnRequestId,
        retryAfter: retryAfter,
        runId: _authoritativeRunId,
      );
      final resumed = await recovery.waitForRetry(
        sessionId,
        retryAfter,
        runId: _authoritativeRunId,
      );
      if (!resumed) {
        if (recovery.isStopped(sessionId, runId: _authoritativeRunId)) {
          throw RuntimeRecoveryCancelled(sessionId);
        }
        // A provider change, manual retry, or queued-message handoff wakes the
        // same runner by aborting its retry timer. The durable work item still
        // owns `waiting` at this point, so reclaim it before issuing another
        // provider request. Continuing without this transition leaves the
        // client snapshot stuck on `waiting` and makes the later terminal
        // commit lose to recovery ownership.
        if (!_claimOwnedAutomaticRetry()) {
          _logger.info(
            'Interrupted retry lost durable ownership for session $sessionId; '
            'leaving recovery state authoritative.',
          );
          throw RuntimeRecoveryRequired(sessionId, reason);
        }
        _turnRoute.refreshFromSession();
        return true;
      }
      if (!_claimOwnedAutomaticRetry()) {
        _logger.info(
          'Automatic retry lost durable ownership for session $sessionId; '
          'leaving recovery state authoritative.',
        );
        throw RuntimeRecoveryRequired(sessionId, reason);
      }
      recovery.emitResuming(
        sessionId: sessionId,
        reason: 'retrying',
        requestId: _turnRoute.turnRequestId,
        providerInstanceId: providerInstanceId,
        message: 'Retrying the last request.',
        runId: _authoritativeRunId,
      );
      return true;
    }

    // Suspended state: keep the ORIGINAL reason and message. Do not rewrite
    // the reason to `unknown` and do not replace the message with a generic
    // "Recovery needs your input" (Plan 30 Phase H §5, §6). The provider
    // response (if any) is appended after central redaction.
    //
    // P1 §3: when the automatic retry budget for a waiting-class reason is
    // exhausted, force the notice to `blocked` so the client shows
    // Stop / Retry / Change Provider instead of a waiting spinner with no timer.
    final budgetExhaustedWaiting =
        exhaustedAutomaticRetries &&
        reason.decision().noticeStatus == RuntimeNoticeStatus.waiting;
    final displayName = recovery.providerDisplayName(providerInstanceId);
    recovery.reportFailure(
      sessionId: sessionId,
      reason: reason,
      providerInstanceId: providerInstanceId,
      requestId: _turnRoute.turnRequestId,
      retryAfter: budgetExhaustedWaiting ? null : retryAfter,
      message: _buildNoticeMessage(reason, providerBody, displayName),
      forceBlocked: budgetExhaustedWaiting,
      runId: _authoritativeRunId,
    );
    throw RuntimeRecoveryRequired(sessionId, reason);
  }

  Future<Message> _getNextResponse({
    String? runtimeSystemPrompt,
    bool preserveModelStepId = false,
    ResponseContinuationCoordinator? continuation,
  }) async {
    continuation ??= ResponseContinuationCoordinator();
    if (!preserveModelStepId || currentModelStepId == null) {
      _beginModelStep();
    }
    _checkpointCoordinator.saveCheckpoint(
      ctx: _checkpointCtx,
      resumeHistoryLength: history.length,
    );
    final tools = registry.allTools.map((t) => t.schema).toList();

    _steerCoordinator.drainPreApiSteer(_RunnerSteerCallbacks(this));

    // Resolve the live turn-scoped adapter before context compression so the
    // compressor uses the current provider route, never a stale singleton
    // frozen before a provider was configured.
    final preRouteAdapter = _turnRoute.adapterForTurn();

    // Apply context compression
    history = await contextEngine.compressIfNeeded(
      history,
      adapter: preRouteAdapter,
    );

    // Prepare effective history with memory injection
    var effectiveHistory = _buildEffectiveHistory(
      runtimeSystemPrompt: runtimeSystemPrompt,
    );

    // Run plugins pre-execution
    effectiveHistory = await pluginManager.runPreExecution(effectiveHistory);

    _logger.info('🧠 [Agent] Thinking...');

    final routing = _turnRoute.resolveTurnRouting();
    var model = routing.model;
    var provider = routing.providerId;
    var baseUrl = routing.baseUrl;
    var apiKey = routing.apiKey;
    _turnRoute.cacheResolvedRoute(_turnRoute.adapterForTurn(), model);

    if (provider != null && model != null) {
      activeProvider = provider;
      activeModel = model;
    }

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.dumpRequest(
        sessionId: sessionId,
        history: effectiveHistory,
        tools: tools,
        model: model,
        provider: provider,
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
    }

    AgentResponse response;
    final attemptsByProviderInstanceId = <String, int>{};
    final failedProviderInstanceIds = <String>{};
    while (true) {
      try {
        final route = _turnRoute.routeForTurn();
        response = await route.adapter.generateResponse(
          effectiveHistory,
          tools: tools,
          modelOverride: route.modelOverride,
          options: _requestOptionsForTurn(provider),
        );
        _lastSuccessfulLlmRoute = LLMRouteSnapshot(
          adapter: _providerAdapterForBackground(route.adapter),
          providerInstanceId: provider,
          modelOverride: route.modelOverride,
        );
        _clearResumingOnProviderProgress();
        break;
      } catch (e) {
        _turnRoute.invalidateResolvedRoute();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.recordError(e);
        }
        final sanitizedHistory = _recoverRejectedProviderState(
          e,
          continuation,
          effectiveHistory,
        );
        if (sanitizedHistory != null) {
          effectiveHistory = sanitizedHistory;
          continue;
        }
        final providerAttempt = provider == null
            ? 0
            : attemptsByProviderInstanceId[provider] ?? 0;
        final handled = await _handleRuntimeFailure(
          e,
          providerInstanceId: provider,
          modelId: model,
          attempt: providerAttempt,
          streamStarted: false,
          failedProviderInstanceIds: failedProviderInstanceIds,
        );
        if (!handled) {
          rethrow;
        }
        if (provider != null) {
          attemptsByProviderInstanceId[provider] = providerAttempt + 1;
        }
        final refreshedRouting = _turnRoute.resolveTurnRouting();
        model = refreshedRouting.model;
        provider = refreshedRouting.providerId;
        baseUrl = refreshedRouting.baseUrl;
        apiKey = refreshedRouting.apiKey;
      }
    }
    _turnRoute.invalidateResolvedRoute();
    _updateMetrics(response);
    final responseMessage = response.message.copyWith(
      finishReason: response.finishReason == LLMFinishReason.unknown
          ? response.message.finishReason
          : response.finishReason,
      metadata: {
        ...?response.message.metadata,
        if (_authoritativeRunId != null) 'run_id': _authoritativeRunId,
        if (currentModelStepId != null) 'model_step_id': currentModelStepId,
      },
    );

    if (_hasPersistableAssistantState(responseMessage)) {
      history.add(responseMessage);
      await pluginManager.notifyMessage(responseMessage);
      await pluginManager.runPostExecution(responseMessage);
      _saveHistory();
    }

    if (responseMessage.toolCalls?.isNotEmpty ?? false) {
      final toolCalls = responseMessage.toolCalls!;
      await _waitForControlledRestartDrain();
      await _toolExecutionCoordinator.executeToolCalls(
        toolCalls,
        parallel: shouldParallelizeToolBatch(toolCalls),
        callbacks: _RunnerToolCallbacks(this),
        ctx: _checkpointCtx,
      );
      return await _getNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        continuation: continuation,
      );
    }

    if (_steerCoordinator.hasPendingSteers) {
      _steerCoordinator.markLastAssistantSupersededBySteer(
        _RunnerSteerCallbacks(this),
      );
      _steerCoordinator.appendPendingSteersAsUserMessages(
        _RunnerSteerCallbacks(this),
      );
      return await _getNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        continuation: continuation,
      );
    }

    if (responseMessage.finishReason == LLMFinishReason.incomplete &&
        continuation.claimIncompleteContinuation()) {
      return await _getNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        continuation: continuation,
      );
    }

    _logger.info('🏁 [Agent] Final Answer: ${responseMessage.content ?? ''}');
    return responseMessage;
  }

  Stream<String> streamMessage(
    String? userContent, {
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    DateTime? receivedAt,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    if (_stopRequested) return;
    _stopRequested = false;
    memoryStore.resetConsolidationFailures();
    _metricsTracker = MetricsTracker();
    final effectiveRequestId = requestId ?? _turnRoute.turnRequestId;
    _turnRoute.configureTurn(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: effectiveRequestId,
    );
    _turnRoute.applyTurnSwitchIfNeeded();

    _currentTurnStartIndex = history.length;
    final userMessage = Message(
      role: MessageRole.user,
      content: userContent ?? '',
      metadata: {
        if (effectiveRequestId != null && effectiveRequestId.isNotEmpty)
          'request_id': effectiveRequestId,
        'received_at': (receivedAt ?? DateTime.now()).toUtc().toIso8601String(),
      },
    );
    history.add(userMessage);
    await pluginManager.notifyMessage(userMessage);
    _saveHistory();
    _beginModelStep();
    _checkpointCoordinator.saveCheckpoint(
      ctx: _checkpointCtx,
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest,
      resumeHistoryLength: history.length,
    );

    final scrubber = StreamingScrubber();
    try {
      await for (final chunk in _streamNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        onToolEvent: onToolEvent,
        onSteerContinuation: onSteerContinuation,
        onThoughtDelta: onThoughtDelta,
        onReasoningDelta: onReasoningDelta,
        preserveModelStepId: true,
      )) {
        final cleanChunk = scrubber.feed(chunk);
        if (cleanChunk.isNotEmpty) {
          yield cleanChunk;
        }
      }
    } finally {
      _turnRoute.setTurnRequestId(null);
    }
  }

  Stream<String> resumeStream({
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    try {
      await _restoreCheckpointForResume();
    } catch (e) {
      _checkpointCoordinator.blockWorkItemOnResumeFailure(e);
      rethrow;
    }
    final effectiveRequestId = requestId ?? _turnRoute.turnRequestId;
    _turnRoute.configureTurn(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: effectiveRequestId,
    );
    _turnRoute.applyTurnSwitchIfNeeded();

    final scrubber = StreamingScrubber();
    try {
      await for (final chunk in _streamNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        onToolEvent: onToolEvent,
        onSteerContinuation: onSteerContinuation,
        onThoughtDelta: onThoughtDelta,
        onReasoningDelta: onReasoningDelta,
        preserveModelStepId: true,
      )) {
        final cleanChunk = scrubber.feed(chunk);
        if (cleanChunk.isNotEmpty) {
          yield cleanChunk;
        }
      }
    } finally {
      _turnRoute.setTurnRequestId(null);
    }
  }

  /// Patches the last assistant [Message] in history with [metadata] (usage, model,
  /// provider, context_tokens, runtime_ms) and re-saves the session to the DB.
  /// Must be called after [streamMessage] or [sendMessage] completes so each
  /// reply carries its own independent statistics when history is reconstructed.
  void attachMetadataToLastAssistantMessage(Map<String, dynamic> metadata) {
    // Find last assistant message (skip tool messages appended after it)
    final idx = history.lastIndexWhere((m) => m.role == MessageRole.assistant);
    if (idx == -1) return;

    final updated = history[idx].copyWith(
      metadata: {...?history[idx].metadata, ...metadata},
    );
    history[idx] = updated;
    _saveHistory();
  }

  Stream<String> _streamNextResponse({
    String? runtimeSystemPrompt,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    void Function()? onSteerContinuation,
    bool preserveModelStepId = false,
    ResponseContinuationCoordinator? continuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    continuation ??= ResponseContinuationCoordinator();
    if (!preserveModelStepId || currentModelStepId == null) {
      _beginModelStep();
    }
    _checkpointCoordinator.saveCheckpoint(
      ctx: _checkpointCtx,
      resumeHistoryLength: history.length,
    );
    final tools = registry.allTools.map((t) => t.schema).toList();

    _steerCoordinator.drainPreApiSteer(_RunnerSteerCallbacks(this));

    // Resolve the live turn-scoped adapter before context compression so the
    // compressor uses the current provider route, never a stale singleton
    // frozen before a provider was configured.
    final preRouteAdapter = _turnRoute.adapterForTurn();

    // Apply context compression
    history = await contextEngine.compressIfNeeded(
      history,
      adapter: preRouteAdapter,
    );

    // Prepare effective history with memory injection
    var effectiveHistory = _buildEffectiveHistory(
      runtimeSystemPrompt: runtimeSystemPrompt,
    );

    // Run plugins pre-execution
    effectiveHistory = await pluginManager.runPreExecution(effectiveHistory);

    String fullContent = '';
    List<ToolCall>? accumulatedToolCalls;
    String? thought;
    String? reasoning;
    LLMProviderState? providerState;
    var finishReason = LLMFinishReason.unknown;
    final accumulatedMessageMetadata = <String, dynamic>{};

    bool isToolCall = false;
    Message? lastMessage;
    var streamStarted = false;

    _logger.info('🧠 [Agent] Thinking...');

    final routing = _turnRoute.resolveTurnRouting();
    var model = routing.model;
    var provider = routing.providerId;
    var baseUrl = routing.baseUrl;
    var apiKey = routing.apiKey;
    _turnRoute.cacheResolvedRoute(_turnRoute.adapterForTurn(), model);

    if (provider != null && model != null) {
      activeProvider = provider;
      activeModel = model;
    }

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.dumpRequest(
        sessionId: sessionId,
        history: effectiveHistory,
        tools: tools,
        model: model,
        provider: provider,
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
    }

    final attemptsByProviderInstanceId = <String, int>{};
    final failedProviderInstanceIds = <String>{};
    while (true) {
      if (_stopRequested) return;
      try {
        final route = _turnRoute.routeForTurn();
        await for (final response in route.adapter.generateStream(
          effectiveHistory,
          tools: tools,
          modelOverride: route.modelOverride,
          options: _requestOptionsForTurn(provider),
        )) {
          if (_stopRequested) return;
          _clearResumingOnProviderProgress();
          // Any provider event makes a transparent retry unsafe: reasoning,
          // metadata, or a partial tool call may already be visible or carry
          // state even when no final-content text has arrived yet.
          streamStarted = true;
          _updateMetrics(response);
          lastMessage = response.message;
          if (response.finishReason != LLMFinishReason.unknown) {
            finishReason = response.finishReason;
          }
          if (response.message.toolCalls?.isNotEmpty ?? false) {
            isToolCall = true;
            accumulatedToolCalls ??= [];
            accumulatedToolCalls.addAll(response.message.toolCalls!);
          }

          if (response.message.thought != null) {
            final thoughtDelta = response.message.thought!;
            thought = (thought ?? '') + thoughtDelta;
            if (thoughtDelta.isNotEmpty && onThoughtDelta != null) {
              await onThoughtDelta(thoughtDelta);
            }
          }
          if (response.message.reasoning != null) {
            final reasoningDelta = response.message.reasoning!;
            reasoning = (reasoning ?? '') + reasoningDelta;
            if (reasoningDelta.isNotEmpty && onReasoningDelta != null) {
              await onReasoningDelta(reasoningDelta);
            }
          }
          if (response.message.providerState != null) {
            providerState = response.message.providerState;
          }
          if (response.message.metadata != null) {
            accumulatedMessageMetadata.addAll(response.message.metadata!);
          }

          final chunk = response.message.content ?? '';
          fullContent += chunk;
          if (chunk.isNotEmpty) {
            yield chunk;
          }
        }
        _lastSuccessfulLlmRoute = LLMRouteSnapshot(
          adapter: _providerAdapterForBackground(route.adapter),
          providerInstanceId: provider,
          modelOverride: route.modelOverride,
        );
        if (_stopRequested) return;
        break;
      } catch (e) {
        _turnRoute.invalidateResolvedRoute();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.recordError(e);
        }
        final sanitizedHistory = _recoverRejectedProviderState(
          e,
          continuation,
          effectiveHistory,
        );
        if (sanitizedHistory != null) {
          effectiveHistory = sanitizedHistory;
          continue;
        }
        final providerAttempt = provider == null
            ? 0
            : attemptsByProviderInstanceId[provider] ?? 0;
        final handled = await _handleRuntimeFailure(
          e,
          providerInstanceId: provider,
          modelId: model,
          attempt: providerAttempt,
          streamStarted: streamStarted,
          failedProviderInstanceIds: failedProviderInstanceIds,
        );
        if (!handled) {
          rethrow;
        }
        if (provider != null) {
          attemptsByProviderInstanceId[provider] = providerAttempt + 1;
        }
        final refreshedRouting = _turnRoute.resolveTurnRouting();
        model = refreshedRouting.model;
        provider = refreshedRouting.providerId;
        baseUrl = refreshedRouting.baseUrl;
        apiKey = refreshedRouting.apiKey;
      }
    }
    _turnRoute.invalidateResolvedRoute();

    if (_stopRequested) return;

    if (lastMessage != null) {
      if (lastMessage.toolCalls != null && lastMessage.toolCalls!.isNotEmpty) {
        isToolCall = true;
      }

      final assistantMessage = Message(
        role: MessageRole.assistant,
        content: fullContent.isEmpty ? null : fullContent,
        toolCalls: accumulatedToolCalls ?? lastMessage.toolCalls,
        thought: thought ?? lastMessage.thought,
        reasoning: reasoning ?? lastMessage.reasoning,
        providerState: providerState ?? lastMessage.providerState,
        finishReason: finishReason == LLMFinishReason.unknown
            ? lastMessage.finishReason
            : finishReason,
        metadata: {
          ...accumulatedMessageMetadata,
          if (_authoritativeRunId != null) 'run_id': _authoritativeRunId,
          if (currentModelStepId != null) 'model_step_id': currentModelStepId,
        },
      );
      if (_hasPersistableAssistantState(assistantMessage)) {
        history.add(assistantMessage);
        await pluginManager.notifyMessage(assistantMessage);
        await pluginManager.runPostExecution(assistantMessage);
        _saveHistory();
      }

      if (isToolCall && assistantMessage.toolCalls != null) {
        if (_stopRequested) return;
        final toolCalls = assistantMessage.toolCalls!;
        await _waitForControlledRestartDrain();
        if (_stopRequested) return;
        await _toolExecutionCoordinator.executeToolCalls(
          toolCalls,
          parallel: shouldParallelizeToolBatch(toolCalls),
          callbacks: _RunnerToolCallbacks(this),
          ctx: _checkpointCtx,
          onToolEvent: onToolEvent,
        );
        if (_stopRequested) return;
        yield* _streamNextResponse(
          runtimeSystemPrompt: runtimeSystemPrompt,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          continuation: continuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      } else {
        if (_steerCoordinator.hasPendingSteers) {
          _steerCoordinator.markLastAssistantSupersededBySteer(
            _RunnerSteerCallbacks(this),
          );
          _steerCoordinator.appendPendingSteersAsUserMessages(
            _RunnerSteerCallbacks(this),
          );
          onSteerContinuation?.call();
          yield* _streamNextResponse(
            runtimeSystemPrompt: runtimeSystemPrompt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            continuation: continuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
          return;
        }
        if (assistantMessage.finishReason == LLMFinishReason.incomplete &&
            continuation.claimIncompleteContinuation()) {
          yield* _streamNextResponse(
            runtimeSystemPrompt: runtimeSystemPrompt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            continuation: continuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
          return;
        }
        _logger.info('🏁 [Agent] Final Answer: $fullContent');
      }
    } else if (fullContent.isNotEmpty) {
      _logger.info('🏁 [Agent] Final Answer: $fullContent');
      final assistantMessage = Message(
        role: MessageRole.assistant,
        content: fullContent,
        metadata: {
          if (_authoritativeRunId != null) 'run_id': _authoritativeRunId,
          if (currentModelStepId != null) 'model_step_id': currentModelStepId,
        },
      );
      history.add(assistantMessage);
      await pluginManager.notifyMessage(assistantMessage);
      await pluginManager.runPostExecution(assistantMessage);
      _saveHistory();
      if (_steerCoordinator.hasPendingSteers) {
        _steerCoordinator.markLastAssistantSupersededBySteer(
          _RunnerSteerCallbacks(this),
        );
        _steerCoordinator.appendPendingSteersAsUserMessages(
          _RunnerSteerCallbacks(this),
        );
        onSteerContinuation?.call();
        yield* _streamNextResponse(
          runtimeSystemPrompt: runtimeSystemPrompt,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      }
    }
  }

  Stream<String> resumeAfterToolCall({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    String? runtimeSystemPrompt,
    String? forcedOutput,
    bool forcedIsError = false,
    Future<void> Function({
      required String toolName,
      String? input,
      String? output,
      required bool isError,
      required bool isStart,
      String? toolRunId,
    })?
    onToolEvent,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) async* {
    try {
      await _toolExecutionCoordinator.executeSingleToolCall(
        ToolCall(id: toolCallId, name: toolName, arguments: arguments),
        callbacks: _RunnerToolCallbacks(this),
        onToolEvent: onToolEvent,
        emitStartEvent: false,
        forcedOutput: forcedOutput,
        forcedIsError: forcedIsError,
      );
    } catch (e) {
      _checkpointCoordinator.blockWorkItemOnResumeFailure(e);
      rethrow;
    }
    _checkpointCoordinator.saveCheckpoint(
      ctx: _checkpointCtx,
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindAfterToolResult,
      resumeHistoryLength: history.length,
    );
    yield* _streamNextResponse(
      runtimeSystemPrompt: runtimeSystemPrompt,
      onToolEvent: onToolEvent,
      onThoughtDelta: onThoughtDelta,
      onReasoningDelta: onReasoningDelta,
    );
  }

  Future<void> _restoreCheckpointForResume() async {
    final allowAmbiguousToolInterruption = _allowManualAmbiguousToolRecovery;
    _allowManualAmbiguousToolRecovery = false;
    final result = _checkpointCoordinator.restoreCheckpointForResume(
      currentHistoryLength: history.length,
      allowAmbiguousToolInterruption: allowAmbiguousToolInterruption,
    );
    if (result.resumeHistoryLength < 0) return; // no-op (no repo / no item)

    final recoveryToolCallIds = <String>{
      ...result.ambiguousToolCallIds,
      ...result.deferredToolCallIds,
    }.toList();
    final recoveryBatch = recoveryToolCallIds.isEmpty
        ? null
        : _findAssistantToolBatch(recoveryToolCallIds);
    if (recoveryToolCallIds.isNotEmpty && recoveryBatch == null) {
      throw StateError(
        'Cannot continue session $sessionId: the durable assistant tool-call '
        'batch for the recovering tools is missing from conversation history.',
      );
    }

    if (history.length > result.resumeHistoryLength) {
      history = history.take(result.resumeHistoryLength).toList(growable: true);
      if (recoveryBatch != null &&
          !_containsAssistantToolBatch(recoveryBatch.toolCalls!)) {
        history.add(recoveryBatch);
      }
      _saveHistory();
    }

    if (result.savedTurnStartIndex != null) {
      _currentTurnStartIndex = result.savedTurnStartIndex!;
    }

    if (result.savedModelStepId != null) {
      currentModelStepId = result.savedModelStepId;
    }

    if (recoveryBatch != null) {
      final toolCalls = recoveryBatch.toolCalls!;
      if (result.ambiguousToolCallIds.isNotEmpty) {
        _recordAmbiguousToolInterruptions(
          result.ambiguousToolCallIds,
          toolCalls,
        );
      }
      await _toolExecutionCoordinator.executeToolCalls(
        toolCalls,
        parallel: shouldParallelizeToolBatch(toolCalls),
        callbacks: _RunnerToolCallbacks(this),
        ctx: _checkpointCtx,
      );
    }
  }

  Message? _findAssistantToolBatch(List<String> requiredToolCallIds) {
    final requiredIds = requiredToolCallIds.toSet();
    for (final message in history.reversed) {
      final calls = message.toolCalls;
      if (message.role != MessageRole.assistant || calls == null) continue;
      final batchIds = calls.map((call) => call.id).toSet();
      if (batchIds.containsAll(requiredIds)) return message;
    }
    return null;
  }

  bool _containsAssistantToolBatch(List<ToolCall> expectedCalls) {
    final expectedIds = expectedCalls.map((call) => call.id).toList();
    return history.any((message) {
      if (message.role != MessageRole.assistant) return false;
      final actualIds = message.toolCalls?.map((call) => call.id).toList();
      if (actualIds == null || actualIds.length != expectedIds.length) {
        return false;
      }
      for (var index = 0; index < expectedIds.length; index++) {
        if (actualIds[index] != expectedIds[index]) return false;
      }
      return true;
    });
  }

  void _recordAmbiguousToolInterruptions(
    List<String> toolCallIds,
    List<ToolCall> durableBatch,
  ) {
    const interruptionResult =
        'Error: Tool execution was interrupted before completion could be '
        'confirmed. The outcome is unknown, and the tool was not executed '
        'again to avoid duplicating side effects.';
    final completedResults = <String, String>{};
    final completedOutputs = <String, Map<String, dynamic>>{};
    final callsById = {for (final call in durableBatch) call.id: call};

    for (final toolCallId in toolCallIds) {
      final matchedCall = callsById[toolCallId];
      if (matchedCall == null) {
        throw StateError(
          'Cannot continue session $sessionId: interrupted tool $toolCallId '
          'is missing from its durable assistant tool-call batch.',
        );
      }
      completedResults[toolCallId] = interruptionResult;
      completedOutputs[toolCallId] = _checkpointCoordinator.toolOutputRecord(
        matchedCall,
        interruptionResult,
        isError: true,
        sentToProvider: false,
      );
    }

    _checkpointCoordinator.saveCheckpoint(
      ctx: _checkpointCtx,
      additionalToolResults: completedResults,
      additionalToolOutputs: completedOutputs,
      currentlyExecutingToolCallIds: const [],
    );
  }

  LLMAdapter _providerAdapterForBackground(LLMAdapter turnAdapter) {
    return switch (turnAdapter) {
      RateLimitedLLMAdapter() => turnAdapter.providerAdapter,
      _ => turnAdapter,
    };
  }

  /// Builds the effective message list sent to the LLM on every turn.
  ///
  /// [history] contains ONLY user/assistant/tool messages — no system messages
  /// are ever stored there. All system context is assembled by
  /// [AgentContextAssembler] into a single `system` message prepended here.
  ///
  /// The three-tier structure (stable → context → volatile) inside the
  /// assembled string is ordered for maximum LLM prefix-cache efficiency:
  /// the stable identity block (longest, never changes) lives at the top so
  /// providers can reuse its cached KV-state across turns.
  ///
  ///   system message  ← assembled from stable + context + volatile
  ///   user message 1
  ///   agent message 1
  ///   user message 2
  ///   ...
  List<Message> _buildEffectiveHistory({String? runtimeSystemPrompt}) {
    // history only contains user/assistant/tool messages — safe to copy as-is.
    final effectiveHistory = List<Message>.from(history);

    // Update volatile tier with the current turn's live data.
    final memorySections = <String>[];
    final memoryBlock = memoryStore.formatForSystemPrompt('memory');
    if (memoryBlock != null) {
      memorySections.add(memoryBlock);
    }
    final userBlock = memoryStore.formatForSystemPrompt('user');
    if (userBlock != null) {
      memorySections.add(userBlock);
    }
    contextAssembler.setVolatile(
      memoryContext: memorySections.join('\n\n'),
      sessionId: sessionId,
      model: _turnRoute.effectiveModel ?? activeModel,
      provider:
          activeProvider ??
          (getIt.isRegistered<Config>()
              ? getIt<Config>().resolveProviderName()
              : null),
    );

    // Update context tier if a per-turn workspace context was supplied.
    // LocalRuntimeOrchestrator passes this on every turn; non-workspace turns
    // pass null which preserves the previously set context (or none).
    if (runtimeSystemPrompt != null) {
      contextAssembler.setContext(runtimeSystemPrompt);
    }

    // Assemble all tiers into one system message and prepend to history.
    final systemContent = contextAssembler.assemble();
    if (systemContent != null) {
      effectiveHistory.insert(
        0,
        Message(role: MessageRole.system, content: systemContent),
      );
    }
    return effectiveHistory;
  }
}

/// Bridges [ToolExecutionCoordinator] history mutations back to the runner
/// so the coordinator never owns a history list.
class _RunnerToolCallbacks implements ToolExecutionCallbacks {
  final AgentRunner _runner;

  _RunnerToolCallbacks(this._runner);

  @override
  Future<void> addToolMessage(
    ToolCall toolCall,
    String result, {
    required bool isError,
  }) async {
    final toolMessage = Message(
      role: MessageRole.tool,
      content: result,
      toolCallId: toolCall.id,
      metadata: {
        if (_runner._authoritativeRunId != null)
          'run_id': _runner._authoritativeRunId,
        'tool_call_id': toolCall.id,
        if (_runner.currentModelStepId != null)
          'model_step_id': _runner.currentModelStepId,
        'is_error': isError,
      },
    );
    _runner.history.add(toolMessage);
    await _runner.pluginManager.notifyMessage(toolMessage);
    _runner._saveHistory();
    _runner.sessionManager.deleteSuspendedCheckpointByToolCallId(toolCall.id);
  }

  @override
  bool isToolMessagePresent(String toolCallId) {
    return _runner.history.any(
      (m) => m.role == MessageRole.tool && m.toolCallId == toolCallId,
    );
  }

  @override
  void saveHistory() => _runner._saveHistory();

  @override
  int currentHistoryLength() => _runner.history.length;

  @override
  void applyPendingSteerToToolResults(int numToolCalls) {
    _runner._steerCoordinator.applyPendingSteerToToolResults(
      numToolCalls,
      _RunnerSteerCallbacks(_runner),
    );
  }
}

/// Bridges [SteerCoordinator] history access back to the runner so the
/// coordinator never owns a history list.
class _RunnerSteerCallbacks implements steer_lib.SteerCallbacks {
  final AgentRunner _runner;

  _RunnerSteerCallbacks(this._runner);

  @override
  int get currentTurnStartIndex => _runner._currentTurnStartIndex;

  @override
  int get historyLength => _runner.history.length;

  @override
  MessageRole messageRoleAt(int index) => _runner.history[index].role;

  @override
  String? messageContentAt(int index) => _runner.history[index].content;

  @override
  Map<String, dynamic>? messageMetadataAt(int index) =>
      _runner.history[index].metadata;

  @override
  void updateMessage(
    int index, {
    String? content,
    Map<String, dynamic>? metadata,
  }) {
    final msg = _runner.history[index];
    _runner.history[index] = msg.copyWith(
      content: content ?? msg.content,
      metadata: metadata ?? msg.metadata,
    );
  }

  @override
  void addUserMessage(Message message) {
    _runner.history.add(message);
  }

  @override
  void rollbackAddedUserMessages(int count) {
    if (count <= 0 || count > _runner.history.length) return;
    _runner.history.removeRange(
      _runner.history.length - count,
      _runner.history.length,
    );
  }

  @override
  int lastAssistantIndex() {
    return _runner.history.lastIndexWhere(
      (message) => message.role == MessageRole.assistant,
    );
  }

  @override
  void saveHistory() => _runner._saveHistory();

  @override
  bool reservePendingSteer(steer_lib.PendingSteer steer) =>
      _runner._reservePendingSteer(steer);

  @override
  void markPendingSteerDelivered(steer_lib.PendingSteer steer) =>
      _runner._markPendingSteerDelivered(steer);

  @override
  void releasePendingSteerAfterDeliveryFailure(steer_lib.PendingSteer steer) =>
      _runner._releasePendingSteerAfterDeliveryFailure(steer);
}
