import 'dart:async';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'session_intervention_coordinator.dart';
import 'session_messages_state.dart';
import 'session_workspace_coordinator.dart';

class SessionMessagesCubit extends Cubit<SessionMessagesState> {
  static const defaultThinkingMode = 'balanced';
  static final _logger = Logger('SessionMessagesCubit');
  final DeviceCubit agentCubit;
  final SessionCubit sessionCubit;
  final ConversationRepository conversationRepository;
  final ConversationCacheRepository? conversationCacheRepository;
  final IDevicePreferencesRepository preferencesRepository;
  final DeviceCapabilitiesStore? capabilitiesStore;
  final LocalToolRuntimeService? localToolRuntime;
  final WorkspaceToolRuntimeContext? workspaceRuntimeContext;
  late final SessionWorkspaceCoordinator _workspaceCoordinator;
  late final SessionInterventionCoordinator _interventionCoordinator;
  StreamSubscription? _agentStateSubscription;
  StreamSubscription<DeviceConversationCacheSnapshot>? _cacheSubscription;
  StreamSubscription? _sessionStateSubscription;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _queuedMessagesSubscription;
  StreamSubscription? _attentionSubscription;
  StreamSubscription<StopDraftRecovery>? _stopRecoverySubscription;
  DeviceConfig? _currentAgent;
  String? _selectedSessionId;
  final Map<String, String> _nextMessageModelByAgentId = {};
  final Map<String, String> _nextMessageThinkingByAgentId = {};

  /// The thinking value the user (or the selected conversation's own stored
  /// selection) chose, per device. It differs from
  /// [_nextMessageThinkingByAgentId] only while a route default is admitted
  /// for display and the next send: an admitted default is never a choice, so
  /// it never reaches this map, a draft or the device preference (Task 122).
  final Map<String, String> _explicitThinkingByAgentId = {};
  final Map<String, String> _nextMessageProviderByAgentId = {};
  final Map<String, String> _pendingRouteProviderBySessionId = {};
  final Map<String, String> _pendingRouteModelBySessionId = {};
  final Map<String, int> _confirmedRouteRevisionBySessionId = {};

  /// Sessions selected as an identity-only startup placeholder whose route
  /// context replacement was deferred until their authoritative summary.
  final Set<String> _deferredRouteContextSessionIds = {};
  final Set<String> _freshSessionIdsAwaitingFirstTurn = {};
  final Map<String, String> _requestedHistoryAnchors = {};
  int _requestGeneration = 0;
  Timer? _delayedLoadingTimer;

  SessionMessagesCubit({
    required this.agentCubit,
    required this.sessionCubit,
    required this.conversationRepository,
    this.conversationCacheRepository,
    required this.preferencesRepository,
    this.capabilitiesStore,
    this.localToolRuntime,
    this.workspaceRuntimeContext,
    WorkspaceSecurityClient? workspaceSecurityClient,
  }) : super(const SessionMessagesState()) {
    _workspaceCoordinator = SessionWorkspaceCoordinator(
      conversationRepository: conversationRepository,
      workspaceSecurityClient: workspaceSecurityClient,
      conversationCacheRepository: conversationCacheRepository,
      capabilitiesStore: capabilitiesStore,
      localToolRuntime: localToolRuntime,
      workspaceRuntimeContext: workspaceRuntimeContext,
      sessionCubit: sessionCubit,
      getCurrentAgent: () => _currentAgent,
      getSelectedSessionId: () => _selectedSessionId,
      getState: () => state,
      emit: emit,
      getIsClosed: () => isClosed,
    );
    _interventionCoordinator = SessionInterventionCoordinator(
      conversationRepository: conversationRepository,
      sessionCubit: sessionCubit,
      preferencesRepository: preferencesRepository,
      getCurrentAgent: () => _currentAgent,
      getState: () => state,
      emit: emit,
      getIsClosed: () => isClosed,
      setPendingRouteSelection: _setPendingRouteSelection,
      nextMessageProviderByAgentId: _nextMessageProviderByAgentId,
      nextMessageModelByAgentId: _nextMessageModelByAgentId,
      nextMessageThinkingByAgentId: _nextMessageThinkingByAgentId,
      selectedWorkspaceForAgent: _selectedWorkspaceForAgent,
    );
    _agentStateSubscription = agentCubit.stream.listen(_handleDeviceStateChange);
    _cacheSubscription = conversationCacheRepository?.snapshotStream.listen(_handleCacheSnapshot);
    _sessionStateSubscription = sessionCubit.stream.listen(_handleSessionStateChange);
    // Initial check
    _handleDeviceStateChange(agentCubit.state);
    final cacheRepository = conversationCacheRepository;
    if (cacheRepository != null) {
      _handleCacheSnapshot(cacheRepository.snapshot);
    }
    _handleSessionStateChange(sessionCubit.state);
  }

  List<DeviceWorkspace> _workspacesForAgent(String? agentId) =>
      agentId == null ? const [] : _workspaceCoordinator.workspacesForAgent(agentId);

  bool _isLoadingWorkspaces(String? agentId) =>
      agentId != null && _workspaceCoordinator.isLoadingWorkspaces(agentId);

  void _handleCacheSnapshot(DeviceConversationCacheSnapshot snapshot) {
    _workspaceCoordinator.handleCacheSnapshot(snapshot);
  }

  void _handleDeviceStateChange(DeviceState agentState) {
    if (agentState is DeviceActive) {
      final nextAgent = agentState.activeAgent;
      if (nextAgent.id != _currentAgent?.id) {
        _subscribeToAgent(nextAgent);
      } else {
        _currentAgent = nextAgent;
      }
    } else {
      final isTransientWithoutActive =
          agentState is DeviceLoading ||
          agentState is AgentInitial ||
          agentState is AgentError ||
          (agentState is DeviceNoActive && agentState.agents.isNotEmpty);
      if (isTransientWithoutActive) return;

      _requestGeneration++;
      _delayedLoadingTimer?.cancel();
      _currentAgent = null;
      workspaceRuntimeContext?.clear();
      _workspaceCoordinator.clearState();
      unawaited(_messageSubscription?.cancel());
      unawaited(_queuedMessagesSubscription?.cancel());
      unawaited(_attentionSubscription?.cancel());
      unawaited(_stopRecoverySubscription?.cancel());
      _interventionCoordinator.clearInFlightStopRecoveryAcks();
      _selectedSessionId = null;
      emit(const SessionMessagesState());
    }
  }

  void _handleSessionStateChange(SessionState sessionState) {
    final selectedSession = sessionState.selectedSession;
    final nextSessionId = selectedSession?.id;
    if (nextSessionId == _selectedSessionId) {
      final adoptedDeferredThinking = _adoptDeferredSessionThinking(selectedSession);
      final routeChangedForActiveSession =
          (nextSessionId != null && _syncConfirmedRouteFromSession(selectedSession)) || adoptedDeferredThinking;
      final currentWorkspace = _currentAgent == null ? null : _selectedWorkspaceForAgent(_currentAgent!);
      final newPermissionMode = _permissionModeForWorkspace(currentWorkspace);
      final permissionChanged = state.permissionMode != newPermissionMode;
      final workspaceChanged = state.selectedWorkspace?.id != currentWorkspace?.id;
      if (routeChangedForActiveSession || permissionChanged || workspaceChanged) {
        _emitCurrentState();
      }
      return;
    }

    final requestedAnchorKey = nextSessionId == null
        ? null
        : '${selectedSession?.deviceId ?? _currentAgent?.id}:$nextSessionId';
    _requestedHistoryAnchors.removeWhere(
      (key, _) => requestedAnchorKey == null || key != requestedAnchorKey,
    );
    final generation = ++_requestGeneration;
    _delayedLoadingTimer?.cancel();
    _selectedSessionId = nextSessionId;
    if (nextSessionId == null || nextSessionId.isEmpty) {
      final currentAgent = _currentAgent;
      emit(
        state.copyWith(
          messages: currentAgent == null
              ? const <CanonicalEvent>[]
              : conversationRepository.currentMessages(currentAgent),
          queuedMessages: currentAgent == null
              ? const <CanonicalEvent>[]
              : conversationRepository.currentQueuedMessages(currentAgent),
          isProcessing: false,
          clearActiveSessionId: true,
          nextMessageProviderId: currentAgent == null ? null : _nextMessageProviderByAgentId[currentAgent.id],
          clearNextMessageProviderId: currentAgent == null && state.nextMessageProviderId != null,
          nextMessageModel: currentAgent == null ? null : _nextMessageModelByAgentId[currentAgent.id],
          clearNextMessageModel: currentAgent == null && state.nextMessageModel != null,
          nextMessageThinkingMode: currentAgent == null ? null : _nextMessageThinkingByAgentId[currentAgent.id],
          clearNextMessageThinkingMode: currentAgent == null && state.nextMessageThinkingMode != null,
          availableWorkspaces: _workspacesForAgent(currentAgent?.id),
          selectedWorkspace: currentAgent == null ? null : _selectedWorkspaceForAgent(currentAgent),
          clearSelectedWorkspace: currentAgent == null,
          isLoadingWorkspaces: _isLoadingWorkspaces(currentAgent?.id),
          requiresWorkspace: currentAgent != null && _requiresWorkspace(currentAgent),
          clearPendingSuspendedRequest: true,
          clearRuntimeNotice: true,
          clearExecutionSnapshot: true,
          clearAttentionState: true,
          clearRequestedSessionId: true,
          isHistoryLoading: false,
          showDelayedLoading: false,
          hasOlderHistory: currentAgent != null && conversationRepository.historyHasMore(currentAgent),
          hasNewerHistory: currentAgent != null && conversationRepository.historyHasNewer(currentAgent),
          isOlderHistoryLoading: false,
          clearOlderHistoryError: true,
          isNewerHistoryLoading: false,
          clearNewerHistoryError: true,
        ),
      );
      return;
    }

    if (!_sessionMatchesAgent(selectedSession, _currentAgent)) {
      _scheduleDelayedLoading(nextSessionId);
      emit(
        state.copyWith(
          requestedSessionId: nextSessionId,
          isHistoryLoading: true,
          showDelayedLoading: false,
          clearHistoryLoadError: true,
        ),
      );
      return;
    }

    final agent = _currentAgent;
    if (agent != null) {
      final sessionWorkspace = _workspaceFromSession(selectedSession);
      _workspaceCoordinator.setSessionWorkspace(
        agent,
        sessionWorkspace,
        nextSessionId: nextSessionId,
      );
      _replaceSessionRouteContext(agent.id, selectedSession);
    }

    if (agent != null && _freshSessionIdsAwaitingFirstTurn.remove(nextSessionId)) {
      final attention = _attentionFor(agent, nextSessionId);
      emit(
        state.copyWith(
          messages: conversationRepository.currentMessages(agent),
          queuedMessages: conversationRepository.currentQueuedMessages(agent),
          isProcessing: attention?.executionSnapshot.isExecuting ?? false,
          activeSessionId: nextSessionId,
          nextMessageProviderId: _effectiveProviderFor(agent, nextSessionId),
          clearNextMessageProviderId: _effectiveProviderFor(agent, nextSessionId) == null,
          nextMessageModel: _effectiveModelFor(agent, nextSessionId),
          clearNextMessageModel: _effectiveModelFor(agent, nextSessionId) == null,
          confirmedNextMessageProviderId: _nextMessageProviderByAgentId[agent.id],
          clearConfirmedNextMessageProviderId: _nextMessageProviderByAgentId[agent.id] == null,
          confirmedNextMessageModel: _nextMessageModelByAgentId[agent.id],
          clearConfirmedNextMessageModel: _nextMessageModelByAgentId[agent.id] == null,
          pendingNextMessageProviderId: _pendingProviderForSession(nextSessionId),
          pendingNextMessageModel: _pendingModelForSession(nextSessionId),
          nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
          clearNextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id] == null,
          availableWorkspaces: _workspacesForAgent(agent.id),
          selectedWorkspace: _selectedWorkspaceForAgent(agent),
          clearSelectedWorkspace: _selectedWorkspaceForAgent(agent) == null,
          isLoadingWorkspaces: _isLoadingWorkspaces(agent.id),
          requiresWorkspace: _requiresWorkspace(agent),
          permissionMode: _permissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
          isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(
            _selectedWorkspaceForAgent(agent),
          ),
          pendingSuspendedRequest: attention?.pendingSuspendedRequest,
          clearPendingSuspendedRequest: attention?.pendingSuspendedRequest == null,
          runtimeNotice: attention?.runtimeNotice,
          clearRuntimeNotice: attention?.runtimeNotice == null,
          executionSnapshot: attention?.executionSnapshot,
          clearExecutionSnapshot: attention == null,
          attentionState: attention,
          clearAttentionState: attention == null,
          clearRequestedSessionId: true,
          isHistoryLoading: false,
          showDelayedLoading: false,
          hasOlderHistory: conversationRepository.historyHasMore(agent),
          hasNewerHistory: conversationRepository.historyHasNewer(agent),
          isOlderHistoryLoading: false,
          clearOlderHistoryError: true,
          isNewerHistoryLoading: false,
          clearNewerHistoryError: true,
        ),
      );
    } else if (agent != null) {
      _scheduleDelayedLoading(nextSessionId);

      emit(
        state.copyWith(
          requestedSessionId: nextSessionId,
          isHistoryLoading: true,
          showDelayedLoading: false,
          clearHistoryLoadError: true,
          selectedWorkspace: _selectedWorkspaceForAgent(agent),
          clearSelectedWorkspace: _selectedWorkspaceForAgent(agent) == null,
        ),
      );

      unawaited(_loadHistoryForAtomicSwap(agent, nextSessionId, generation));
    }
  }

  void _scheduleDelayedLoading(String sessionId) {
    _delayedLoadingTimer?.cancel();
    _delayedLoadingTimer = Timer(const Duration(milliseconds: 300), () {
      if (!isClosed && state.requestedSessionId == sessionId) {
        emit(state.copyWith(showDelayedLoading: true));
      }
    });
  }

  /// Retries the currently requested history load without changing the
  /// presented session. Stream updates remain gated until the retry succeeds.
  void retryHistoryLoad() {
    final agent = _currentAgent;
    final sessionId = state.requestedSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) return;
    final generation = ++_requestGeneration;
    _scheduleDelayedLoading(sessionId);
    emit(
      state.copyWith(
        isHistoryLoading: true,
        showDelayedLoading: false,
        clearHistoryLoadError: true,
      ),
    );
    unawaited(_loadHistoryForAtomicSwap(agent, sessionId, generation));
  }

  Future<void> loadOlderHistory() async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null ||
        sessionId == null ||
        state.isOlderHistoryLoading ||
        !state.hasOlderHistory ||
        state.requestedSessionId != null ||
        state.isHistoryLoading) {
      return;
    }
    final generation = _requestGeneration;
    emit(
      state.copyWith(
        isOlderHistoryLoading: true,
        clearOlderHistoryError: true,
      ),
    );
    try {
      await conversationRepository.loadOlderSessionHistory(agent, sessionId);
      if (isClosed || generation != _requestGeneration || state.activeSessionId != sessionId) {
        return;
      }
      emit(
        state.copyWith(
          messages: conversationRepository.currentMessages(agent),
          hasOlderHistory: conversationRepository.historyHasMore(agent),
          hasNewerHistory: conversationRepository.historyHasNewer(agent),
          isOlderHistoryLoading: false,
          clearOlderHistoryError: true,
          isNewerHistoryLoading: false,
          clearNewerHistoryError: true,
        ),
      );
    } catch (error, stackTrace) {
      if (isClosed || generation != _requestGeneration) return;
      _logger.warning(
        'Older history load failed device_id=${agent.id} '
        'session_id=$sessionId error_type=${error.runtimeType}',
        error,
        stackTrace,
      );
      emit(
        state.copyWith(
          isOlderHistoryLoading: false,
          olderHistoryError: 'Could not load earlier messages.',
        ),
      );
    }
  }

  Future<void> loadNewerHistory() async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null ||
        sessionId == null ||
        state.isNewerHistoryLoading ||
        !state.hasNewerHistory ||
        state.requestedSessionId != null ||
        state.isHistoryLoading) {
      return;
    }
    final generation = _requestGeneration;
    emit(
      state.copyWith(
        isNewerHistoryLoading: true,
        clearNewerHistoryError: true,
      ),
    );
    try {
      await conversationRepository.loadNewerSessionHistory(agent, sessionId);
      if (isClosed || generation != _requestGeneration || state.activeSessionId != sessionId) {
        return;
      }
      emit(
        state.copyWith(
          messages: conversationRepository.currentMessages(agent),
          hasNewerHistory: conversationRepository.historyHasNewer(agent),
          isNewerHistoryLoading: false,
          clearNewerHistoryError: true,
        ),
      );
    } catch (error, stackTrace) {
      if (isClosed || generation != _requestGeneration) return;
      _logger.warning(
        'Newer history load failed device_id=${agent.id} '
        'session_id=$sessionId error_type=${error.runtimeType}',
        error,
        stackTrace,
      );
      emit(
        state.copyWith(
          isNewerHistoryLoading: false,
          newerHistoryError: 'Could not load later messages.',
        ),
      );
    }
  }

  void requestHistoryAnchor({
    required String deviceId,
    required String sessionId,
    required String anchorEventId,
  }) {
    final anchor = anchorEventId.trim();
    if (anchor.isEmpty) return;
    _requestedHistoryAnchors['$deviceId:$sessionId'] = anchor;
  }

  Future<void> loadAnchoredHistory(
    String anchorEventId, {
    bool forceReopen = false,
  }) async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null ||
        sessionId == null ||
        anchorEventId.trim().isEmpty ||
        state.requestedSessionId != null ||
        state.isHistoryLoading) {
      return;
    }
    final anchorIsLoaded = state.messages.any(
      (event) => event.id == anchorEventId || event.eventId == anchorEventId,
    );
    if (anchorIsLoaded && !forceReopen) return;
    final generation = ++_requestGeneration;
    try {
      if (!anchorIsLoaded) {
        await conversationRepository.loadAnchoredSessionHistory(
          agent,
          sessionId,
          anchorEventId,
        );
      }
      if (isClosed || generation != _requestGeneration || state.activeSessionId != sessionId) {
        return;
      }
      _requestedHistoryAnchors.remove('${agent.id}:$sessionId');
      emit(
        state.copyWith(
          messages: conversationRepository.currentMessages(agent),
          hasOlderHistory: conversationRepository.historyHasMore(agent),
          hasNewerHistory: conversationRepository.historyHasNewer(agent),
          isOlderHistoryLoading: false,
          clearOlderHistoryError: true,
          isNewerHistoryLoading: false,
          clearNewerHistoryError: true,
          historyOpenRevision: forceReopen ? state.historyOpenRevision + 1 : state.historyOpenRevision,
        ),
      );
    } catch (error, stackTrace) {
      if (isClosed || generation != _requestGeneration) return;
      _logger.fine(
        'Saved history anchor unavailable device_id=${agent.id} '
        'session_id=$sessionId error_type=${error.runtimeType}',
        error,
        stackTrace,
      );
    }
  }

  /// Invalidates a deleted session even when it is merely the presentation
  /// retained underneath a newer requested destination.
  void invalidateDeletedSession(String deviceId, String sessionId) {
    if (_currentAgent?.id != deviceId && state.activeSessionId != sessionId) return;
    if (state.activeSessionId != sessionId && state.requestedSessionId != sessionId) return;
    final deletingRequested = state.requestedSessionId == sessionId;
    if (deletingRequested) {
      _requestGeneration++;
      _delayedLoadingTimer?.cancel();
    }
    emit(
      state.copyWith(
        messages: state.activeSessionId == sessionId ? const <CanonicalEvent>[] : null,
        queuedMessages: state.activeSessionId == sessionId ? const <CanonicalEvent>[] : null,
        clearActiveSessionId: state.activeSessionId == sessionId,
        clearRequestedSessionId: deletingRequested,
        isHistoryLoading: deletingRequested ? false : state.isHistoryLoading,
        showDelayedLoading: deletingRequested ? false : state.showDelayedLoading,
        clearHistoryLoadError: deletingRequested,
      ),
    );
  }

  Future<void> _loadHistoryForAtomicSwap(
    DeviceConfig agent,
    String sessionId,
    int generation,
  ) async {
    try {
      final anchorKey = '${agent.id}:$sessionId';
      final requestedAnchor = _requestedHistoryAnchors[anchorKey];
      if (requestedAnchor == null) {
        await conversationRepository.loadSessionHistory(agent, sessionId);
      } else {
        await conversationRepository.loadAnchoredSessionHistory(
          agent,
          sessionId,
          requestedAnchor,
        );
      }
      if (isClosed || generation != _requestGeneration) {
        if (!isClosed && state.requestedSessionId == sessionId && _selectedSessionId != sessionId) {
          _delayedLoadingTimer?.cancel();
        }
        return;
      }
      _requestedHistoryAnchors.remove(anchorKey);

      _delayedLoadingTimer?.cancel();
      final attention = _attentionFor(agent, sessionId);
      emit(
        state.copyWith(
          messages: conversationRepository.currentMessages(agent),
          queuedMessages: conversationRepository.currentQueuedMessages(agent),
          isProcessing: attention?.executionSnapshot.isExecuting ?? false,
          activeSessionId: sessionId,
          nextMessageProviderId: _effectiveProviderFor(agent, sessionId),
          clearNextMessageProviderId: _effectiveProviderFor(agent, sessionId) == null,
          nextMessageModel: _effectiveModelFor(agent, sessionId),
          clearNextMessageModel: _effectiveModelFor(agent, sessionId) == null,
          confirmedNextMessageProviderId: _nextMessageProviderByAgentId[agent.id],
          clearConfirmedNextMessageProviderId: _nextMessageProviderByAgentId[agent.id] == null,
          confirmedNextMessageModel: _nextMessageModelByAgentId[agent.id],
          clearConfirmedNextMessageModel: _nextMessageModelByAgentId[agent.id] == null,
          pendingNextMessageProviderId: _pendingProviderForSession(sessionId),
          pendingNextMessageModel: _pendingModelForSession(sessionId),
          nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
          clearNextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id] == null,
          availableWorkspaces: _workspacesForAgent(agent.id),
          selectedWorkspace: _selectedWorkspaceForAgent(agent),
          clearSelectedWorkspace: _selectedWorkspaceForAgent(agent) == null,
          isLoadingWorkspaces: _isLoadingWorkspaces(agent.id),
          requiresWorkspace: _requiresWorkspace(agent),
          permissionMode: _permissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
          isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(
            _selectedWorkspaceForAgent(agent),
          ),
          pendingSuspendedRequest: attention?.pendingSuspendedRequest,
          clearPendingSuspendedRequest: attention?.pendingSuspendedRequest == null,
          runtimeNotice: attention?.runtimeNotice,
          clearRuntimeNotice: attention?.runtimeNotice == null,
          executionSnapshot: attention?.executionSnapshot,
          clearExecutionSnapshot: attention == null,
          attentionState: attention,
          clearAttentionState: attention == null,
          clearRequestedSessionId: true,
          isHistoryLoading: false,
          showDelayedLoading: false,
          hasOlderHistory: conversationRepository.historyHasMore(agent),
          hasNewerHistory: conversationRepository.historyHasNewer(agent),
          isOlderHistoryLoading: false,
          clearOlderHistoryError: true,
          isNewerHistoryLoading: false,
          clearNewerHistoryError: true,
        ),
      );
    } catch (error, stackTrace) {
      if (isClosed || generation != _requestGeneration) return;
      _logger.severe(
        'History hydration failed phase=atomic_history_swap '
        'device_id=${agent.id} session_id=$sessionId generation=$generation '
        'error_type=${error.runtimeType}',
        error,
        stackTrace,
      );
      _delayedLoadingTimer?.cancel();
      emit(
        state.copyWith(
          isHistoryLoading: false,
          showDelayedLoading: false,
          historyLoadError: 'Could not load this conversation.',
        ),
      );
    }
  }

  void _subscribeToAgent(DeviceConfig? agent) {
    unawaited(_messageSubscription?.cancel());
    unawaited(_queuedMessagesSubscription?.cancel());
    unawaited(_attentionSubscription?.cancel());
    _workspaceCoordinator.cancelPolicySubscription();
    unawaited(_stopRecoverySubscription?.cancel());

    _currentAgent = agent;

    if (agent != null) {
      unawaited(_ensureWorkspacesForAgent(agent));
      final selectedSession = sessionCubit.state.selectedSession;
      final shouldLoadSelectedSession =
          selectedSession?.id == _selectedSessionId && _sessionMatchesAgent(selectedSession, agent);
      final sessionWorkspace = shouldLoadSelectedSession ? _workspaceFromSession(selectedSession) : null;
      // Only a resolved session workspace replaces the agent's selection here;
      // without one the current (possibly manual) selection is kept.
      if (sessionWorkspace != null) {
        _workspaceCoordinator.setSessionWorkspace(
          agent,
          sessionWorkspace,
          nextSessionId: _selectedSessionId,
        );
      }

      final bool isFreshSession;
      if (shouldLoadSelectedSession && _selectedSessionId != null && _selectedSessionId!.isNotEmpty) {
        if (_freshSessionIdsAwaitingFirstTurn.remove(_selectedSessionId!)) {
          isFreshSession = true;
        } else {
          isFreshSession = false;
          final generation = ++_requestGeneration;
          final sessionId = _selectedSessionId!;
          _scheduleDelayedLoading(sessionId);
          unawaited(_loadHistoryForAtomicSwap(agent, sessionId, generation));
        }
      } else {
        isFreshSession = false;
      }

      // Load persisted preferences if not already in memory for this session.
      // Provider and model form one route and must survive together.
      if (!_nextMessageProviderByAgentId.containsKey(agent.id)) {
        final savedProvider = preferencesRepository.getLastProvider(agent.id);
        if (savedProvider != null) {
          _nextMessageProviderByAgentId[agent.id] = savedProvider;
        }
      }
      if (!_nextMessageModelByAgentId.containsKey(agent.id)) {
        final savedModel = preferencesRepository.getLastModel(agent.id);
        if (savedModel != null) {
          _nextMessageModelByAgentId[agent.id] = savedModel;
        }
      }
      if (!_nextMessageThinkingByAgentId.containsKey(agent.id)) {
        final savedThinking = preferencesRepository.getLastThinkingMode(agent.id)?.trim();
        final caps = capabilitiesStore?.getForAgent(agent.id);
        if (caps?.usesModelThinkingControls == true) {
          if (savedThinking != null && savedThinking.isNotEmpty) {
            _setThinking(agent.id, savedThinking);
          }
        } else {
          final thinkingMode = savedThinking?.isNotEmpty == true ? savedThinking! : defaultThinkingMode;
          _setThinking(agent.id, thinkingMode);
          if (savedThinking == null || savedThinking.isEmpty) {
            unawaited(preferencesRepository.setLastThinkingMode(agent.id, thinkingMode));
          }
        }
      }

      final initialAttention = shouldLoadSelectedSession ? _attentionFor(agent, _selectedSessionId) : null;
      final bool loadingExistingSession = shouldLoadSelectedSession && !isFreshSession;
      emit(
        loadingExistingSession
            ? state.copyWith(
                requestedSessionId: _selectedSessionId,
                isHistoryLoading: true,
                showDelayedLoading: false,
                clearHistoryLoadError: true,
              )
            : state.copyWith(
                messages: conversationRepository.currentMessages(agent),
                queuedMessages: conversationRepository.currentQueuedMessages(agent),
                isProcessing: initialAttention?.executionSnapshot.isExecuting ?? false,
                activeSessionId: isFreshSession ? _selectedSessionId : null,
                clearActiveSessionId: !isFreshSession,
                clearRequestedSessionId: true,
                isHistoryLoading: false,
                nextMessageProviderId: _effectiveProviderFor(agent, _selectedSessionId),
                nextMessageModel: _effectiveModelFor(agent, _selectedSessionId),
                confirmedNextMessageProviderId: _nextMessageProviderByAgentId[agent.id],
                confirmedNextMessageModel: _nextMessageModelByAgentId[agent.id],
                pendingNextMessageProviderId: _pendingProviderForSession(_selectedSessionId),
                pendingNextMessageModel: _pendingModelForSession(_selectedSessionId),
                nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
                availableWorkspaces: _workspacesForAgent(agent.id),
                selectedWorkspace: _selectedWorkspaceForAgent(agent),
                clearSelectedWorkspace: _selectedWorkspaceForAgent(agent) == null,
                isLoadingWorkspaces: _isLoadingWorkspaces(agent.id),
                requiresWorkspace: _requiresWorkspace(agent),
                permissionMode: _permissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
                isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
                pendingSuspendedRequest: initialAttention?.pendingSuspendedRequest,
                clearPendingSuspendedRequest: initialAttention?.pendingSuspendedRequest == null,
                runtimeNotice: initialAttention?.runtimeNotice,
                clearRuntimeNotice: initialAttention?.runtimeNotice == null,
                executionSnapshot: initialAttention?.executionSnapshot,
                clearExecutionSnapshot: initialAttention == null,
                attentionState: initialAttention,
                clearAttentionState: initialAttention == null,
              ),
      );

      _messageSubscription = conversationRepository.watchMessages(agent).listen((messages) {
        if (state.requestedSessionId != null) return;
        final activeSessionId = _resolvedActiveSessionId();
        final attention = _attentionFor(agent, activeSessionId);
        emit(
          state.copyWith(
            messages: List.from(messages),
            pendingSteerCancellationRequestIds: state.pendingSteerCancellationRequestIds
                .where(
                  (requestId) => messages.any(
                    (event) =>
                        event.requestId == requestId &&
                        event.metadata?['pending_steer_state'] == 'pending' &&
                        event.metadata?['pending_cancel_outcome'] == null,
                  ),
                )
                .toSet(),
            isProcessing: attention?.executionSnapshot.isExecuting ?? false,
            activeSessionId: activeSessionId,
            clearActiveSessionId: activeSessionId == null,
            nextMessageProviderId: _effectiveProviderFor(agent, activeSessionId),
            nextMessageModel: _effectiveModelFor(agent, activeSessionId),
            confirmedNextMessageProviderId: _nextMessageProviderByAgentId[agent.id],
            confirmedNextMessageModel: _nextMessageModelByAgentId[agent.id],
            pendingNextMessageProviderId: _pendingProviderForSession(activeSessionId),
            pendingNextMessageModel: _pendingModelForSession(activeSessionId),
            nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
            availableWorkspaces: _workspacesForAgent(agent.id),
            selectedWorkspace: _selectedWorkspaceForAgent(agent),
            isLoadingWorkspaces: _isLoadingWorkspaces(agent.id),
            requiresWorkspace: _requiresWorkspace(agent),
            permissionMode: _permissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
            isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
            pendingSuspendedRequest: attention?.pendingSuspendedRequest,
            clearPendingSuspendedRequest: attention?.pendingSuspendedRequest == null,
            runtimeNotice: attention?.runtimeNotice,
            clearRuntimeNotice: attention?.runtimeNotice == null,
            executionSnapshot: attention?.executionSnapshot,
            clearExecutionSnapshot: attention == null,
            attentionState: attention,
            clearAttentionState: attention == null,
          ),
        );
      });

      _queuedMessagesSubscription = conversationRepository.watchQueuedMessages(agent).listen((queuedMessages) {
        if (state.requestedSessionId != null) return;
        final visibleIds = queuedMessages
            .where((event) => event.metadata?['queue_mutation_outcome'] == null)
            .map((event) => event.requestId)
            .whereType<String>()
            .toSet();
        emit(
          state.copyWith(
            queuedMessages: List.from(queuedMessages),
            queuedMutationRequestIds: state.queuedMutationRequestIds.intersection(visibleIds),
          ),
        );
      });

      _attentionSubscription = conversationRepository
          .watchAttentionStates(agent)
          .listen((_) => _emitAuthoritativeAttention(agent));
      _stopRecoverySubscription = conversationRepository
          .watchStopRecoveries(agent)
          .listen(
            (recovery) => unawaited(_applyStopRecovery(agent, recovery)),
          );
    }
  }

  bool _selectedSessionBelongsToCurrentClient() {
    final selectedSession = sessionCubit.state.selectedSession;
    return selectedSession?.id == _selectedSessionId && _sessionMatchesAgent(selectedSession, _currentAgent);
  }

  String? _resolvedActiveSessionId() {
    if (_selectedSessionBelongsToCurrentClient()) {
      return _selectedSessionId;
    }
    return state.activeSessionId ?? _selectedSessionId;
  }

  SessionAttentionState? _attentionFor(
    DeviceConfig agent,
    String? sessionId,
  ) {
    if (sessionId == null || sessionId.isEmpty) return null;
    return conversationRepository.currentAttentionStates(agent)[sessionId];
  }

  void _emitAuthoritativeAttention(DeviceConfig agent) {
    if (state.requestedSessionId != null || _currentAgent?.id != agent.id) return;
    final activeSessionId = _resolvedActiveSessionId();
    final attention = _attentionFor(agent, activeSessionId);
    // A transport rebind must not replace the last accepted authoritative
    // snapshot with a transient absence. Navigation commits replace it only
    // after history hydration succeeds.
    if (attention == null && state.attentionState?.sessionId == activeSessionId) {
      return;
    }
    emit(
      state.copyWith(
        isProcessing: attention?.executionSnapshot.isExecuting ?? false,
        pendingSuspendedRequest: attention?.pendingSuspendedRequest,
        clearPendingSuspendedRequest: attention?.pendingSuspendedRequest == null,
        runtimeNotice: attention?.runtimeNotice,
        clearRuntimeNotice: attention?.runtimeNotice == null,
        executionSnapshot: attention?.executionSnapshot,
        clearExecutionSnapshot: attention == null,
        attentionState: attention,
        clearAttentionState: attention == null,
      ),
    );
  }

  /// Sends [text], creating the session first when none is active.
  ///
  /// [omitThinkingMode] is set by the composer when the target route's
  /// resolved thinking control is `noControl`/`unknown`: the user cannot see or
  /// choose a value there, so no `thinking_mode` is sent with `create_session`
  /// or the turn and none is written onto the new session. The stored
  /// per-device preference is left untouched for routes that do offer it.
  Future<bool> sendMessage(
    String text, {
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
    List<Map<String, dynamic>> attachments = const [],
    bool omitThinkingMode = false,
  }) async {
    final agent = _currentAgent;
    if (agent == null) return false;
    final thinkingForTurn = omitThinkingMode ? null : _nextMessageThinkingByAgentId[agent.id];
    final workspaceId = _selectedWorkspaceForAgent(agent)?.id;
    if (_requiresWorkspace(agent) && (workspaceId == null || workspaceId.isEmpty)) {
      emit(state.copyWith(error: 'Select a workspace before sending your first Sanad Agent message.'));
      return false;
    }

    try {
      var targetSessionId = state.activeSessionId;
      if (targetSessionId == null || targetSessionId.isEmpty) {
        // Unified session-creation path: the first send always creates the
        // session eagerly (with or without a workspace), then navigates to it.
        // There is no deferred daemon-side draft creation path.
        final createdSession = await conversationRepository.createSession(
          agent,
          workspaceId: workspaceId,
          title: text.length > 80 ? '${text.substring(0, 77)}...' : text,
          isTitlePlaceholder: true,
          providerId: _effectiveProviderFor(agent, targetSessionId),
          model: _effectiveModelFor(agent, targetSessionId),
          thinkingMode: thinkingForTurn,
        );
        targetSessionId = createdSession.id;
        _freshSessionIdsAwaitingFirstTurn.add(createdSession.id);
        conversationRepository.activateSession(agent, targetSessionId);
        // Keep SessionCubit's selectedSession in sync with the locally created
        // session immediately, so that stream listeners in this cubit (which
        // derive activeSessionId via _selectedSessionBelongsToCurrentClient)
        // do not clear activeSessionId before the remote session_created event
        // arrives. Without this, the next sendMessage() would see a null
        // activeSessionId and create yet another new session.
        sessionCubit.markSessionSelectedSync(createdSession);
        sessionCubit.transferNewConversationDraftToSession(
          agent.id,
          createdSession.id,
        );
        emit(state.copyWith(activeSessionId: targetSessionId));
      }

      final repository = conversationRepository;
      final String? requestId;
      if (attachments.isNotEmpty) {
        if (repository is! AttachmentSendRepository) {
          throw StateError('Attachment admission is unavailable.');
        }
        requestId = await (repository as AttachmentSendRepository).sendMessageWithAttachments(
          agent,
          text,
          sessionId: targetSessionId,
          workspaceId: workspaceId,
          providerId: _effectiveProviderFor(agent, targetSessionId),
          model: _effectiveModelFor(agent, targetSessionId),
          thinkingMode: thinkingForTurn,
          attachments: attachments,
          intent: intent,
        );
      } else {
        requestId = await repository.sendMessage(
          agent,
          text,
          sessionId: targetSessionId,
          workspaceId: workspaceId,
          providerId: _effectiveProviderFor(agent, targetSessionId),
          model: _effectiveModelFor(agent, targetSessionId),
          thinkingMode: thinkingForTurn,
          intent: intent,
        );
      }
      if (targetSessionId.isNotEmpty && !omitThinkingMode) {
        sessionCubit.applyThinkingMode(targetSessionId, thinkingForTurn);
      }
      if (requestId != null && targetSessionId.isNotEmpty) {
        sessionCubit.markSessionDraftAwaitingAcceptance(
          agent.id,
          targetSessionId,
          requestId,
        );
        return true;
      }
      return false;
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return false;
    }
  }

  Future<void> steerMessage(String text, {required String requestId}) =>
      _interventionCoordinator.steerMessage(text, requestId: requestId);

  Future<void> deleteQueuedMessage({required String requestId}) =>
      _interventionCoordinator.deleteQueuedMessage(requestId: requestId);

  Future<void> cancelPendingSteer({required String requestId}) =>
      _interventionCoordinator.cancelPendingSteer(requestId: requestId);

  Future<void> stop() => _interventionCoordinator.stop();

  Future<void> _applyStopRecovery(DeviceConfig agent, StopDraftRecovery recovery) =>
      _interventionCoordinator.applyStopRecovery(agent, recovery);

  Future<TurnReplayResult> replayTurn({
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
    required TurnReplayAction action,
    String? message,
    List<Map<String, dynamic>>? attachmentEdits,
    bool confirmedReplayUnsafe = false,
    bool confirmedDropSteers = false,
  }) =>
      _interventionCoordinator.replayTurn(
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: expectedHistoryRevision,
        action: action,
        message: message,
        attachmentEdits: attachmentEdits,
        confirmedReplayUnsafe: confirmedReplayUnsafe,
        confirmedDropSteers: confirmedDropSteers,
      );

  Future<SessionForkResult> forkSession({
    required String targetMessageId,
    required String targetTurnId,
  }) =>
      _interventionCoordinator.forkSession(
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
      );

  Future<void> retryRuntimeNotice() => _interventionCoordinator.retryRuntimeNotice();

  Future<void> continueWithProvider({
    required String providerInstanceId,
    String? modelId,
  }) =>
      _interventionCoordinator.continueWithProvider(
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      );

  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) =>
      _interventionCoordinator.respondToSuspendedRequest(
        request,
        allow: allow,
        scope: scope,
        comment: comment,
        answer: answer,
      );

  Future<void> updateSessionPreferences({
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) {
      return;
    }

    try {
      final trimmedProviderId = providerId?.trim();
      final trimmedModel = model?.trim();
      final trimmedThinkingMode = thinkingMode?.trim();

      // 1. Immediately update SessionCubit state & cache
      sessionCubit.applySessionRoutePreferences(
        sessionId,
        providerId: trimmedProviderId,
        model: trimmedModel,
        thinkingMode: thinkingMode != null ? (trimmedThinkingMode ?? '') : null,
      );

      // 2. Persist device-level last preferences and in-memory nextMessage maps
      if (trimmedProviderId != null) {
        if (trimmedProviderId.isEmpty) {
          _nextMessageProviderByAgentId.remove(agent.id);
        } else {
          _nextMessageProviderByAgentId[agent.id] = trimmedProviderId;
          unawaited(preferencesRepository.setLastProvider(agent.id, trimmedProviderId));
        }
      }

      if (trimmedModel != null) {
        if (trimmedModel.isEmpty) {
          _nextMessageModelByAgentId.remove(agent.id);
          unawaited(preferencesRepository.clearPreferences(agent.id));
        } else {
          _nextMessageModelByAgentId[agent.id] = trimmedModel;
          unawaited(preferencesRepository.setLastModel(agent.id, trimmedModel));
        }
      }

      if (thinkingMode != null) {
        if (trimmedThinkingMode == null || trimmedThinkingMode.isEmpty) {
          _setThinking(agent.id, null);
          unawaited(preferencesRepository.clearLastThinkingMode(agent.id));
        } else {
          _setThinking(agent.id, trimmedThinkingMode);
          unawaited(preferencesRepository.setLastThinkingMode(agent.id, trimmedThinkingMode));
        }
      }

      emit(
        state.copyWith(
          nextMessageProviderId: _nextMessageProviderByAgentId[agent.id],
          nextMessageModel: _nextMessageModelByAgentId[agent.id],
          nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
        ),
      );

      await conversationRepository.updateSessionPreferences(
        agent,
        sessionId: sessionId,
        providerId: providerId,
        model: model,
        thinkingMode: thinkingMode,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  /// Shows [thinkingMode] as the open conversation's effective selection and
  /// makes it the value the next send carries, in memory only. It writes no
  /// session preference and no device preference: opening or hydrating a
  /// conversation is never a user choice (live acceptance 106b r2 G2).
  ///
  /// The admitted value is not an explicit choice either, so it leaves
  /// [explicitNextMessageThinkingMode] untouched: a New Conversation draft
  /// persists only that explicit value (Task 122 D2).
  void admitNextMessageThinkingMode(String? thinkingMode) {
    final agent = _currentAgent;
    if (agent == null) return;
    _setThinking(agent.id, thinkingMode, explicit: false);
    emit(
      state.copyWith(
        nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
        clearNextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id] == null,
      ),
    );
  }

  /// The thinking value the user explicitly chose for the next send on the
  /// current device (or the selected conversation's own stored selection),
  /// excluding any route default admitted only for display and the next send.
  String? get explicitNextMessageThinkingMode {
    final agent = _currentAgent;
    return agent == null ? null : _explicitThinkingByAgentId[agent.id];
  }

  /// Sets the next-send thinking value for [deviceId]. An [explicit] value is a
  /// user choice (or the selected conversation's own stored selection) and is
  /// recorded as such; an admitted route default changes only the next-send
  /// value.
  void _setThinking(String deviceId, String? value, {bool explicit = true}) {
    final normalized = value?.trim();
    void apply(Map<String, String> values) {
      if (normalized == null || normalized.isEmpty) {
        values.remove(deviceId);
      } else {
        values[deviceId] = normalized;
      }
    }

    apply(_nextMessageThinkingByAgentId);
    if (explicit) apply(_explicitThinkingByAgentId);
  }

  void replaceNextMessagePreferences({
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    final agent = _currentAgent;
    if (agent == null) return;

    void replace(Map<String, String> values, String? value) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) {
        values.remove(agent.id);
      } else {
        values[agent.id] = normalized;
      }
    }

    replace(_nextMessageProviderByAgentId, providerId);
    replace(_nextMessageModelByAgentId, model);
    _setThinking(agent.id, thinkingMode);
    _emitCurrentState(error: null);
  }

  void setNextMessagePreferences({
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    final agent = _currentAgent;
    if (agent == null) {
      return;
    }
    final activeSessionId = state.activeSessionId;
    if (state.runtimeNotice != null && activeSessionId != null && activeSessionId.isNotEmpty) {
      stagePendingRouteSelection(providerId: providerId, model: model);
      if (thinkingMode != null) {
        final trimmedThinkingMode = thinkingMode.trim();
        if (trimmedThinkingMode.isEmpty) {
          _setThinking(agent.id, null);
          unawaited(preferencesRepository.clearLastThinkingMode(agent.id));
        } else {
          _setThinking(agent.id, trimmedThinkingMode);
          unawaited(preferencesRepository.setLastThinkingMode(agent.id, trimmedThinkingMode));
        }
        sessionCubit.applyThinkingMode(
          activeSessionId,
          trimmedThinkingMode.isEmpty ? null : trimmedThinkingMode,
        );
      }
      emit(
        state.copyWith(
          activeSessionId: activeSessionId,
          nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
          error: null,
        ),
      );
      return;
    }

    final trimmedModel = model?.trim();
    final trimmedThinkingMode = thinkingMode?.trim();
    final trimmedProviderId = providerId?.trim();

    if (trimmedProviderId != null) {
      if (trimmedProviderId.isEmpty) {
        _nextMessageProviderByAgentId.remove(agent.id);
      } else {
        _nextMessageProviderByAgentId[agent.id] = trimmedProviderId;
        unawaited(
          preferencesRepository.setLastProvider(agent.id, trimmedProviderId),
        );
      }
    }

    if (trimmedModel != null) {
      if (trimmedModel.isEmpty) {
        _nextMessageModelByAgentId.remove(agent.id);
        unawaited(preferencesRepository.clearPreferences(agent.id)); // Or just clear model?
      } else {
        _nextMessageModelByAgentId[agent.id] = trimmedModel;
        unawaited(preferencesRepository.setLastModel(agent.id, trimmedModel));
      }
    }

    if (trimmedThinkingMode != null) {
      if (trimmedThinkingMode.isEmpty) {
        _setThinking(agent.id, null);
        unawaited(preferencesRepository.clearLastThinkingMode(agent.id));
      } else {
        _setThinking(agent.id, trimmedThinkingMode);
        unawaited(preferencesRepository.setLastThinkingMode(agent.id, trimmedThinkingMode));
      }
      final activeSessionId = state.activeSessionId;
      if (activeSessionId != null && activeSessionId.isNotEmpty) {
        sessionCubit.applyThinkingMode(
          activeSessionId,
          trimmedThinkingMode.isEmpty ? null : trimmedThinkingMode,
        );
      }
    }

    _emitCurrentState(error: null);
  }

  void stagePendingRouteSelection({String? providerId, String? model}) {
    final sessionId = state.activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    _setPendingRouteSelection(
      sessionId: sessionId,
      providerId: providerId,
      modelId: model,
    );
    final pendingProvider = _pendingProviderForSession(sessionId);
    final pendingModel = _pendingModelForSession(sessionId);
    emit(
      state.copyWith(
        pendingNextMessageProviderId: pendingProvider,
        clearPendingNextMessageProviderId: pendingProvider == null,
        pendingNextMessageModel: pendingModel,
        clearPendingNextMessageModel: pendingModel == null,
      ),
    );
  }

  void clearError() {
    emit(state.copyWith(error: null));
  }

  void _emitCurrentState({String? error}) {
    if (state.requestedSessionId != null) return;
    final agent = _currentAgent;
    final activeSessionId = _resolvedActiveSessionId();
    final attention = agent == null ? null : _attentionFor(agent, activeSessionId);
    final pendingProviderId = _pendingProviderForSession(activeSessionId);
    final pendingModelId = _pendingModelForSession(activeSessionId);
    emit(
      state.copyWith(
        messages: agent == null ? const <CanonicalEvent>[] : conversationRepository.currentMessages(agent),
        queuedMessages: agent == null ? const <CanonicalEvent>[] : conversationRepository.currentQueuedMessages(agent),
        isProcessing: attention?.executionSnapshot.isExecuting ?? false,
        activeSessionId: activeSessionId,
        clearActiveSessionId: activeSessionId == null,
        nextMessageProviderId: _effectiveProviderFor(agent, activeSessionId),
        clearNextMessageProviderId: _effectiveProviderFor(agent, activeSessionId) == null,
        nextMessageModel: _effectiveModelFor(agent, activeSessionId),
        clearNextMessageModel: _effectiveModelFor(agent, activeSessionId) == null,
        confirmedNextMessageProviderId: agent == null ? null : _nextMessageProviderByAgentId[agent.id],
        clearConfirmedNextMessageProviderId: agent == null || _nextMessageProviderByAgentId[agent.id] == null,
        confirmedNextMessageModel: agent == null ? null : _nextMessageModelByAgentId[agent.id],
        clearConfirmedNextMessageModel: agent == null || _nextMessageModelByAgentId[agent.id] == null,
        pendingNextMessageProviderId: pendingProviderId,
        clearPendingNextMessageProviderId: pendingProviderId == null,
        pendingNextMessageModel: pendingModelId,
        clearPendingNextMessageModel: pendingModelId == null,
        nextMessageThinkingMode: agent == null ? null : _nextMessageThinkingByAgentId[agent.id],
        clearNextMessageThinkingMode: agent == null || _nextMessageThinkingByAgentId[agent.id] == null,
        availableWorkspaces: _workspacesForAgent(agent?.id),
        selectedWorkspace: agent == null ? null : _selectedWorkspaceForAgent(agent),
        isLoadingWorkspaces: _isLoadingWorkspaces(agent?.id),
        requiresWorkspace: agent != null && _requiresWorkspace(agent),
        permissionMode: _permissionModeForWorkspace(agent == null ? null : _selectedWorkspaceForAgent(agent)),
        isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(
          agent == null ? null : _selectedWorkspaceForAgent(agent),
        ),
        pendingSuspendedRequest: attention?.pendingSuspendedRequest,
        clearPendingSuspendedRequest: attention?.pendingSuspendedRequest == null,
        runtimeNotice: attention?.runtimeNotice,
        clearRuntimeNotice: attention?.runtimeNotice == null,
        executionSnapshot: attention?.executionSnapshot,
        clearExecutionSnapshot: attention == null,
        attentionState: attention,
        clearAttentionState: attention == null,
        error: error,
      ),
    );
  }

  String? _pendingProviderForSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) {
      return null;
    }
    return _pendingRouteProviderBySessionId[sessionId];
  }

  String? _pendingModelForSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) {
      return null;
    }
    return _pendingRouteModelBySessionId[sessionId];
  }

  void _replaceSessionRouteContext(String deviceId, Session? session) {
    final providerId = session?.modelProvider?.trim();
    final modelId = session?.model?.trim();
    final hasCompleteRoute = providerId?.isNotEmpty == true && modelId?.isNotEmpty == true;
    final hasAuthoritativeRouteRevision = session?.routeRevision != null;
    if (!hasCompleteRoute && !hasAuthoritativeRouteRevision && _isIdentityOnlySessionPlaceholder(session)) {
      // Startup may restore the selected session as an identity-only
      // placeholder before its authoritative summary/history arrives. It must
      // not erase the persisted device route during that transient window.
      final sessionId = session?.id;
      if (sessionId != null && sessionId.isNotEmpty) {
        _deferredRouteContextSessionIds.add(sessionId);
      }
      return;
    }
    if (session != null) {
      _deferredRouteContextSessionIds.remove(session.id);
    }

    void replace(Map<String, String> values, String? value) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) {
        values.remove(deviceId);
      } else {
        values[deviceId] = normalized;
      }
    }

    replace(_nextMessageProviderByAgentId, providerId);
    replace(_nextMessageModelByAgentId, modelId);
    _setThinking(deviceId, session?.thinkingMode);
  }

  /// Completes a deferred placeholder replacement once the same session's
  /// authoritative summary arrives: the conversation's own stored thinking
  /// selection (or its absence) becomes the next-send value, in memory only.
  /// The device preference written by another conversation must never stand in
  /// for this conversation's stored pick after a Client restart. The route
  /// itself is confirmed by [_syncConfirmedRouteFromSession].
  bool _adoptDeferredSessionThinking(Session? session) {
    final agent = _currentAgent;
    if (agent == null || session == null || !_deferredRouteContextSessionIds.contains(session.id)) {
      return false;
    }
    final hasCompleteRoute =
        session.modelProvider?.trim().isNotEmpty == true && session.model?.trim().isNotEmpty == true;
    if (!hasCompleteRoute && session.routeRevision == null && _isIdentityOnlySessionPlaceholder(session)) {
      return false;
    }
    _deferredRouteContextSessionIds.remove(session.id);
    final stored = session.thinkingMode?.trim();
    final previous = _nextMessageThinkingByAgentId[agent.id];
    if (stored == null || stored.isEmpty) {
      _setThinking(agent.id, null);
    } else {
      _setThinking(agent.id, stored);
    }
    return previous != _nextMessageThinkingByAgentId[agent.id];
  }

  bool _isIdentityOnlySessionPlaceholder(Session? session) {
    final title = session?.title.trim();
    return title == 'Loading...' || title == 'Loading…';
  }

  String? _effectiveProviderFor(DeviceConfig? agent, String? sessionId) {
    return agent == null ? null : _nextMessageProviderByAgentId[agent.id];
  }

  String? _effectiveModelFor(DeviceConfig? agent, String? sessionId) {
    return agent == null ? null : _nextMessageModelByAgentId[agent.id];
  }

  void _setPendingRouteSelection({
    required String sessionId,
    String? providerId,
    String? modelId,
  }) {
    final trimmedProviderId = providerId?.trim();
    final trimmedModelId = modelId?.trim();
    if (trimmedProviderId != null) {
      if (trimmedProviderId.isEmpty) {
        _pendingRouteProviderBySessionId.remove(sessionId);
      } else {
        _pendingRouteProviderBySessionId[sessionId] = trimmedProviderId;
      }
    }
    if (trimmedModelId != null) {
      if (trimmedModelId.isEmpty) {
        _pendingRouteModelBySessionId.remove(sessionId);
      } else {
        _pendingRouteModelBySessionId[sessionId] = trimmedModelId;
      }
    }
  }

  bool _syncConfirmedRouteFromSession(Session? session) {
    final agent = _currentAgent;
    if (agent == null || session == null || !_sessionMatchesAgent(session, agent)) {
      return false;
    }
    var changed = false;
    final provider = session.modelProvider?.trim();
    final model = session.model?.trim();
    final routeRevision = session.routeRevision;
    final previousRevision = _confirmedRouteRevisionBySessionId[session.id];
    if (routeRevision != null && previousRevision != null && routeRevision < previousRevision) {
      return false;
    }
    if (routeRevision != null && routeRevision == previousRevision) {
      // A repeated authoritative snapshot is still allowed to repair a route
      // field lost from local projection during client reconstruction. It must
      // not overwrite a non-empty value because that may represent newer local
      // intent awaiting confirmation.
      if (provider != null && provider.isNotEmpty && _nextMessageProviderByAgentId[agent.id]?.isNotEmpty != true) {
        _nextMessageProviderByAgentId[agent.id] = provider;
        unawaited(preferencesRepository.setLastProvider(agent.id, provider));
        changed = true;
      }
      if (model != null && model.isNotEmpty && _nextMessageModelByAgentId[agent.id]?.isNotEmpty != true) {
        _nextMessageModelByAgentId[agent.id] = model;
        unawaited(preferencesRepository.setLastModel(agent.id, model));
        changed = true;
      }
      return changed;
    }
    final hadPendingSelection =
        _pendingRouteProviderBySessionId.containsKey(session.id) ||
        _pendingRouteModelBySessionId.containsKey(session.id);
    if (provider != null && provider.isNotEmpty && _nextMessageProviderByAgentId[agent.id] != provider) {
      _nextMessageProviderByAgentId[agent.id] = provider;
      unawaited(preferencesRepository.setLastProvider(agent.id, provider));
      changed = true;
    }
    if (model != null && model.isNotEmpty && _nextMessageModelByAgentId[agent.id] != model) {
      _nextMessageModelByAgentId[agent.id] = model;
      unawaited(preferencesRepository.setLastModel(agent.id, model));
      changed = true;
    }
    final isAuthoritativeConfirmation = routeRevision != null;
    if (isAuthoritativeConfirmation) {
      _confirmedRouteRevisionBySessionId[session.id] = routeRevision;
    }
    if (isAuthoritativeConfirmation && hadPendingSelection) {
      _pendingRouteProviderBySessionId.remove(session.id);
      _pendingRouteModelBySessionId.remove(session.id);
      changed = true;
    }
    return changed;
  }

  Future<void> refreshWorkspaces() => _workspaceCoordinator.refreshWorkspaces();

  Future<SessionCompactResult> compactSession() =>
      _interventionCoordinator.compactSession();

  Future<List<SlashCommandEntry>> searchSlashCommands({String? query}) =>
      _interventionCoordinator.searchSlashCommands(query: query);

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({String? path}) =>
      _workspaceCoordinator.browseWorkspaceTree(path: path);

  void selectWorkspace(DeviceWorkspace workspace) =>
      _workspaceCoordinator.selectWorkspace(workspace);

  void clearWorkspace() => _workspaceCoordinator.clearWorkspace();

  Future<DeviceWorkspace?> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) =>
      _workspaceCoordinator.createWorkspace(
        path: path,
        name: name,
        description: description,
      );

  Future<void> _ensureWorkspacesForAgent(DeviceConfig agent, {bool force = false}) =>
      _workspaceCoordinator.ensureWorkspacesForAgent(agent, force: force);

  Future<WorkspacePolicyChangeFailure?> setWorkspacePermissionMode(WorkspacePermissionMode permissionMode) =>
      _workspaceCoordinator.setWorkspacePermissionMode(permissionMode);

  bool _sessionMatchesAgent(Session? session, DeviceConfig? agent) =>
      SessionWorkspaceCoordinator.sessionMatchesAgent(session, agent);

  DeviceWorkspace? _selectedWorkspaceForAgent(DeviceConfig agent) =>
      _workspaceCoordinator.selectedWorkspaceForAgent(agent);

  DeviceWorkspace? _workspaceFromSession(Session? session) =>
      _workspaceCoordinator.workspaceFromSession(session);

  bool _requiresWorkspace(DeviceConfig agent) =>
      _workspaceCoordinator.requiresWorkspace(agent);

  WorkspacePermissionMode _permissionModeForWorkspace(DeviceWorkspace? workspace) =>
      _workspaceCoordinator.permissionModeForWorkspace(workspace);

  bool _isLoadingPermissionModeForWorkspace(DeviceWorkspace? workspace) =>
      _workspaceCoordinator.isLoadingPermissionModeForWorkspace(workspace);

  @override
  Future<void> close() async {
    _delayedLoadingTimer?.cancel();
    _interventionCoordinator.clearInFlightStopRecoveryAcks();
    await _agentStateSubscription?.cancel();
    await _cacheSubscription?.cancel();
    await _sessionStateSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _queuedMessagesSubscription?.cancel();
    await _stopRecoverySubscription?.cancel();
    await _attentionSubscription?.cancel();
    await _workspaceCoordinator.dispose();
    return super.close();
  }
}
