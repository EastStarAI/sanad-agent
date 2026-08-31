import 'dart:async';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
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
import 'package:uuid/uuid.dart';

import 'session_messages_state.dart';

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
  StreamSubscription<WorkspacePolicy>? _workspacePolicySubscription;
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
  final Map<String, String> _nextMessageProviderByAgentId = {};
  final Map<String, String> _pendingRouteProviderBySessionId = {};
  final Map<String, String> _pendingRouteModelBySessionId = {};
  final Map<String, int> _confirmedRouteRevisionBySessionId = {};
  final Map<String, List<DeviceWorkspace>> _workspacesByAgentId = {};
  final Map<String, DeviceWorkspace> _selectedWorkspaceByAgentId = {};
  final Set<String> _loadingWorkspaceAgentIds = {};
  final Map<String, WorkspacePermissionMode> _permissionModesByWorkspaceId = {};
  final Set<String> _loadingPermissionModeWorkspaceIds = {};
  final Map<String, int> _workspacePolicyLoadIds = {};
  final Set<String> _freshSessionIdsAwaitingFirstTurn = {};
  final Set<String> _initiatedStopRequestIds = {};
  final Map<String, String> _stopRecoveryClaimIds = {};
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
  }) : super(const SessionMessagesState()) {
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

  void _handleCacheSnapshot(DeviceConversationCacheSnapshot snapshot) {
    final agent = _currentAgent;
    if (agent == null) return;
    final cachedWorkspaces = snapshot.contexts[agent.id]?.workspaces;
    if (cachedWorkspaces == null || !cachedWorkspaces.state.hasUsableSnapshot) return;

    final workspaces = List<DeviceWorkspace>.unmodifiable(cachedWorkspaces.workspaces);
    _workspacesByAgentId[agent.id] = workspaces;

    final currentSelection = _selectedWorkspaceByAgentId[agent.id];
    var selectedWorkspace = currentSelection;
    if (currentSelection != null) {
      for (final workspace in workspaces) {
        if (workspace.id == currentSelection.id) {
          selectedWorkspace = workspace;
          break;
        }
      }
      _selectedWorkspaceByAgentId[agent.id] = selectedWorkspace!;
      workspaceRuntimeContext?.setActiveWorkspace(selectedWorkspace);
    }

    if (!isClosed) {
      emit(
        state.copyWith(
          availableWorkspaces: workspaces,
          selectedWorkspace: selectedWorkspace,
          clearSelectedWorkspace: selectedWorkspace == null,
        ),
      );
    }
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
      _loadingPermissionModeWorkspaceIds.clear();
      unawaited(_messageSubscription?.cancel());
      unawaited(_queuedMessagesSubscription?.cancel());
      unawaited(_attentionSubscription?.cancel());
      unawaited(_stopRecoverySubscription?.cancel());
      _selectedSessionId = null;
      emit(const SessionMessagesState());
    }
  }

  void _handleSessionStateChange(SessionState sessionState) {
    final selectedSession = sessionState.selectedSession;
    final nextSessionId = selectedSession?.id;
    final routeChangedForActiveSession =
        nextSessionId != null && nextSessionId == _selectedSessionId && _syncConfirmedRouteFromSession(selectedSession);
    if (nextSessionId == _selectedSessionId) {
      if (routeChangedForActiveSession) {
        _emitCurrentState();
      }
      return;
    }

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
          availableWorkspaces: currentAgent == null ? const [] : _workspacesByAgentId[currentAgent.id] ?? const [],
          selectedWorkspace: currentAgent == null ? null : _selectedWorkspaceForAgent(currentAgent),
          clearSelectedWorkspace: currentAgent == null,
          isLoadingWorkspaces: currentAgent != null && _loadingWorkspaceAgentIds.contains(currentAgent.id),
          requiresWorkspace: currentAgent != null && _requiresWorkspace(currentAgent),
          clearPendingSuspendedRequest: true,
          clearRuntimeNotice: true,
          clearExecutionSnapshot: true,
          clearAttentionState: true,
          clearRequestedSessionId: true,
          isHistoryLoading: false,
          showDelayedLoading: false,
        ),
      );
      return;
    }

    if (selectedSession?.deviceId != _currentAgent?.id) {
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
      if (sessionWorkspace != null) {
        _selectedWorkspaceByAgentId[agent.id] = sessionWorkspace;
        workspaceRuntimeContext?.setActiveWorkspace(sessionWorkspace);
        if (nextSessionId.isNotEmpty) {
          workspaceRuntimeContext?.bindSessionWorkspace(nextSessionId, sessionWorkspace);
        }
        unawaited(_loadPermissionModeForWorkspace(sessionWorkspace));
      } else {
        _selectedWorkspaceByAgentId.remove(agent.id);
        workspaceRuntimeContext?.setActiveWorkspace(null);
      }
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
          availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
          selectedWorkspace: _selectedWorkspaceForAgent(agent),
          clearSelectedWorkspace: _selectedWorkspaceForAgent(agent) == null,
          isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
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
      await conversationRepository.loadSessionHistory(agent, sessionId);
      if (isClosed || generation != _requestGeneration) return;

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
          availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
          selectedWorkspace: _selectedWorkspaceForAgent(agent),
          clearSelectedWorkspace: _selectedWorkspaceForAgent(agent) == null,
          isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
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
    unawaited(_workspacePolicySubscription?.cancel());

    _currentAgent = agent;

    if (agent != null) {
      unawaited(_ensureWorkspacesForAgent(agent));
      final selectedSession = sessionCubit.state.selectedSession;
      final shouldLoadSelectedSession =
          selectedSession?.id == _selectedSessionId && selectedSession?.deviceId == agent.id;
      final sessionWorkspace = shouldLoadSelectedSession ? _workspaceFromSession(selectedSession) : null;
      if (sessionWorkspace != null) {
        _selectedWorkspaceByAgentId[agent.id] = sessionWorkspace;
        workspaceRuntimeContext?.setActiveWorkspace(sessionWorkspace);
        if (_selectedSessionId != null && _selectedSessionId!.isNotEmpty) {
          workspaceRuntimeContext?.bindSessionWorkspace(_selectedSessionId!, sessionWorkspace);
        }
        unawaited(_loadPermissionModeForWorkspace(sessionWorkspace));
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
        final thinkingMode = savedThinking?.isNotEmpty == true ? savedThinking! : defaultThinkingMode;
        _nextMessageThinkingByAgentId[agent.id] = thinkingMode;
        if (savedThinking == null || savedThinking.isEmpty) {
          unawaited(preferencesRepository.setLastThinkingMode(agent.id, thinkingMode));
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
                availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
                selectedWorkspace: _selectedWorkspaceForAgent(agent),
                isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
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
            availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
            selectedWorkspace: _selectedWorkspaceForAgent(agent),
            isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
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
    return selectedSession?.id == _selectedSessionId && selectedSession?.deviceId == _currentAgent?.id;
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

  Future<void> sendMessage(String text, {MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) async {
    final agent = _currentAgent;
    if (agent == null) return;
    final workspaceId = _selectedWorkspaceForAgent(agent)?.id;
    if (_requiresWorkspace(agent) && (workspaceId == null || workspaceId.isEmpty)) {
      emit(state.copyWith(error: 'Select a workspace before sending your first Sanad Agent message.'));
      return;
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
          thinkingMode: _nextMessageThinkingByAgentId[agent.id],
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

      final requestId = await conversationRepository.sendMessage(
        agent,
        text,
        sessionId: targetSessionId,
        workspaceId: workspaceId,
        providerId: _effectiveProviderFor(agent, targetSessionId),
        model: _effectiveModelFor(agent, targetSessionId),
        thinkingMode: _nextMessageThinkingByAgentId[agent.id],
        intent: intent,
      );
      if (requestId != null && targetSessionId.isNotEmpty) {
        sessionCubit.markSessionDraftAwaitingAcceptance(
          agent.id,
          targetSessionId,
          requestId,
        );
      }
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> steerMessage(String text, {required String requestId}) async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) return;
    emit(state.copyWith(queuedMutationRequestIds: {...state.queuedMutationRequestIds, requestId}));
    try {
      await conversationRepository.steerMessage(
        agent,
        text,
        requestId: requestId,
        sessionId: sessionId,
      );
    } catch (e) {
      emit(
        state.copyWith(
          error: e.toString(),
          queuedMutationRequestIds: {...state.queuedMutationRequestIds}..remove(requestId),
        ),
      );
    }
  }

  Future<void> deleteQueuedMessage({required String requestId}) async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null || requestId.isEmpty) return;
    emit(state.copyWith(queuedMutationRequestIds: {...state.queuedMutationRequestIds, requestId}));
    final operationId = await conversationRepository.deleteQueuedMessage(
      agent,
      requestId: requestId,
      sessionId: sessionId,
    );
    if (operationId == null) {
      emit(state.copyWith(queuedMutationRequestIds: {...state.queuedMutationRequestIds}..remove(requestId)));
    }
  }

  Future<void> cancelPendingSteer({required String requestId}) async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null || requestId.isEmpty) return;
    emit(
      state.copyWith(
        pendingSteerCancellationRequestIds: {...state.pendingSteerCancellationRequestIds, requestId},
      ),
    );
    final operationId = await conversationRepository.cancelPendingSteer(
      agent,
      requestId: requestId,
      sessionId: sessionId,
    );
    if (operationId == null) {
      emit(
        state.copyWith(
          pendingSteerCancellationRequestIds: {...state.pendingSteerCancellationRequestIds}..remove(requestId),
        ),
      );
    }
  }

  Future<void> stop() async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null) return;
    final requestId = const Uuid().v4();
    final recoveryOwnerToken = const Uuid().v4();
    final cache = sessionCubit.conversationCacheRepository;
    try {
      await cache?.markStopRecoveryPendingAndFlush(
        agent.id,
        sessionId,
        requestId,
        ownerToken: recoveryOwnerToken,
      );
    } catch (_) {
      return;
    }
    _initiatedStopRequestIds.add(requestId);
    final acceptedRequestId = await conversationRepository.stop(
      agent,
      sessionId: sessionId,
      requestId: requestId,
      recoveryOwnerToken: recoveryOwnerToken,
    );
    if (acceptedRequestId == null) {
      _initiatedStopRequestIds.remove(requestId);
      await cache?.unmarkStopRecoveryPendingAndFlush(agent.id, sessionId, requestId);
    }
  }

  Future<void> _applyStopRecovery(DeviceConfig agent, StopDraftRecovery recovery) async {
    final cache = sessionCubit.conversationCacheRepository;
    if (cache == null) return;
    if (recovery.claimRequired) {
      if (_stopRecoveryClaimIds.containsKey(recovery.stopRequestId)) return;
      final claimId = const Uuid().v4();
      _stopRecoveryClaimIds[recovery.stopRequestId] = claimId;
      try {
        await cache.setStopRecoveryClaimAndFlush(
          agent.id,
          recovery.sessionId,
          recovery.stopRequestId,
          claimId,
        );
      } catch (_) {
        _stopRecoveryClaimIds.remove(recovery.stopRequestId);
        return;
      }
      final acceptedClaimId = await conversationRepository.claimStopRecovery(
        agent,
        sessionId: recovery.sessionId,
        stopRequestId: recovery.stopRequestId,
        commandRequestId: claimId,
      );
      if (acceptedClaimId == null) {
        _stopRecoveryClaimIds.remove(recovery.stopRequestId);
        try {
          await cache.clearStopRecoveryClaimAndFlush(
            agent.id,
            recovery.sessionId,
            recovery.stopRequestId,
          );
        } catch (_) {}
      }
      return;
    }
    final draft = cache.sessionDraft(agent.id, recovery.sessionId);
    final persistedClaimId = draft?.stopRecoveryClaimIds[recovery.stopRequestId];
    final recoveryOwnerToken = draft?.stopRecoveryOwnerTokens[recovery.stopRequestId];
    final claimedByThisClient =
        recovery.recoveryReason == 'daemon_restart' &&
        recovery.claimedBy != null &&
        (_stopRecoveryClaimIds[recovery.stopRequestId] == recovery.claimedBy || persistedClaimId == recovery.claimedBy);
    final alreadyApplied = draft?.appliedStopRecoveryIds.contains(recovery.stopRequestId) == true;
    final isOwned = recovery.recoveryReason == 'daemon_restart'
        ? claimedByThisClient || alreadyApplied
        : recoveryOwnerToken != null && recoveryOwnerToken.isNotEmpty;
    if (!isOwned) return;
    try {
      await cache.prependStopRecoveryAndFlush(
        agent.id,
        recovery.sessionId,
        stopRequestId: recovery.stopRequestId,
        texts: recovery.inputs.map((input) => input.text),
      );
    } catch (_) {
      return;
    }
    await conversationRepository.acknowledgeStopRecovery(
      agent,
      sessionId: recovery.sessionId,
      stopRequestId: recovery.stopRequestId,
      claimantId: recovery.recoveryReason == 'daemon_restart' ? recovery.claimedBy : null,
      recoveryOwnerToken: recovery.recoveryReason == 'user_stop' ? recoveryOwnerToken : null,
    );
    _initiatedStopRequestIds.remove(recovery.stopRequestId);
    _stopRecoveryClaimIds.remove(recovery.stopRequestId);
    try {
      await cache.clearStopRecoveryClaimAndFlush(
        agent.id,
        recovery.sessionId,
        recovery.stopRequestId,
      );
    } catch (_) {}
    if (recovery.recoveryReason == 'user_stop') {
      try {
        await cache.clearStopRecoveryOwnerTokenAndFlush(
          agent.id,
          recovery.sessionId,
          recovery.stopRequestId,
        );
      } catch (_) {}
    }
  }

  Future<TurnReplayResult> replayTurn({
    required String targetRequestId,
    required TurnReplayAction action,
    String? message,
    bool confirmedReplayUnsafe = false,
  }) async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) {
      return const TurnReplayResult(
        outcome: 'missing_session',
        safety: TurnReplaySafety.unknown,
        requiresConfirmation: false,
      );
    }
    return conversationRepository.replayTurn(
      agent,
      sessionId: sessionId,
      targetRequestId: targetRequestId,
      action: action,
      message: message,
      providerInstanceId: state.nextMessageProviderId,
      modelId: state.nextMessageModel,
      thinkingMode: state.nextMessageThinkingMode,
      confirmedReplayUnsafe: confirmedReplayUnsafe,
    );
  }

  Future<void> retryRuntimeNotice() async {
    final agent = _currentAgent;
    final notice = state.runtimeNotice;
    if (agent == null || notice == null) {
      return;
    }
    final providerId = state.nextMessageProviderId?.trim();
    final modelId = state.nextMessageModel?.trim();
    await conversationRepository.retryRuntimeNotice(
      agent,
      sessionId: notice.sessionId,
      requestId: notice.requestId,
      providerInstanceId: providerId == null || providerId.isEmpty ? null : providerId,
      modelId: modelId == null || modelId.isEmpty ? null : modelId,
    );
  }

  Future<void> continueWithProvider({
    required String providerInstanceId,
    String? modelId,
  }) async {
    final agent = _currentAgent;
    final notice = state.runtimeNotice;
    if (agent == null || notice == null) {
      return;
    }
    _setPendingRouteSelection(
      sessionId: notice.sessionId,
      providerId: providerInstanceId,
      modelId: modelId,
    );
    emit(
      state.copyWith(
        activeSessionId: notice.sessionId,
        pendingNextMessageProviderId: providerInstanceId,
        pendingNextMessageModel: modelId?.trim().isEmpty ?? true ? state.pendingNextMessageModel : modelId!.trim(),
      ),
    );
    await conversationRepository.continueWithProvider(
      agent,
      sessionId: notice.sessionId,
      providerInstanceId: providerInstanceId,
      requestId: notice.requestId,
      modelId: modelId?.trim().isEmpty ?? true ? null : modelId!.trim(),
    );
  }

  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) async {
    final agent = _currentAgent;
    if (agent == null) return;
    try {
      await conversationRepository.respondToSuspendedRequest(
        agent,
        request,
        allow: allow,
        scope: scope,
        comment: comment,
        answer: answer,
      );
      emit(
        state.copyWith(
          clearPendingSuspendedRequest: true,
        ),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

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
      await conversationRepository.updateSessionPreferences(
        agent,
        sessionId: sessionId,
        providerId: providerId,
        model: model,
        thinkingMode: thinkingMode,
      );

      // Persist these as the last selected values for this agent
      if (thinkingMode != null) {
        _nextMessageThinkingByAgentId[agent.id] = thinkingMode;
        unawaited(preferencesRepository.setLastThinkingMode(agent.id, thinkingMode));
      }

      emit(
        state.copyWith(
          nextMessageProviderId: _nextMessageProviderByAgentId[agent.id],
          nextMessageModel: _nextMessageModelByAgentId[agent.id],
          nextMessageThinkingMode: _nextMessageThinkingByAgentId[agent.id],
        ),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
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
    replace(_nextMessageThinkingByAgentId, thinkingMode);
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
          _nextMessageThinkingByAgentId.remove(agent.id);
        } else {
          _nextMessageThinkingByAgentId[agent.id] = trimmedThinkingMode;
          unawaited(preferencesRepository.setLastThinkingMode(agent.id, trimmedThinkingMode));
        }
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
        _nextMessageThinkingByAgentId.remove(agent.id);
      } else {
        _nextMessageThinkingByAgentId[agent.id] = trimmedThinkingMode;
        unawaited(preferencesRepository.setLastThinkingMode(agent.id, trimmedThinkingMode));
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
        availableWorkspaces: agent == null ? const [] : _workspacesByAgentId[agent.id] ?? const [],
        selectedWorkspace: agent == null ? null : _selectedWorkspaceForAgent(agent),
        isLoadingWorkspaces: agent != null && _loadingWorkspaceAgentIds.contains(agent.id),
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
      return;
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
    replace(_nextMessageThinkingByAgentId, session?.thinkingMode);
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
    if (agent == null || session == null || session.deviceId != agent.id) {
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

  Future<void> refreshWorkspaces() async {
    final agent = _currentAgent;
    if (agent == null) return;
    await _ensureWorkspacesForAgent(agent, force: true);
  }

  Future<SessionCompactResult> compactSession() async {
    final agent = _currentAgent;
    final sessionId = state.activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) {
      return const SessionCompactResult(outcome: 'missing_session');
    }
    return conversationRepository.compactSession(
      agent,
      sessionId: sessionId,
    );
  }

  Future<List<SlashCommandEntry>> searchSlashCommands({String? query}) async {
    final agent = _currentAgent;
    if (agent == null) {
      return const [];
    }

    return conversationRepository.searchSlashCommands(
      agent,
      query: query,
      workspaceId: _selectedWorkspaceForAgent(agent)?.id,
    );
  }

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({String? path}) async {
    final agent = _currentAgent;
    if (agent == null) {
      throw StateError('No active agent selected.');
    }

    return conversationRepository.browseWorkspaceTree(
      agent,
      path: path,
    );
  }

  void selectWorkspace(DeviceWorkspace workspace) {
    final agent = _currentAgent;
    if (agent == null) return;
    _selectedWorkspaceByAgentId[agent.id] = workspace;
    workspaceRuntimeContext?.setActiveWorkspace(workspace);
    unawaited(_loadPermissionModeForWorkspace(workspace));
    unawaited(_registerToolsForWorkspace(agent, workspace.id));
    emit(
      state.copyWith(
        selectedWorkspace: workspace,
        availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
        isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
        requiresWorkspace: _requiresWorkspace(agent),
        permissionMode: _permissionModeForWorkspace(workspace),
        isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(workspace),
        error: null,
      ),
    );
  }

  void clearWorkspace() {
    final agent = _currentAgent;
    if (agent == null) return;
    _selectedWorkspaceByAgentId.remove(agent.id);
    workspaceRuntimeContext?.setActiveWorkspace(null);
    emit(
      state.copyWith(
        clearSelectedWorkspace: true,
        availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
        isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
        requiresWorkspace: _requiresWorkspace(agent),
        permissionMode: WorkspacePermissionMode.defaultMode,
        isLoadingPermissionMode: false,
        error: null,
      ),
    );
  }

  Future<DeviceWorkspace?> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) async {
    final agent = _currentAgent;
    if (agent == null) return null;

    try {
      final workspace = conversationCacheRepository == null
          ? await conversationRepository.createWorkspace(
              agent,
              path: path,
              name: name,
              description: description,
            )
          : await conversationCacheRepository!.createWorkspace(
              agent,
              path: path,
              name: name,
              description: description,
            );
      if (workspace == null) return null;
      final currentList = List<DeviceWorkspace>.from(_workspacesByAgentId[agent.id] ?? const []);
      currentList.removeWhere((item) => item.id == workspace.id);
      currentList.insert(0, workspace);
      _workspacesByAgentId[agent.id] = currentList;
      _selectedWorkspaceByAgentId[agent.id] = workspace;
      workspaceRuntimeContext?.setActiveWorkspace(workspace);
      unawaited(_loadPermissionModeForWorkspace(workspace));
      unawaited(_registerToolsForWorkspace(agent, workspace.id));
      emit(
        state.copyWith(
          availableWorkspaces: currentList,
          selectedWorkspace: workspace,
          isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
          requiresWorkspace: _requiresWorkspace(agent),
          permissionMode: _permissionModeForWorkspace(workspace),
          isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(workspace),
          error: null,
        ),
      );
      return workspace;
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return null;
    }
  }

  Future<void> _ensureWorkspacesForAgent(DeviceConfig agent, {bool force = false}) async {
    final caps = capabilitiesStore != null ? await capabilitiesStore!.ensureFreshForAgent(agent, force: force) : null;
    final supportsWorkspaceFlow = (caps?.supportsWorkspaces ?? false) || (caps?.workspaceRequired ?? false);
    if (!supportsWorkspaceFlow) {
      _workspacesByAgentId.remove(agent.id);
      _selectedWorkspaceByAgentId.remove(agent.id);
      if (_currentAgent?.id == agent.id) {
        emit(
          state.copyWith(
            availableWorkspaces: const [],
            clearSelectedWorkspace: true,
            isLoadingWorkspaces: false,
            requiresWorkspace: false,
            permissionMode: WorkspacePermissionMode.defaultMode,
            isLoadingPermissionMode: false,
          ),
        );
      }
      return;
    }

    if (_workspacesByAgentId.containsKey(agent.id) && !force) {
      if (_currentAgent?.id == agent.id) {
        emit(
          state.copyWith(
            availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
            selectedWorkspace: _selectedWorkspaceForAgent(agent),
            isLoadingWorkspaces: false,
            requiresWorkspace: _requiresWorkspace(agent),
            permissionMode: _permissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
            isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
          ),
        );
      }
      return;
    }

    _loadingWorkspaceAgentIds.add(agent.id);
    if (_currentAgent?.id == agent.id) {
      emit(state.copyWith(isLoadingWorkspaces: true, requiresWorkspace: _requiresWorkspace(agent)));
    }

    try {
      final workspaces = await conversationRepository.getWorkspaces(agent);
      _workspacesByAgentId[agent.id] = workspaces;
      final selectedWorkspace = _selectedWorkspaceByAgentId[agent.id];
      if (selectedWorkspace != null) {
        for (final workspace in workspaces) {
          if (workspace.id == selectedWorkspace.id) {
            _selectedWorkspaceByAgentId[agent.id] = workspace;
            break;
          }
        }
      }
    } catch (e) {
      if (_currentAgent?.id == agent.id) {
        emit(state.copyWith(error: e.toString()));
      }
    } finally {
      _loadingWorkspaceAgentIds.remove(agent.id);
      if (_currentAgent?.id == agent.id) {
        emit(
          state.copyWith(
            availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
            selectedWorkspace: _selectedWorkspaceForAgent(agent),
            isLoadingWorkspaces: false,
            requiresWorkspace: _requiresWorkspace(agent),
            permissionMode: _permissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
            isLoadingPermissionMode: _isLoadingPermissionModeForWorkspace(_selectedWorkspaceForAgent(agent)),
          ),
        );
      }
    }
  }

  Future<void> setWorkspacePermissionMode(WorkspacePermissionMode permissionMode) async {
    final agent = _currentAgent;
    final workspace = agent == null ? null : _selectedWorkspaceForAgent(agent);
    if (workspace == null || workspace.path.trim().isEmpty) {
      emit(state.copyWith(error: 'Select a workspace before changing its permission mode.'));
      return;
    }

    _workspacePolicyLoadIds[workspace.id] = (_workspacePolicyLoadIds[workspace.id] ?? 0) + 1;
    emit(state.copyWith(isLoadingPermissionMode: true));
    try {
      final updatedPolicy = await conversationRepository.setWorkspacePermissionMode(
        agent!,
        workspaceId: workspace.id,
        workspacePath: workspace.path,
        mode: permissionMode,
      );
      _permissionModesByWorkspaceId[workspace.id] = updatedPolicy.permissionMode;
      emit(
        state.copyWith(
          selectedWorkspace: workspace,
          permissionMode: updatedPolicy.permissionMode,
          isLoadingPermissionMode: false,
          error: null,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          isLoadingPermissionMode: false,
          error: e.toString(),
        ),
      );
    }
  }

  DeviceWorkspace? _selectedWorkspaceForAgent(DeviceConfig agent) {
    final selectedSession = sessionCubit.state.selectedSession;
    if (selectedSession?.deviceId == agent.id) {
      final sessionWorkspace = _workspaceFromSession(selectedSession);
      if (sessionWorkspace != null) {
        return sessionWorkspace;
      }
    }
    return _selectedWorkspaceByAgentId[agent.id];
  }

  DeviceWorkspace? _workspaceFromSession(Session? session) {
    final workspaceId = session?.workspaceId?.trim();
    if (workspaceId == null || workspaceId.isEmpty) {
      return null;
    }
    for (final workspaces in _workspacesByAgentId.values) {
      for (final workspace in workspaces) {
        if (workspace.id == workspaceId) return workspace;
      }
    }
    return DeviceWorkspace(
      id: workspaceId,
      name: session?.workspaceName?.trim().isNotEmpty == true ? session!.workspaceName!.trim() : workspaceId,
      path: session?.workspacePath?.trim() ?? '',
      trustState: session?.workspaceTrustState?.trim().isNotEmpty == true
          ? session!.workspaceTrustState!.trim()
          : 'untrusted',
    );
  }

  bool _requiresWorkspace(DeviceConfig agent) {
    final caps = capabilitiesStore?.getForAgent(agent.id);
    return caps?.workspaceRequired ?? false;
  }

  WorkspacePermissionMode _permissionModeForWorkspace(DeviceWorkspace? workspace) {
    if (workspace == null) {
      return WorkspacePermissionMode.defaultMode;
    }
    return _permissionModesByWorkspaceId[workspace.id] ?? WorkspacePermissionMode.defaultMode;
  }

  bool _isLoadingPermissionModeForWorkspace(DeviceWorkspace? workspace) {
    if (workspace == null) {
      return false;
    }
    return _loadingPermissionModeWorkspaceIds.contains(workspace.id);
  }

  Future<void> _loadPermissionModeForWorkspace(DeviceWorkspace workspace) async {
    final workspaceId = workspace.id.trim();
    final workspacePath = workspace.path.trim();
    if (workspaceId.isEmpty || workspacePath.isEmpty) {
      return;
    }

    final loadId = (_workspacePolicyLoadIds[workspaceId] ?? 0) + 1;
    _workspacePolicyLoadIds[workspaceId] = loadId;

    _loadingPermissionModeWorkspaceIds.add(workspaceId);
    if (!isClosed && _currentAgent != null && _selectedWorkspaceForAgent(_currentAgent!)?.id == workspaceId) {
      emit(state.copyWith(isLoadingPermissionMode: true));
    }

    unawaited(_workspacePolicySubscription?.cancel());
    final agent = _currentAgent;
    if (agent != null) {
      _workspacePolicySubscription = conversationRepository.watchWorkspacePolicy(agent, workspaceId).listen((policy) {
        _permissionModesByWorkspaceId[workspaceId] = policy.permissionMode;
        if (!isClosed && _currentAgent?.id == agent.id && _selectedWorkspaceForAgent(agent)?.id == workspaceId) {
          emit(state.copyWith(permissionMode: policy.permissionMode));
        }
      });
    }

    try {
      final policy = await conversationRepository.getWorkspacePolicy(agent!, workspacePath);
      if (_workspacePolicyLoadIds[workspaceId] == loadId) {
        _permissionModesByWorkspaceId[workspaceId] = policy.permissionMode;
      }
    } catch (e) {
      if (!isClosed && _currentAgent != null && _selectedWorkspaceForAgent(_currentAgent!)?.id == workspaceId) {
        emit(state.copyWith(error: e.toString()));
      }
    } finally {
      _loadingPermissionModeWorkspaceIds.remove(workspaceId);
      if (!isClosed && _currentAgent != null && _selectedWorkspaceForAgent(_currentAgent!)?.id == workspaceId) {
        emit(
          state.copyWith(
            permissionMode: _permissionModeForWorkspace(workspace),
            isLoadingPermissionMode: false,
          ),
        );
      }
    }
  }

  Future<void> _registerToolsForWorkspace(DeviceConfig agent, String workspaceId) async {
    if (workspaceId.trim().isEmpty) return;
    await localToolRuntime?.broadcastAvailableTools(
      workspaceId: workspaceId,
    );
  }

  @override
  Future<void> close() async {
    _delayedLoadingTimer?.cancel();
    await _agentStateSubscription?.cancel();
    await _cacheSubscription?.cancel();
    await _sessionStateSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _queuedMessagesSubscription?.cancel();
    await _stopRecoverySubscription?.cancel();
    await _attentionSubscription?.cancel();
    await _workspacePolicySubscription?.cancel();
    return super.close();
  }
}
