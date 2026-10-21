import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../core/models/message.dart';
import '../core/models/user_attachment.dart';
import '../core/models/tool_execution_result.dart';
import '../core/models/agent_response.dart';
import '../core/models/llm_usage_snapshot.dart';
import '../capabilities/registry/tools_registry.dart';
import '../capabilities/models/tool_schema.dart';
import '../capabilities/tools/memory_tool.dart';
import 'adapters/llm_adapter.dart';
import 'adapters/llm_request_options.dart';
import '../core/di.dart';
import '../core/config.dart';
import '../evolution/attachments/attachment_store.dart';
import '../evolution/session_manager.dart';
import '../evolution/db/persisted_runtime_state_repository.dart';
import '../evolution/models/pending_steer_record.dart';
import '../evolution/memory/file_memory_store.dart';
import '../plugins/plugin_manager.dart';
import '../core/models/tool_call.dart';
import '../core/utils/scrubber.dart';
import '../core/provider_runtime/runtime_recovery_exception.dart';
import '../core/provider_thinking/thinking_route_preference.dart';
import '../core/provider_thinking/thinking_route_preference_store.dart';
import '../core/provider_thinking/thinking_selection_resolver.dart';
import 'agent_context_assembler.dart';
import 'llm_request_dumper.dart';
import 'history_healer.dart';
import 'history_image_pruner.dart';
import 'metrics_tracker.dart';
import 'tool_concurrency_evaluator.dart';
import 'runtime/continuation_checkpoint_coordinator.dart';
import 'runtime/deferred_tool_result.dart';
import 'runtime/llm_route_snapshot.dart';
import 'runtime/response_continuation_coordinator.dart';
import 'runtime/steer_coordinator.dart' as steer_lib;
import 'runtime/tool_execution_coordinator.dart';
import 'runtime/run_cancellation_scope.dart';
import 'runtime/thinking_field_rejection.dart';
import '../core/provider_thinking/native_thinking_directive.dart';
import '../evolution/models/compaction_operation_record.dart';
import '../core/agent_runtime_service.dart';
import 'runtime/compaction_coordinator.dart';
import 'runtime/compaction_request_factory.dart';
import 'runtime/post_boundary_usage_reservation.dart';
import 'context/context.dart';
import 'runtime/turn_route_state.dart';
import '../core/provider_runtime/provider_instance_repository.dart';
import '../core/provider_runtime/route_capability_resolver.dart';
import 'adapters/models_dev_service.dart';
import 'runtime/runner_recovery_coordinator.dart';
import 'runtime/runner_compaction_orchestrator.dart';
import 'runtime/runner_resume_coordinator.dart';
import 'runtime/runner_admission_gate.dart';
import 'runtime/runner_context_projector.dart';
import 'runtime/runner_stream_coordinator.dart';

/// Legacy re-exports so existing imports of the steer constants from
/// `agent_runner.dart` continue to work without touching call sites.
export 'runtime/steer_coordinator.dart'
    show steerMarkerOpen, steerMarkerClose, steerChannelNote;
export 'runtime/runner_compaction_orchestrator.dart'
    show CompactionProviderSeed;

class PendingSteerDeliveryCommit {
  final List<Message> history;
  final List<PendingSteerRecord> records;

  const PendingSteerDeliveryCommit({
    required this.history,
    required this.records,
  });
}

class AgentRunner
    implements
        RunnerRecoveryHost,
        RunnerCompactionHost,
        RunnerResumeHost,
        RunnerContextHost,
        RunnerStreamHost {
  static final Logger _logger = Logger('AgentRunner');

  final LLMAdapter adapter;
  @override
  final ToolsRegistry registry;
  @override
  final SessionManager sessionManager;
  @override
  final PluginManager pluginManager;
  final DeferredToolResultResolver? _deferredToolResultResolver;
  final AttachmentStore? _attachmentStore;
  @override
  late final FileMemoryStore memoryStore;
  @override
  late final String sessionId;

  late final RunnerAdmissionGate _admissionGate = RunnerAdmissionGate();
  late final RunnerRecoveryCoordinator _recoveryCoordinator =
      RunnerRecoveryCoordinator(this, logger: _logger);
  late final RunnerCompactionOrchestrator _compactionOrchestrator =
      RunnerCompactionOrchestrator(this);
  late final RunnerResumeCoordinator _resumeCoordinator =
      RunnerResumeCoordinator(this);
  late final RunnerContextProjector _contextProjector = RunnerContextProjector(
    this,
    logger: _logger,
  );
  late final RunnerStreamCoordinator _streamCoordinator =
      RunnerStreamCoordinator(this, logger: _logger);

  @override
  List<Message> history = [];
  int _currentTurnStartIndex = 0;
  bool _allowManualAmbiguousToolRecovery = false;

  bool get stopRequested => _admissionGate.stopRequested;
  bool get providerRequestInFlight => _admissionGate.providerRequestInFlight;

  void markProviderResponseTerminalCommitted() {
    _admissionGate.markProviderResponseTerminalCommitted(
      checkpointCoordinator: _checkpointCoordinator,
      checkpointCtx: _checkpointCtx,
    );
  }

  void _settleProviderRequest() {
    _admissionGate.settleProviderRequest(
      checkpointCoordinator: _checkpointCoordinator,
      checkpointCtx: _checkpointCtx,
    );
  }

  /// Allows one explicit user recovery command to continue past an ambiguous
  /// non-idempotent tool without replaying its side effect. Automatic startup
  /// recovery never enables this policy.
  void allowManualAmbiguousToolRecovery() {
    _allowManualAmbiguousToolRecovery = true;
  }

  void beginControlledRestartDrain() =>
      _admissionGate.beginControlledRestartDrain();

  void cancelControlledRestartDrain() =>
      _admissionGate.cancelControlledRestartDrain();

  /// Atomically claims permission to invoke the provider after any restart
  /// drain has been released.
  Future<bool> _claimProviderRequestAfterRestartDrain() =>
      _admissionGate.claimProviderRequestAfterRestartDrain(
        persistInFlightCheckpoint: () => _checkpointCoordinator.saveCheckpoint(
          ctx: _checkpointCtx,
          checkpointKind: ContinuationCheckpointCoordinator
              .checkpointKindModelRequestInFlight,
          resumeHistoryLength: history.length,
        ),
      );

  static const checkpointKindInitialModelRequest =
      ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest;
  static const checkpointKindAfterToolResult =
      ContinuationCheckpointCoordinator.checkpointKindAfterToolResult;

  void requestStop() => _admissionGate.requestStop();

  void attachCancellationScope(RunCancellationScope scope) =>
      _admissionGate.attachCancellationScope(scope);

  void detachCancellationScope(RunCancellationScope scope) =>
      _admissionGate.detachCancellationScope(scope);

  bool get canPublishRunEvents => _admissionGate.canPublishRunEvents;

  @override
  RunCancellationScope? get cancellationScope =>
      _admissionGate.cancellationScope;

  /// Three-tier context assembler responsible for building the single system
  /// message sent to the LLM on every turn.
  ///
  /// Tiers (stable → context → volatile) are ordered so the longest,
  /// least-changing prefix remains byte-stable across turns, maximizing
  /// LLM prefix-cache reuse. See [AgentContextAssembler] for the full contract.
  @override
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
  @override
  String? currentModelStepId;
  String? _authoritativeRunId;
  String? _authoritativeWorkItemId;
  int? _authoritativeGeneration;
  LLMRouteSnapshot? _lastSuccessfulLlmRoute;
  void Function(PendingSteerRecord record)? _onPendingSteerChanged;
  PendingSteerDeliveryCommit Function(
    List<Message> history,
    List<steer_lib.PendingSteerPlacement> placements,
  )?
  _onCommitPendingSteerDelivery;
  FutureOr<void> Function(Message message)? _onRootMessageCommitted;

  /// Exact adapter/provider/model route that completed the latest LLM request
  /// in the current authoritative turn.
  LLMRouteSnapshot? get lastSuccessfulLlmRoute => _lastSuccessfulLlmRoute;

  RouteCapabilityProfile? _turnCapabilityProfile;

  /// True between turn admission and the end of that turn's entry point.
  /// Only an admitted turn may move [_turnCapabilityProfile] to a new route.
  bool _turnCapabilityProfileAdmitted = false;

  static bool _profileMatchesRoute(
    RouteCapabilityProfile? profile,
    String? providerInstanceId,
    String? modelId,
  ) =>
      profile != null &&
      providerInstanceId != null &&
      modelId != null &&
      profile.providerInstanceId.trim() == providerInstanceId.trim() &&
      profile.modelId.trim() == modelId.trim();

  /// Completes once the most recently cancelled turn stream has unwound.
  @visibleForTesting
  Future<void> get debugDetachedTurnStreamUnwind =>
      _streamCoordinator.detachedTurnStreamUnwind;

  @visibleForTesting
  RouteCapabilityProfile? get debugTurnCapabilityProfile =>
      _turnCapabilityProfile;

  RouteCapabilityResolver get _capabilityResolver =>
      getIt.isRegistered<RouteCapabilityResolver>()
      ? getIt<RouteCapabilityResolver>()
      : RouteCapabilityResolver(
          instances: getIt.isRegistered<ProviderInstanceRepository>()
              ? getIt<ProviderInstanceRepository>()
              : null,
          config: getIt.isRegistered<Config>() ? getIt<Config>() : null,
          modelsDevService: getIt.isRegistered<ModelsDevService>()
              ? getIt<ModelsDevService>()
              : null,
          thinkingResolver: getIt.isRegistered<ThinkingSelectionResolver>()
              ? getIt<ThinkingSelectionResolver>()
              : null,
        );

  Future<void> _admitTurnCapabilityProfile() async {
    _turnCapabilityProfileAdmitted = true;
    final routing = _turnRoute.resolveTurnRouting();
    final pId = routing.providerId;
    final mId = routing.model ?? _turnRoute.effectiveModel;
    if (pId != null && mId != null) {
      _turnCapabilityProfile = await _capabilityResolver.resolve(
        providerInstanceId: pId,
        modelId: mId,
        thinkingMode: _turnRoute.effectiveThinkingMode,
      );
      if (_turnCapabilityProfile?.thinkingSelectionId != null &&
          getIt.isRegistered<ThinkingRoutePreferenceStore>()) {
        getIt<ThinkingRoutePreferenceStore>().savePreference(
          sessionId: sessionId,
          preference: ThinkingRoutePreference(
            selectionId: _turnCapabilityProfile!.thinkingSelectionId!,
            providerInstanceId: pId.trim(),
            modelId: mId.trim(),
            capabilityRevision:
                _turnCapabilityProfile!
                    .thinkingDescriptor
                    ?.capabilityRevision ??
                'unknown',
          ),
        );
      }
    } else {
      _turnCapabilityProfile = null;
    }
  }

  @override
  Future<void> admitTurnCapabilityProfile() => _admitTurnCapabilityProfile();

  @visibleForTesting
  void debugSetConfirmedInputUsageBaseline(
    ConfirmedInputUsageBaseline? baseline,
  ) {
    _compactionOrchestrator.setConfirmedInputUsageBaseline(baseline);
  }

  @visibleForTesting
  RequestPressureSnapshot? get debugLastPreflightPressure =>
      _compactionOrchestrator.lastPreflightPressure;

  @visibleForTesting
  ConfirmedInputUsageBaseline? get debugConfirmedInputUsageBaseline =>
      _compactionOrchestrator.confirmedInputUsageBaseline;

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
    _compactionOrchestrator.resetRunFlags();
    _turnRoute.setTurnRunId(runId);
  }

  void configureRootMessageCommitted(
    FutureOr<void> Function(Message message)? onCommitted,
  ) {
    _onRootMessageCommitted = onCommitted;
  }

  void configurePendingSteerLifecycle({
    required String runId,
    required int generation,
    void Function(PendingSteerRecord record)? onChanged,
    PendingSteerDeliveryCommit Function(
      List<Message> history,
      List<steer_lib.PendingSteerPlacement> placements,
    )?
    onCommitDelivery,
  }) {
    _authoritativeRunId = runId;
    _authoritativeGeneration = generation;
    _onPendingSteerChanged = onChanged;
    _onCommitPendingSteerDelivery = onCommitDelivery;
  }

  void endAuthoritativeRun(String? runId) {
    if (runId == null || runId.isEmpty) return;
    if (_authoritativeRunId != runId) return;
    _authoritativeRunId = null;
    _authoritativeWorkItemId = null;
    _authoritativeGeneration = null;
    _admissionGate.clearCancellationScope();
    _onPendingSteerChanged = null;
    _onCommitPendingSteerDelivery = null;
    _onRootMessageCommitted = null;
    _activeProviderInstanceId = null;
    _turnRoute.setTurnRunId(null);
  }

  String? _activeProviderInstanceId;

  String? get activeProviderInstanceId =>
      _compactionOrchestrator
          .confirmedInputUsageBaseline
          ?.routeSignature
          .providerInstanceId ??
      _compactionOrchestrator
          .pendingInputUsageBaseline
          ?.routeSignature
          .providerInstanceId ??
      _activeProviderInstanceId ??
      _turnRoute.activeProviderInstanceId;

  set activeProviderInstanceId(String? value) {
    _activeProviderInstanceId = value;
  }

  @override
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
  @override
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
      if (activeProviderInstanceId != null || activeProvider != null)
        'provider_instance_id': activeProviderInstanceId ?? activeProvider,
      if (_authoritativeRunId != null) 'run_id': _authoritativeRunId,
      if (currentModelStepId != null) 'model_step_id': currentModelStepId,
      // Binds this confirmed usage to the complete ordered wire material and
      // route that produced it, so a restore can prove compatibility against
      // adapter remeasurement rather than trusting unproven legacy rows.
      if (_compactionOrchestrator.confirmedWireProof != null)
        'wire_proof': _compactionOrchestrator.confirmedWireProof,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  String? get activeModelDisplay => _metricsTracker?.formatActiveModelDisplay();

  void _updateMetrics(AgentResponse response) {
    _metricsTracker?.updateMetrics(response);
    _compactionOrchestrator.confirmInputUsageBaseline(
      response.usage,
      finishReason: response.finishReason,
    );
  }

  Future<void> _stageInputUsageBaseline({
    required List<Message> requestMessages,
    required List<Map<String, dynamic>> toolSchemas,
    required String? providerId,
    required String? modelId,
  }) => _compactionOrchestrator.stageInputUsageBaseline(
    requestMessages: requestMessages,
    toolSchemas: toolSchemas,
    providerId: providerId,
    modelId: modelId,
  );

  AgentRunner(
    this.adapter,
    this.registry,
    this.sessionManager, {
    PluginManager? pluginManager,
    String? existingSessionId,
    DeferredToolResultResolver? deferredToolResultResolver,
    AttachmentStore? attachmentStore,
  }) : pluginManager = pluginManager ?? PluginManager(),
       _deferredToolResultResolver = deferredToolResultResolver,
       _attachmentStore = attachmentStore {
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

  void _pruneProcessedHistoryImages() {
    final result = HistoryImagePruner.prune(history);
    if (!result.changed) return;
    history = List<Message>.of(result.messages);
    _saveHistory();
  }

  @override
  AttachmentStore? get attachmentStore =>
      _attachmentStore ??
      (getIt.isRegistered<AttachmentStore>() ? getIt<AttachmentStore>() : null);

  @override
  bool get supportsImageInput =>
      _turnCapabilityProfile?.imageSupport == RouteImageSupport.supported;

  @override
  void pruneProcessedHistoryImages() => _pruneProcessedHistoryImages();

  void _reloadPersistedHistory() {
    final session = sessionManager.getSession(sessionId);
    if (session != null) {
      history = session.messages.toList();
    }
  }

  int _appendOrReuseUserMessage(Message userMessage, String? requestId) {
    final existingIndex = _persistedUserMessageIndex(requestId);
    if (existingIndex != -1) return existingIndex;
    history.add(userMessage);
    return history.length - 1;
  }

  int _persistedUserMessageIndex(String? requestId) {
    if (requestId == null || requestId.isEmpty || history.isEmpty) return -1;
    for (var index = history.length - 1; index >= 0; index--) {
      final message = history[index];
      if (message.role == MessageRole.user &&
          message.metadata?['request_id']?.toString() == requestId) {
        return index;
      }
    }
    return -1;
  }

  /// Commits one root user input before any live event exposes it to clients.
  /// Re-entry with the same request id reuses the durable row without notifying
  /// plugins or mutating history a second time.
  List<UserAttachment> _pendingUserAttachments = const [];

  void configureUserAttachments(List<UserAttachment> attachments) {
    _pendingUserAttachments = List<UserAttachment>.unmodifiable(attachments);
  }

  @override
  Future<Message> commitUserMessage(
    String? userContent, {
    String? requestId,
    DateTime? receivedAt,
  }) async {
    final attachments = _pendingUserAttachments;
    _pendingUserAttachments = const [];
    _reloadPersistedHistory();
    var index = _persistedUserMessageIndex(requestId);
    if (index == -1) {
      final candidate = Message(
        role: MessageRole.user,
        content: userContent ?? '',
        attachments: attachments,
        metadata: {
          if (requestId != null && requestId.isNotEmpty)
            'request_id': requestId,
          'received_at': (receivedAt ?? DateTime.now())
              .toUtc()
              .toIso8601String(),
        },
      );
      if (attachments.isNotEmpty) {
        if (requestId == null || requestId.isEmpty) {
          throw StateError('Attachment admission requires a request identity.');
        }
        index = _appendOrReuseUserMessage(candidate, requestId);
        final attachmentStore = getIt<AttachmentStore>();
        history = attachmentStore.claimAdmissionAndPersist(
          sessionId: sessionId,
          admissionId: requestId,
          attachmentIds: attachments
              .map((attachment) => attachment.id)
              .toList(),
          persist: (transaction, admitted) {
            history[index] = history[index].copyWith(attachments: admitted);
            return sessionManager.saveSessionHistoryInTransaction(
              sessionId,
              history,
              transaction,
            );
          },
        );
        _reloadPersistedHistory();
        index = _persistedUserMessageIndex(requestId);
        if (index >= 0 && index < history.length) {
          await pluginManager.notifyMessage(history[index]);
        }
      } else {
        final commit = sessionManager.appendRootUserMessage(
          sessionId,
          candidate,
        );
        if (commit.inserted) {
          history.add(commit.message);
          index = history.length - 1;
          await pluginManager.notifyMessage(commit.message);
        } else {
          _reloadPersistedHistory();
          index = _persistedUserMessageIndex(requestId);
        }
      }
    }
    if (index != -1 &&
        attachments.isNotEmpty &&
        history[index].attachments.isEmpty) {
      history[index] = history[index].copyWith(attachments: attachments);
      sessionManager.saveSessionHistory(sessionId, history);
    }
    if (index < 0 || index >= history.length) {
      throw StateError(
        'Committed user message is missing from session history.',
      );
    }
    _currentTurnStartIndex = index;
    return history[index];
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
    final activeToolCallIds =
        getIt.isRegistered<PersistedRuntimeStateRepository>()
        ? getIt<PersistedRuntimeStateRepository>()
              .findAllWorkItems(sessionId)
              .where(
                (item) =>
                    item.state != SessionWorkState.completed &&
                    item.state != SessionWorkState.cancelled,
              )
              .expand(
                (item) => List<String>.from(
                  item.continuationMetadata['currently_executing_tools']
                          as List? ??
                      const [],
                ),
              )
              .toSet()
        : const <String>{};
    HistoryHealer.healHistory(
      history: history,
      sessionManager: sessionManager,
      sessionId: sessionId,
      suspendedToolCallIds: suspendedToolCallIds,
      deferredToolCallIds: deferredToolCallIds,
      activeToolCallIds: activeToolCallIds,
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
    _compactionOrchestrator.confirmedWireProof = null;
  }

  @visibleForTesting
  Future<void> executeToolCalls(
    List<ToolCall> toolCalls, {
    required bool parallel,
    ToolEventCallback? onToolEvent,
  }) => _toolExecutionCoordinator.executeToolCalls(
    toolCalls,
    parallel: parallel,
    callbacks: _RunnerToolCallbacks(this),
    ctx: _checkpointCtx,
    cancellationScope: cancellationScope,
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
    _admissionGate.resetStopRequested();
    memoryStore.resetConsolidationFailures();
    _metricsTracker = MetricsTracker(startTime: receivedAt);
    final effectiveRequestId = requestId ?? _turnRoute.turnRequestId;
    _turnRoute.configureTurn(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      requestId: effectiveRequestId,
    );
    await _admitTurnCapabilityProfile();
    try {
      _turnRoute.applyTurnSwitchIfNeeded();
      await commitUserMessage(
        userContent,
        requestId: effectiveRequestId,
        receivedAt: receivedAt,
      );
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
      _turnCapabilityProfileAdmitted = false;
    }
  }

  @override
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
    final routing = _turnRoute.resolveTurnRouting();
    final pId = routing.providerId;
    final mId = routing.model ?? _turnRoute.effectiveModel;
    if (pId != null && mId != null) {
      _turnCapabilityProfile = _capabilityResolver.resolveSync(
        providerInstanceId: pId,
        modelId: mId,
        thinkingMode: _turnRoute.effectiveThinkingMode,
      );
    } else {
      _turnCapabilityProfile = null;
    }
  }

  final SessionThinkingFieldSuppression _localThinkingSuppression =
      SessionThinkingFieldSuppression();

  SessionThinkingFieldSuppression get _thinkingSuppression =>
      getIt.isRegistered<SessionThinkingFieldSuppression>()
      ? getIt<SessionThinkingFieldSuppression>()
      : _localThinkingSuppression;

  /// When [error] is a 400 that clearly rejects the thinking field the request
  /// actually carried, records that exact selection value on this route+model
  /// as rejected for the rest of this session and reports that the same
  /// request may be retried once without the field. Other selection values on
  /// the same route stay unaffected.
  bool _retryWithoutRejectedThinkingField(Object error, String? provider) {
    if (!ThinkingFieldRejection.matches(error)) return false;
    final options = _requestOptionsForTurn(provider);
    final sent = options.thinkingDirective;
    if (sent == null || sent is UseProviderDefault) return false;
    final routing = _turnRoute.resolveTurnRouting();
    final selection = options.thinkingMode;
    _thinkingSuppression.suppress(
      sessionId,
      provider ?? routing.providerId,
      routing.model ?? _turnRoute.effectiveModel,
      selection,
    );
    // The retry must not pass as the user's choice: record that the requested
    // level was not applied and the provider default answered instead.
    _logger.warning(
      'Provider rejected thinking selection "${selection ?? '?'}" for session '
      '$sessionId; it was not applied. Retrying once with the provider '
      'default (no thinking field).',
    );
    return true;
  }

  LLMRequestOptions _requestOptionsForTurn(
    String? providerInstanceId, {
    String? requestId,
  }) {
    final routing = _turnRoute.resolveTurnRouting();
    final pId = providerInstanceId ?? routing.providerId;
    final mId = routing.model ?? _turnRoute.effectiveModel;

    final existingProfile = _turnCapabilityProfile;
    final matchesRoute = _profileMatchesRoute(existingProfile, pId, mId);

    final profile = matchesRoute
        ? existingProfile
        : (pId != null && mId != null
              ? _capabilityResolver.resolveSync(
                  providerInstanceId: pId,
                  modelId: mId,
                  thinkingMode: _turnRoute.effectiveThinkingMode,
                )
              : null);
    if (_turnCapabilityProfileAdmitted &&
        existingProfile != null &&
        !matchesRoute &&
        profile != null) {
      _turnCapabilityProfile = profile;
    }

    // A selection value whose provider rejected the thinking field earlier in
    // this session is dispatched with the provider default (no thinking
    // field); other values on the same route are still sent.
    final selectionId = profile != null
        ? profile.thinkingSelectionId
        : _turnRoute.effectiveThinkingMode;
    final thinkingSuppressed = _thinkingSuppression.isSuppressed(
      sessionId,
      pId,
      mId,
      selectionId,
    );
    final thinkingMode = thinkingSuppressed ? null : selectionId;

    return LLMRequestOptions(
      sessionId: sessionId,
      requestId: requestId ?? _turnRoute.turnRequestId,
      providerInstanceId: providerInstanceId,
      thinkingMode: thinkingMode,
      thinkingDirective: thinkingSuppressed
          ? const UseProviderDefault()
          : profile?.thinkingDirective,
      cancellationScope: cancellationScope,
      routeCapabilitySnapshot: profile?.rawOverride,
      routeCapabilityProfile: profile,
      attachmentStore:
          _attachmentStore ??
          (getIt.isRegistered<AttachmentStore>()
              ? getIt<AttachmentStore>()
              : null),
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

  void _commitPendingSteerDelivery(
    List<steer_lib.PendingSteerPlacement> placements,
  ) {
    final commit = _onCommitPendingSteerDelivery;
    if (commit == null) {
      _saveHistory();
      for (final placement in placements) {
        _markPendingSteerDeliveredFallback(placement.steer);
      }
      return;
    }
    final result = commit(List<Message>.unmodifiable(history), placements);
    history = List<Message>.from(result.history);
    for (final record in result.records) {
      _onPendingSteerChanged?.call(record);
    }
  }

  void _markPendingSteerDeliveredFallback(steer_lib.PendingSteer steer) {
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

  void _clearResumingOnProviderProgress() =>
      _recoveryCoordinator.clearResumingOnProviderProgress();

  Future<bool> _handleRuntimeFailure(
    Object error, {
    required String? providerInstanceId,
    required String? modelId,
    required int attempt,
    required bool streamStarted,
    required Set<String> failedProviderInstanceIds,
    List<Message>? failedProviderProjection,
    List<ToolSchema>? failedProviderTools,
  }) => _recoveryCoordinator.handleRuntimeFailure(
    error,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
    attempt: attempt,
    streamStarted: streamStarted,
    failedProviderInstanceIds: failedProviderInstanceIds,
    failedProviderProjection: failedProviderProjection,
    failedProviderTools: failedProviderTools,
  );

  List<Message>? _recoverRejectedProviderState(
    Object error,
    ResponseContinuationCoordinator continuation,
    List<Message> effectiveHistory,
  ) => _recoveryCoordinator.recoverRejectedProviderState(
    error,
    continuation,
    effectiveHistory,
  );

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

    var effectiveHistory = await _prepareProviderHistory(
      runtimeSystemPrompt: runtimeSystemPrompt,
    );

    final routing = _turnRoute.resolveTurnRouting();
    var model = routing.model;
    var provider = routing.providerId;
    var baseUrl = routing.baseUrl;
    var apiKey = routing.apiKey;
    _turnRoute.cacheResolvedRoute(_turnRoute.adapterForTurn(), model);

    if (provider != null && model != null) {
      activeProvider = provider;
      activeProviderInstanceId = provider;
      activeModel = model;
    }

    AgentResponse response;
    final attemptsByProviderInstanceId = <String, int>{};
    final failedProviderInstanceIds = <String>{};
    var thinkingFieldRetried = false;
    DispatchedReservation? dispatchedReservation;
    while (true) {
      final turnRequestId = _turnRoute.turnRequestId ?? '';
      final stepRequestId = _compactionOrchestrator.stepRequestId();
      final providerAttempt = provider == null
          ? 0
          : attemptsByProviderInstanceId[provider] ?? 0;
      final attemptRequestId = providerAttempt == 0
          ? (turnRequestId.isNotEmpty ? turnRequestId : stepRequestId)
          : (turnRequestId.isNotEmpty
                ? '$turnRequestId:retry_$providerAttempt'
                : '$stepRequestId:retry_$providerAttempt');
      final activeBoundary = _contextProjector.activeProjectionBoundary;
      final priorReservation = dispatchedReservation;
      if (priorReservation != null &&
          (activeBoundary == null ||
              activeBoundary.compactionId != priorReservation.compactionId)) {
        _compactionOrchestrator.finalizeReservation(
          priorReservation,
          'no_provider_usage',
        );
        dispatchedReservation = null;
      }

      void finalizeMissing([String reason = 'no_provider_usage']) {
        final currentReservation = dispatchedReservation;
        if (currentReservation != null) {
          _compactionOrchestrator.finalizeReservation(
            currentReservation,
            reason,
          );
          dispatchedReservation = null;
        } else {
          _compactionOrchestrator.finalizePostBoundaryMissingUsage(
            activeBoundary: activeBoundary,
            stepRequestId: stepRequestId,
            missingReason: reason,
            routeSignature: _compactionOrchestrator
                .pendingInputUsageBaseline
                ?.routeSignature,
          );
        }
      }

      try {
        final route = _turnRoute.routeForTurn();
        if (!await _claimProviderRequestAfterRestartDrain()) {
          finalizeMissing('no_provider_usage');
          return Message(role: MessageRole.assistant);
        }
        _logger.info('🧠 [Agent] Thinking...');

        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpRequest(
            sessionId: sessionId,
            history: effectiveHistory,
            tools: tools,
            model: model,
            provider: provider,
            baseUrl: baseUrl,
            apiKey: apiKey,
            requestId: attemptRequestId,
          );
        }
        await _stageInputUsageBaseline(
          requestMessages: effectiveHistory,
          toolSchemas: tools.map((tool) => tool.toJson()).toList(),
          providerId: provider,
          modelId: model,
        );
        final reserved = _compactionOrchestrator.reservePostBoundaryDispatch(
          activeBoundary: activeBoundary,
          stepRequestId: stepRequestId,
        );
        if (reserved != null) {
          dispatchedReservation = reserved;
        }
        try {
          response = await route.adapter.generateResponse(
            effectiveHistory,
            tools: tools,
            modelOverride: route.modelOverride,
            options: _requestOptionsForTurn(
              provider,
              requestId: attemptRequestId,
            ),
          );
        } finally {
          if (_admissionGate.stopRequested) {
            _admissionGate.providerRequestInFlight = false;
          }
        }
        _lastSuccessfulLlmRoute = LLMRouteSnapshot(
          adapter: RunnerStreamCoordinator.providerAdapterForBackground(
            route.adapter,
          ),
          providerInstanceId: provider,
          modelOverride: route.modelOverride,
        );
        _clearResumingOnProviderProgress();
        break;
      } catch (e) {
        _settleProviderRequest();
        _turnRoute.invalidateResolvedRoute();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.recordError(e, requestId: attemptRequestId);
        }
        if (!thinkingFieldRetried &&
            _retryWithoutRejectedThinkingField(e, provider)) {
          // Exactly one retry of the same request without the thinking field.
          thinkingFieldRetried = true;
          if (provider != null) {
            attemptsByProviderInstanceId[provider] =
                (attemptsByProviderInstanceId[provider] ?? 0) + 1;
          }
          continue;
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
        final previousProvider = provider;
        final previousModel = model;
        bool handled = false;
        try {
          handled = await _handleRuntimeFailure(
            e,
            providerInstanceId: provider,
            modelId: model,
            attempt: providerAttempt,
            streamStarted: false,
            failedProviderInstanceIds: failedProviderInstanceIds,
            failedProviderProjection: effectiveHistory,
            failedProviderTools: tools,
          );
        } catch (failure) {
          finalizeMissing('no_provider_usage');
          rethrow;
        }
        if (!handled) {
          finalizeMissing('no_provider_usage');
          rethrow;
        }
        if (provider != null) {
          attemptsByProviderInstanceId[provider] = providerAttempt + 1;
        }
        final refreshedRouting = _turnRoute.resolveTurnRouting();
        final routeChanged =
            refreshedRouting.providerId != previousProvider ||
            refreshedRouting.model != previousModel;
        if (routeChanged) {
          finalizeMissing('route_failover');
        }
        try {
          effectiveHistory = await _prepareProviderHistory(
            runtimeSystemPrompt: runtimeSystemPrompt,
          );
        } catch (prepError) {
          finalizeMissing('no_provider_usage');
          rethrow;
        }
        model = refreshedRouting.model;
        provider = refreshedRouting.providerId;
        baseUrl = refreshedRouting.baseUrl;
        apiKey = refreshedRouting.apiKey;
      }
    }
    _turnRoute.invalidateResolvedRoute();
    _updateMetrics(response);
    final responseUsage = response.usage;
    final snapshot = responseUsage != null
        ? LlmUsageSnapshot.fromProviderUsage(responseUsage)
        : null;
    if (snapshot?.inputTokens == null) {
      final reason = response.usage == null
          ? 'no_provider_usage'
          : 'missing_input_tokens';
      final remainingReservation = dispatchedReservation;
      if (remainingReservation != null) {
        _compactionOrchestrator.finalizeReservation(
          remainingReservation,
          reason,
        );
        dispatchedReservation = null;
      } else {
        final activeBoundary = _contextProjector.activeProjectionBoundary;
        final pending = _compactionOrchestrator.pendingInputUsageBaseline;
        if (activeBoundary != null &&
            pending?.routeSignature != null &&
            getIt.isRegistered<CompactionCoordinator>()) {
          final turnRequestId = _turnRoute.turnRequestId ?? '';
          final stepRequestId =
              currentModelStepId != null && currentModelStepId!.isNotEmpty
              ? '$turnRequestId:$currentModelStepId'
              : turnRequestId;
          _compactionOrchestrator.finalizePostBoundaryMissingUsage(
            activeBoundary: activeBoundary,
            stepRequestId: stepRequestId,
            missingReason: reason,
            routeSignature: pending!.routeSignature,
          );
        }
      }
    }
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

    if (RunnerStreamCoordinator.hasPersistableAssistantState(responseMessage)) {
      history.add(responseMessage);
      await pluginManager.notifyMessage(responseMessage);
      await pluginManager.runPostExecution(responseMessage);
      _saveHistory();
      _pruneProcessedHistoryImages();
    }
    if (responseMessage.toolCalls?.isNotEmpty ?? false) {
      final toolCalls = responseMessage.toolCalls!;
      _settleProviderRequest();
      await _toolExecutionCoordinator.executeToolCalls(
        toolCalls,
        parallel: shouldParallelizeToolBatch(toolCalls),
        callbacks: _RunnerToolCallbacks(this),
        ctx: _checkpointCtx,
        cancellationScope: cancellationScope,
      );
      return await _getNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        continuation: continuation,
      );
    }

    if (_steerCoordinator.hasPendingSteers) {
      _settleProviderRequest();
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
      _settleProviderRequest();
      return await _getNextResponse(
        runtimeSystemPrompt: runtimeSystemPrompt,
        continuation: continuation,
      );
    }

    if (_authoritativeRunId == null) {
      markProviderResponseTerminalCommitted();
    }
    _logger.info('🏁 [Agent] Final answer committed');
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
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) => _streamCoordinator.streamMessage(
    userContent,
    requestId: requestId,
    runtimeSystemPrompt: runtimeSystemPrompt,
    providerId: providerId,
    model: model,
    thinkingMode: thinkingMode,
    receivedAt: receivedAt,
    onToolEvent: onToolEvent,
    onSteerContinuation: onSteerContinuation,
    onThoughtDelta: onThoughtDelta,
    onReasoningDelta: onReasoningDelta,
  );

  Stream<String> resumeStream({
    String? requestId,
    String? runtimeSystemPrompt,
    String? providerId,
    String? model,
    String? thinkingMode,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) => _streamCoordinator.resumeStream(
    requestId: requestId,
    runtimeSystemPrompt: runtimeSystemPrompt,
    providerId: providerId,
    model: model,
    thinkingMode: thinkingMode,
    onToolEvent: onToolEvent,
    onSteerContinuation: onSteerContinuation,
    onThoughtDelta: onThoughtDelta,
    onReasoningDelta: onReasoningDelta,
  );

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

  Stream<String> resumeAfterToolCall({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    String? runtimeSystemPrompt,
    String? forcedOutput,
    bool forcedIsError = false,
    ToolResultErrorCode? forcedErrorCode,
    ToolEventCallback? onToolEvent,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) => _streamCoordinator.resumeAfterToolCall(
    toolCallId: toolCallId,
    toolName: toolName,
    arguments: arguments,
    runtimeSystemPrompt: runtimeSystemPrompt,
    forcedOutput: forcedOutput,
    forcedIsError: forcedIsError,
      forcedErrorCode: forcedErrorCode,
    onToolEvent: onToolEvent,
    onThoughtDelta: onThoughtDelta,
    onReasoningDelta: onReasoningDelta,
  );

  List<Message> _buildEffectiveHistory({String? runtimeSystemPrompt}) =>
      _contextProjector.buildEffectiveHistory(
        runtimeSystemPrompt: runtimeSystemPrompt,
      );

  Future<List<Message>> _prepareProviderHistory({
    String? runtimeSystemPrompt,
  }) => _contextProjector.prepareProviderHistory(
    runtimeSystemPrompt: runtimeSystemPrompt,
  );

  /// Test-facing projection hook kept on the runner boundary; the context
  /// projector owns the implementation the live provider path uses.
  @visibleForTesting
  static Future<List<Message>> projectUserAttachmentsForProvider({
    required AttachmentStore store,
    required String sessionId,
    required List<Message> messages,
    bool supportsImageInput = false,
  }) => RunnerContextProjector.projectUserAttachmentsForProvider(
    store: store,
    sessionId: sessionId,
    messages: messages,
    supportsImageInput: supportsImageInput,
  );

  Future<bool> _maybeRunPreflightCompaction({
    String? runtimeSystemPrompt,
    required List<Message> prospectiveHistory,
  }) => _compactionOrchestrator.maybeRunPreflightCompaction(
    runtimeSystemPrompt: runtimeSystemPrompt,
    prospectiveHistory: prospectiveHistory,
  );

  int _currentProjectionRevision() =>
      _compactionOrchestrator.currentProjectionRevision();

  void _refreshCanonicalHistoryAfterCompaction() =>
      _compactionOrchestrator.refreshCanonicalHistoryAfterCompaction();

  /// Test hook for Plan 53d preflight compaction verification.
  @visibleForTesting
  Future<List<Message>> debugPrepareProviderHistory({
    String? runtimeSystemPrompt,
  }) {
    return _prepareProviderHistory(runtimeSystemPrompt: runtimeSystemPrompt);
  }

  /// Test hook for Plan 53d request options resolution.
  @visibleForTesting
  LLMRequestOptions debugRequestOptionsForTurn([
    String? providerInstanceId,
    String? requestId,
  ]) {
    return _requestOptionsForTurn(providerInstanceId, requestId: requestId);
  }

  /// Builds the same idle provider payload used by an ordinary next request,
  /// without running preflight compaction or inventing a user turn.
  Future<CompactionProviderSeed> prepareCompactionProviderSeed({
    String? runtimeSystemPrompt,
  }) => _compactionOrchestrator.prepareCompactionProviderSeed(
    runtimeSystemPrompt: runtimeSystemPrompt,
  );

  @visibleForTesting
  void debugSaveCheckpointForTesting({
    required int resumeHistoryLength,
    required int turnStartIndex,
  }) {
    _currentTurnStartIndex = turnStartIndex;
    _checkpointCoordinator.saveCheckpoint(
      ctx: _checkpointCtx,
      checkpointKind:
          ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest,
      resumeHistoryLength: resumeHistoryLength,
    );
  }

  @visibleForTesting
  ResumeResult debugRestoreCheckpointForTesting() {
    final result = _checkpointCoordinator.restoreCheckpointForResume(
      currentHistoryLength: history.length,
    );
    if (result.resumeHistoryLength >= 0 &&
        history.length > result.resumeHistoryLength) {
      history = history.take(result.resumeHistoryLength).toList(growable: true);
    }
    if (result.savedTurnStartIndex != null) {
      _currentTurnStartIndex = result.savedTurnStartIndex!;
    }
    return result;
  }

  @visibleForTesting
  void debugRefreshAfterCompactionForTesting() {
    _refreshCanonicalHistoryAfterCompaction();
  }

  List<IndexedConversationMessage> _compactionTimelineForSession() =>
      _compactionOrchestrator.compactionTimelineForSession();

  LLMRequestOptions _compactionRequestOptions(
    String? providerInstanceId, {
    required String compactionId,
  }) {
    final base = _requestOptionsForTurn(providerInstanceId);
    final routing = _turnRoute.resolveTurnRouting();
    final route = getIt<AgentRuntimeService>().resolveSignature(
      providerId: routing.providerId,
      modelId: routing.model,
    );
    final uniqueCompactionId = compactionId.isEmpty
        ? const Uuid().v4()
        : '$compactionId:${const Uuid().v4()}';
    return CompactionRequestFactory.buildCompactionRequestOptions(
      sessionId: sessionId,
      compactionId: uniqueCompactionId,
      routeSignature: route,
      baseOptions: base,
      fallbackThinkingMode: _turnRoute.effectiveThinkingMode,
    );
  }

  @visibleForTesting
  Future<bool> debugTryOverflowCompactionRecovery({
    required Object error,
    required String? providerInstanceId,
    required String? modelId,
    bool streamStarted = false,
    int attempt = 0,
    List<Message>? failedProviderProjection,
    List<ToolSchema>? failedProviderTools,
  }) async {
    try {
      return await _handleRuntimeFailure(
        error,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        attempt: attempt,
        streamStarted: streamStarted,
        failedProviderInstanceIds: {},
        failedProviderProjection: failedProviderProjection,
        failedProviderTools: failedProviderTools,
      );
    } on RuntimeRecoveryRequired {
      return false;
    }
  }

  // --- RunnerRecoveryHost, RunnerCompactionHost, RunnerResumeHost ---

  @override
  String? get authoritativeRunId => _authoritativeRunId;

  @override
  String? get authoritativeWorkItemId => _authoritativeWorkItemId;

  @override
  int? get authoritativeGeneration => _authoritativeGeneration;

  @override
  TurnRouteState get turnRoute => _turnRoute;

  @override
  void saveHistory() => _saveHistory();

  @override
  String? latestPersistedMessageId() =>
      sessionManager.latestActiveMessageId(sessionId);

  @override
  String assembleSystemPrompt() => contextAssembler.assemble() ?? '';

  @override
  List<IndexedConversationMessage> compactionTimelineForSession() =>
      _compactionTimelineForSession();

  @override
  int currentProjectionRevision() => _currentProjectionRevision();

  @override
  LLMRequestOptions compactionRequestOptions(
    String? providerInstanceId, {
    required String compactionId,
  }) =>
      _compactionRequestOptions(providerInstanceId, compactionId: compactionId);

  @override
  void refreshCanonicalHistoryAfterCompaction() =>
      _refreshCanonicalHistoryAfterCompaction();

  @override
  bool claimOwnedAutomaticRetry() => _claimOwnedAutomaticRetry();

  @override
  void updateSessionProviderId(String candidateId) =>
      sessionManager.updateSessionProviderId(sessionId, candidateId);

  @override
  ContinuationCheckpointCoordinator get checkpointCoordinator =>
      _checkpointCoordinator;

  @override
  CheckpointContext get checkpointCtx => _checkpointCtx;

  @override
  void healHistory() => _healHistory();

  @override
  LLMRequestOptions requestOptionsForTurn(
    String? providerId, {
    String? requestId,
  }) => _requestOptionsForTurn(providerId, requestId: requestId);

  @override
  bool turnCapabilityProfileMatchesRoute(
    String? providerInstanceId,
    String? modelId,
  ) =>
      _profileMatchesRoute(_turnCapabilityProfile, providerInstanceId, modelId);

  @override
  void resolveTurnCapabilityProfile({
    required String providerInstanceId,
    required String modelId,
  }) {
    _turnCapabilityProfile = _capabilityResolver.resolveSync(
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      thinkingMode: _turnRoute.effectiveThinkingMode,
    );
  }

  @override
  void clearTurnCapabilityProfile() {
    _turnCapabilityProfile = null;
  }

  @override
  bool get autoCompactionBlockedForRun =>
      _compactionOrchestrator.autoCompactionBlockedForRun;

  @override
  void markCompactionFailure() =>
      _compactionOrchestrator.markCompactionFailure();

  @override
  List<Message> buildEffectiveHistory({String? runtimeSystemPrompt}) =>
      _buildEffectiveHistory(runtimeSystemPrompt: runtimeSystemPrompt);

  @override
  ToolExecutionCoordinator get toolExecutionCoordinator =>
      _toolExecutionCoordinator;

  @override
  ToolExecutionCallbacks get toolCallbacks => _RunnerToolCallbacks(this);

  @override
  int get currentTurnStartIndex => _currentTurnStartIndex;

  @override
  set currentTurnStartIndex(int value) => _currentTurnStartIndex = value;

  @override
  bool consumeManualAmbiguousToolRecovery() {
    final allowed = _allowManualAmbiguousToolRecovery;
    _allowManualAmbiguousToolRecovery = false;
    return allowed;
  }

  // --- RunnerContextHost & RunnerStreamHost ---

  @override
  RunnerAdmissionGate get admissionGate => _admissionGate;

  @override
  RunnerRecoveryCoordinator get recoveryCoordinator => _recoveryCoordinator;

  @override
  RunnerResumeCoordinator get resumeCoordinator => _resumeCoordinator;

  @override
  RunnerCompactionOrchestrator get compactionOrchestrator =>
      _compactionOrchestrator;

  @override
  CompactionOperationRecord? get activeProjectionBoundary =>
      _contextProjector.activeProjectionBoundary;

  @override
  void endTurnCapabilityAdmission() {
    _turnCapabilityProfileAdmitted = false;
  }

  @override
  bool retryWithoutRejectedThinkingField(Object error, String? provider) =>
      _retryWithoutRejectedThinkingField(error, provider);

  @override
  steer_lib.SteerCoordinator get steerCoordinator => _steerCoordinator;

  @override
  steer_lib.SteerCallbacks get steerCallbacks => _RunnerSteerCallbacks(this);

  @override
  FutureOr<void> Function(Message)? get onRootMessageCommitted =>
      _onRootMessageCommitted;

  @override
  void beginModelStep() => _beginModelStep();

  @override
  void updateMetrics(AgentResponse response) => _updateMetrics(response);

  @override
  void resetMetricsTracker(DateTime? receivedAt) {
    _metricsTracker = MetricsTracker(startTime: receivedAt);
  }

  @override
  void setActiveRoute(String? provider, String? model) {
    activeProvider = provider;
    activeProviderInstanceId = provider;
    activeModel = model;
  }

  @override
  void setLastSuccessfulLlmRoute(LLMRouteSnapshot snapshot) {
    _lastSuccessfulLlmRoute = snapshot;
  }

  @override
  Future<List<Message>> prepareProviderHistory({String? runtimeSystemPrompt}) =>
      _prepareProviderHistory(runtimeSystemPrompt: runtimeSystemPrompt);

  @override
  Future<bool> maybeRunPreflightCompaction({
    String? runtimeSystemPrompt,
    required List<Message> prospectiveHistory,
  }) => _maybeRunPreflightCompaction(
    runtimeSystemPrompt: runtimeSystemPrompt,
    prospectiveHistory: prospectiveHistory,
  );
}

/// Bridges [ToolExecutionCoordinator] history mutations back to the runner
/// so the coordinator never owns a history list.
class _RunnerToolCallbacks
    implements ToolExecutionCallbacks, TypedToolExecutionCallbacks {
  final AgentRunner _runner;

  _RunnerToolCallbacks(this._runner);

  @override
  Future<void> addToolMessage(
    ToolCall toolCall,
    String result, {
    required bool isError,
    DateTime? startedAt,
    DateTime? terminalAt,
    int? runtimeMs,
  }) => addTypedToolMessage(
    toolCall,
    ToolExecutionResult.text(
      result,
      isError: isError,
      errorCode: isError ? ToolResultErrorCode.executionFailed : null,
    ),
    startedAt: startedAt,
    terminalAt: terminalAt,
    runtimeMs: runtimeMs,
  );

  @override
  Future<void> addTypedToolMessage(
    ToolCall toolCall,
    ToolExecutionResult result, {
    DateTime? startedAt,
    DateTime? terminalAt,
    int? runtimeMs,
  }) async {
    final toolMessage = Message(
      role: MessageRole.tool,
      toolResult: result,
      toolCallId: toolCall.id,
      metadata: {
        if (_runner._authoritativeRunId != null)
          'run_id': _runner._authoritativeRunId,
        'tool_call_id': toolCall.id,
        if (_runner.currentModelStepId != null)
          'model_step_id': _runner.currentModelStepId,
        'is_error': result.isError,
        'started_at': ?startedAt?.toIso8601String(),
        'terminal_at': ?terminalAt?.toIso8601String(),
        'runtime_ms': ?runtimeMs,
      },
    );
    _runner.history.add(toolMessage);
    await _runner.pluginManager.notifyMessage(
      toolMessage.copyWith(clearToolResult: true),
    );
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

  @override
  RouteImageSupport currentImageSupport() =>
      _runner._turnCapabilityProfile?.imageSupport ?? RouteImageSupport.unknown;
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
    var updatedToolResult = msg.toolResult;
    var clearToolResult = false;
    if (content != null && updatedToolResult != null) {
      final previousText = updatedToolResult.displayText;
      if (content.startsWith(previousText)) {
        final suffix = content.substring(previousText.length);
        final blocks = updatedToolResult.blocks.toList();
        final lastTextIndex = blocks.lastIndexWhere(
          (block) => block is ToolTextBlock,
        );
        final previousBlock = blocks[lastTextIndex] as ToolTextBlock;
        blocks[lastTextIndex] = ToolTextBlock(
          text: '${previousBlock.text}$suffix',
        );
        updatedToolResult = ToolExecutionResult(
          blocks: blocks,
          isError: updatedToolResult.isError,
          errorCode: updatedToolResult.errorCode,
        );
      } else {
        clearToolResult = true;
      }
    }
    _runner.history[index] = msg.copyWith(
      content: content ?? msg.content,
      toolResult: clearToolResult ? null : updatedToolResult,
      clearToolResult: clearToolResult,
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
  void commitPendingSteerDelivery(
    List<steer_lib.PendingSteerPlacement> placements,
  ) => _runner._commitPendingSteerDelivery(placements);

  @override
  bool reservePendingSteer(steer_lib.PendingSteer steer) =>
      _runner._reservePendingSteer(steer);

  @override
  void releasePendingSteerAfterDeliveryFailure(steer_lib.PendingSteer steer) =>
      _runner._releasePendingSteerAfterDeliveryFailure(steer);
}
