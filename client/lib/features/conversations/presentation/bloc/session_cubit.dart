import 'package:logging/logging.dart';
import 'dart:async';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/core/interfaces/socket_service.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/processing_store.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'session_state.dart';

typedef DeletedSessionIdentity = ({String deviceId, String sessionId});

class SessionCubit extends Cubit<SessionState> {
  static final _logger = Logger('SessionCubit');

  final DeviceCubit agentCubit;
  final ISocketService socketService;
  final ConversationRepository conversationRepository;
  final ProcessingStore processingStore;
  final ConversationCacheRepository? conversationCacheRepository;
  final DeviceConnectionCoordinator? connectionCoordinator;
  final ConversationHistoryController historyController;

  final Map<String, StreamSubscription> _sessionsSubscriptions = {};
  final Map<String, StreamSubscription> _sessionCreatedSubscriptions = {};
  final Map<String, StreamSubscription> _processingSubscriptions = {};
  final Map<String, StreamSubscription> _attentionSubscriptions = {};
  final Map<String, StreamSubscription> _routeSubscriptions = {};
  late final bool _ownsProcessingStore;
  StreamSubscription? _agentStateSubscription;
  StreamSubscription<DeviceConversationCacheSnapshot>? _cacheSubscription;
  final List<StreamSubscription> _globalEventSubscriptions = [];
  String? _newConversationDeviceId;
  String? _newConversationWorkspaceId;
  final StreamController<DeletedSessionIdentity> _deletedSessionsController =
      StreamController<DeletedSessionIdentity>.broadcast();

  Stream<DeletedSessionIdentity> get deletedSessions => _deletedSessionsController.stream;

  SessionCubit({
    required this.agentCubit,
    required this.socketService,
    required this.conversationRepository,
    ConversationHistoryController? historyController,
    ProcessingStore? processingStore,
    this.conversationCacheRepository,
    this.connectionCoordinator,
  }) : historyController = historyController ?? ConversationHistoryController(),
       processingStore = processingStore ?? ProcessingStore(),
       super(const SessionState()) {
    _ownsProcessingStore = processingStore == null;
    _cacheSubscription = conversationCacheRepository?.snapshotStream.listen(
      _onCacheSnapshot,
    );
    if (conversationCacheRepository != null) {
      _onCacheSnapshot(conversationCacheRepository!.snapshot);
    }
    _agentStateSubscription = agentCubit.stream.listen(_onDeviceStateChanged);
    _listenToGlobalSessionEvents();
    _onDeviceStateChanged(agentCubit.state);
  }

  void _onDeviceStateChanged(DeviceState agentState) {
    if (agentState is AgentInitial || agentState is DeviceLoading || agentState is AgentError) {
      return;
    }
    final agents = _agentsFrom(agentState);
    if (agents.isEmpty) {
      _resetForEmptyAgents();
      return;
    }

    _retainProcessingForAgents(agents);
    final activeAgent = agentState is DeviceActive ? agentState.activeAgent : null;
    // A non-empty DeviceNoActive state is transitional while a persisted
    // identity resolves. Keep the last cache slice visible until replacement.
    if (activeAgent != null) {
      conversationCacheRepository?.selectDevice(activeAgent.id);
    }
    if (activeAgent != null && _canRefreshConversations(activeAgent)) {
      unawaited(conversationCacheRepository?.refreshDeviceSidebar(activeAgent));
    }
    _listenToClientSessionStreams(agentState);
  }

  void _resetForEmptyAgents() {
    processingStore.clear();
    _cancelClientSessionSubscriptions();
    emit(const SessionState());
  }

  void _retainProcessingForAgents(List<DeviceConfig> agents) {
    final liveAgentIds = agents.map((agent) => agent.id).toSet();
    processingStore.retainAgents(liveAgentIds);
    _emitProcessingFromStore();
  }

  void _listenToGlobalSessionEvents() {
    for (final subscription in _globalEventSubscriptions) {
      unawaited(subscription.cancel());
    }
    _globalEventSubscriptions.clear();

    final sources = <Stream<Map<String, dynamic>>>[
      socketService.events,
      if (connectionCoordinator != null) ...[
        ...connectionCoordinator!.eventStreams,
      ],
    ];

    final seenStreams = <Stream<Map<String, dynamic>>>{};
    for (final source in sources) {
      if (!seenStreams.add(source)) {
        continue;
      }
      _globalEventSubscriptions.add(source.listen(_handleGlobalSessionEvent));
    }
  }

  @visibleForTesting
  void handleGlobalSessionEventForTesting(Map<String, dynamic> event) => _handleGlobalSessionEvent(event);

  void _handleGlobalSessionEvent(Map<String, dynamic> event) {
    final eventName = event['event'] as String?;
    final deviceId = event['device_id'] as String?;
    final payload = event['payload'];

    if (deviceId == null || payload is! Map<String, dynamic>) return;

    if (eventName == 'session_created') {
      final session = _normalizeSessionForAgentId(
        deviceId,
        Session.fromJson(payload),
      );
      if (conversationCacheRepository != null) {
        conversationCacheRepository!.applySessionCreated(deviceId, session);
        final newDraft = conversationCacheRepository!.newConversationDraft(
          deviceId,
        );
        final eventRequestId = payload['request_id']?.toString();
        if (newDraft.pendingRequestId != null &&
            (eventRequestId == null || eventRequestId == newDraft.pendingRequestId)) {
          conversationCacheRepository!.transferNewConversationDraftToSession(
            deviceId,
            session.id,
          );
        }
      } else {
        _onSessionCreated(deviceId, session);
      }
    } else if (eventName == 'session_updated') {
      final sessionId = payload['session_id'] as String?;
      if (sessionId != null) {
        _onSessionUpdated(deviceId, sessionId, payload);
      }
    } else if (eventName == 'session_deleted') {
      final sessionId = payload['session_id'] as String?;
      if (sessionId != null) _onSessionDeleted(deviceId, sessionId);
    } else if (eventName == 'user_message' || eventName == 'session.pending_steer_changed') {
      final sessionId = payload['session_id'] as String? ?? event['session_id'] as String?;
      final pendingSteerState = payload['state']?.toString();
      final isAcceptedPendingSteer =
          eventName == 'session.pending_steer_changed' &&
          (pendingSteerState == 'pending' || pendingSteerState == 'delivering' || pendingSteerState == 'delivered');
      if (sessionId != null && (eventName == 'user_message' || isAcceptedPendingSteer)) {
        conversationCacheRepository?.applyUserMessageAccepted(
          deviceId,
          sessionId,
          timestamp: _eventTimestamp(payload) ?? _eventTimestamp(event),
          requestId: payload['request_id']?.toString(),
        );
      }
    }
  }

  void _listenToClientSessionStreams(DeviceState agentState) {
    _cancelClientSessionSubscriptions();

    final agents = _agentsFrom(agentState);
    final activeAgent = agentState is DeviceActive ? agentState.activeAgent : null;

    for (final agent in agents) {
      if (activeAgent?.id != agent.id || agentState is! DeviceActive) continue;

      unawaited(_sessionsSubscriptions[agent.id]?.cancel());
      if (conversationCacheRepository == null) {
        _sessionsSubscriptions[agent.id] = conversationRepository.watchSessions(agent).listen((sessions) {
          final nextSessions = Map<String, List<Session>>.from(state.agentSessions);
          final normalizedSessions = _normalizeSessionsForAgent(agent, sessions);
          nextSessions[agent.id] = normalizedSessions;
          final refreshed = _refreshSelectedSessionFromLists(
            nextSessions,
            fallback: state.selectedSession,
          );
          emit(
            state.copyWith(
              agentSessions: nextSessions,
              selectedSession: refreshed,
              clearSelectedSession: refreshed == null && state.selectedSession != null,
            ),
          );
        });

        _sessionCreatedSubscriptions[agent.id] = conversationRepository.watchSessionCreated(agent).listen((session) {
          _onSessionCreated(agent.id, _normalizeSessionForAgent(agent, session));
        });
      }

      unawaited(_processingSubscriptions[agent.id]?.cancel());
      _processingSubscriptions[agent.id] = conversationRepository.watchProcessing(agent).listen((snapshot) {
        processingStore.setSnapshot(agent.id, snapshot);
        _emitProcessingFromStore();
      });
      unawaited(_attentionSubscriptions[agent.id]?.cancel());
      _attentionSubscriptions[agent.id] = conversationRepository
          .watchAttentionStates(agent)
          .listen((attention) => _applyAttentionStates(agent.id, attention));
      unawaited(_routeSubscriptions[agent.id]?.cancel());
      _routeSubscriptions[agent.id] = conversationRepository
          .watchRouteSnapshots(agent)
          .listen((routes) => _applyRouteSnapshots(agent.id, routes));
    }
  }

  void _cancelClientSessionSubscriptions() {
    for (final subscription in _sessionsSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _sessionCreatedSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _processingSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _attentionSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _routeSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _sessionsSubscriptions.clear();
    _sessionCreatedSubscriptions.clear();
    _processingSubscriptions.clear();
    _attentionSubscriptions.clear();
    _routeSubscriptions.clear();
  }

  Future<void> refreshSessions() async {
    final agentState = agentCubit.state;
    final activeAgent = agentState is DeviceActive ? agentState.activeAgent : null;
    if (activeAgent == null || !_canRefreshConversations(activeAgent)) {
      return;
    }

    _setDeviceLoading(activeAgent.id, true);
    try {
      if (conversationCacheRepository != null) {
        await conversationCacheRepository!.refreshDeviceSidebar(activeAgent);
      } else {
        await conversationRepository.refreshSessions(activeAgent);
      }
    } catch (e) {
      _logger.severe('[SessionCubit] Error refreshing sessions for ${activeAgent.name}: $e');
      emit(state.copyWith(error: e.toString()));
    } finally {
      _setDeviceLoading(activeAgent.id, false);
    }
  }

  Future<void> selectSession(Session session) async {
    final agents = _agentsFrom(agentCubit.state);
    final activeAgent = agentCubit.state is DeviceActive ? (agentCubit.state as DeviceActive).activeAgent : null;
    final agent = agents.where((a) => a.id == session.deviceId).firstOrNull ?? _agentForSessionType(agents, session);

    final resolvedSession = _resolveSessionSelection(agent, session);
    _clearNewConversationPresentation();
    if (agent != null) {
      conversationCacheRepository?.recordLastDestination(
        ConversationDestination.session(
          deviceId: agent.id,
          sessionId: resolvedSession.id,
        ),
      );
    }
    emit(state.copyWith(selectedSession: resolvedSession));

    historyController.navigateTo(
      ConversationDestination.session(
        deviceId: resolvedSession.deviceId ?? agent?.id ?? '',
        sessionId: resolvedSession.id,
      ),
    );

    // SessionMessagesCubit owns activation through loadSessionHistory. Emit
    // the requested selection first so its atomic-swap gate is installed
    // before the target store can publish messages.
    if (agent != null && activeAgent?.id != agent.id) {
      await agentCubit.switchAgent(agent);
    }
  }

  /// Synchronously marks [session] as the selected session in this cubit's
  /// state, without switching agents or re-activating the session in the
  /// repository. Used by [SessionMessagesCubit] right after it locally creates
  /// a session, so that downstream stream listeners (whose
  /// `_selectedSessionBelongsToCurrentClient` check reads
  /// `SessionCubit.state.selectedSession`) do not clear their own
  /// `activeSessionId` before the remote `session_created` event arrives.
  void markSessionSelectedSync(Session session) {
    if (state.selectedSession?.id == session.id) return;
    _clearNewConversationPresentation();
    final deviceId = session.deviceId;
    if (deviceId != null) {
      conversationCacheRepository?.recordLastDestination(
        ConversationDestination.session(
          deviceId: deviceId,
          sessionId: session.id,
        ),
      );
    }
    emit(state.copyWith(selectedSession: session));
  }

  void transferNewConversationDraftToSession(
    String deviceId,
    String sessionId,
  ) {
    conversationCacheRepository?.transferNewConversationDraftToSession(
      deviceId,
      sessionId,
    );
  }

  void markSessionDraftAwaitingAcceptance(
    String deviceId,
    String sessionId,
    String requestId,
  ) {
    conversationCacheRepository?.markSessionDraftAwaitingAcceptance(
      deviceId,
      sessionId,
      requestId,
    );
  }

  void markNewConversationDraftAwaitingAcceptance(
    String deviceId,
    String requestId,
  ) {
    conversationCacheRepository?.markNewConversationDraftAwaitingAcceptance(
      deviceId,
      requestId,
    );
  }

  Session _resolveSessionSelection(DeviceConfig? agent, Session session) {
    if (agent == null) {
      return session;
    }

    final normalizedInput = _normalizeSessionForAgent(agent, session);
    final sessionsForAgent = state.agentSessions[agent.id] ?? const <Session>[];
    final matched = sessionsForAgent.where((item) => item.id == normalizedInput.id).firstOrNull;
    return matched ?? normalizedInput;
  }

  Session? _refreshSelectedSessionFromLists(
    Map<String, List<Session>> sessionsByAgent, {
    Session? fallback,
  }) {
    final current = fallback;
    if (current == null) {
      return null;
    }

    final deviceId = current.deviceId;
    if (deviceId == null) {
      return current;
    }

    final agentSessions = sessionsByAgent[deviceId] ?? const <Session>[];
    final matched = agentSessions.where((session) => session.id == current.id).firstOrNull;
    if (matched != null) return matched;

    // Snapshot absence is not proof of deletion: reconnect and transport
    // handoff can briefly return an incomplete list. Explicit
    // `session_deleted` events own removal of a selected persisted session.
    return current;
  }

  Future<void> startNewChat(DeviceConfig agent, {String? workspaceId}) async {
    final activeAgent = agentCubit.state is DeviceActive ? (agentCubit.state as DeviceActive).activeAgent : null;
    if (activeAgent?.id != agent.id) {
      await agentCubit.switchAgent(agent);
    }

    final cacheRepository = conversationCacheRepository;
    final selectedSession = state.selectedSession;
    final previousSession = selectedSession?.deviceId == agent.id
        ? selectedSession
        : cacheRepository?.lastSelectedSession(agent.id);
    final requestedWorkspaceId = workspaceId?.trim();
    final restoredWorkspaceId = previousSession?.workspaceId?.trim();
    final canRestoreWorkspace =
        restoredWorkspaceId?.isNotEmpty == true &&
        cacheRepository?.containsWorkspace(agent.id, restoredWorkspaceId!) == true;
    final targetWorkspaceId = requestedWorkspaceId?.isNotEmpty == true
        ? requestedWorkspaceId
        : canRestoreWorkspace
        ? restoredWorkspaceId
        : null;

    final destination = ConversationDestination.newConversation(
      deviceId: agent.id,
      workspaceId: targetWorkspaceId,
    );
    if (_newConversationDeviceId == agent.id &&
        _newConversationWorkspaceId == targetWorkspaceId &&
        state.selectedSession == null) {
      historyController.navigateTo(destination);
      return;
    }

    // Persist the typed destination immediately. This prevents restart
    // recovery from treating the previous session as the current route.
    cacheRepository?.recordLastDestination(destination);

    // Keep the persisted last-selected session as the source for restoring
    // new-conversation context, but mark presentation ownership before the
    // draft update emits a cache snapshot. Otherwise that snapshot is
    // mistaken for startup hydration and re-selects the previous session.
    _newConversationDeviceId = agent.id;
    _newConversationWorkspaceId = targetWorkspaceId;
    conversationRepository.beginNewSession(agent);
    cacheRepository?.setNewConversationDraft(
      agent.id,
      workspaceId: targetWorkspaceId,
      providerId: previousSession?.modelProvider,
      model: previousSession?.model,
      thinkingMode: previousSession?.thinkingMode,
      clearWorkspace: targetWorkspaceId == null,
      clearProvider: previousSession?.modelProvider?.trim().isNotEmpty != true,
      clearModel: previousSession?.model?.trim().isNotEmpty != true,
      clearThinkingMode: previousSession?.thinkingMode?.trim().isNotEmpty != true,
      clearPermissionMode: true,
    );
    emit(state.copyWith(clearSelectedSession: true));

    historyController.navigateTo(destination);
  }

  void _clearNewConversationPresentation() {
    _newConversationDeviceId = null;
    _newConversationWorkspaceId = null;
  }

  Future<void> updateSessionTitle({
    required DeviceConfig agent,
    required Session session,
    required String title,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return;
    await conversationRepository.updateSessionTitle(agent, session.id, trimmedTitle);
  }

  void _handleDeletionFallback(
    String deviceId,
    String sessionId, {
    required bool isCurrent,
  }) {
    if (!isCurrent) {
      historyController.removeSessionFromHistory(deviceId, sessionId);
      return;
    }

    historyController.removeSessionFromHistory(deviceId, sessionId);
    bool isValidFallback(ConversationDestination destination) {
      if (destination.isNewConversation) return true;
      if (!destination.isSession || destination.sessionId == null) return false;
      return (state.agentSessions[deviceId] ?? const <Session>[]).any(
        (session) => session.id == destination.sessionId && session.id != sessionId,
      );
    }

    final fallback =
        historyController.takePreviousSameDevice(
          deviceId,
          isValid: isValidFallback,
        ) ??
        historyController.takeForwardSameDevice(
          deviceId,
          isValid: isValidFallback,
        ) ??
        ConversationDestination.newConversation(deviceId: deviceId);
    historyController.replaceCurrent(fallback);

    if (fallback.isNewConversation) {
      final agents = _agentsFrom(agentCubit.state);
      final agent = agents.where((candidate) => candidate.id == deviceId).firstOrNull;
      if (agent != null) {
        conversationRepository.beginNewSession(agent);
      }
      conversationCacheRepository?.recordLastDestination(fallback);
      emit(state.copyWith(clearSelectedSession: true));
    } else {
      unawaited(_selectFallbackSession(fallback));
    }
  }

  Future<void> _selectFallbackSession(ConversationDestination fallback) async {
    final agents = _agentsFrom(agentCubit.state);
    final activeAgent = agentCubit.state is DeviceActive ? (agentCubit.state as DeviceActive).activeAgent : null;
    final agent = agents.where((a) => a.id == fallback.deviceId).firstOrNull;

    if (agent != null && activeAgent?.id != agent.id) {
      await agentCubit.switchAgent(agent);
    }

    final sessionsForAgent = state.agentSessions[fallback.deviceId] ?? [];
    var fallbackSession = sessionsForAgent.where((s) => s.id == fallback.sessionId).firstOrNull;
    fallbackSession ??= Session(
      id: fallback.sessionId!,
      title: 'Loading...',
      deviceId: fallback.deviceId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    if (agent != null) {
      conversationCacheRepository?.recordLastDestination(
        ConversationDestination.session(
          deviceId: agent.id,
          sessionId: fallbackSession.id,
        ),
      );
    }
    emit(state.copyWith(selectedSession: fallbackSession));
  }

  Future<void> deleteSession({
    required DeviceConfig agent,
    required Session session,
  }) async {
    await conversationRepository.deleteSession(agent, session.id);
    conversationCacheRepository?.applySessionDeleted(agent.id, session.id);
    _deletedSessionsController.add((deviceId: agent.id, sessionId: session.id));
    _handleDeletionFallback(
      agent.id,
      session.id,
      isCurrent: state.selectedSession?.id == session.id,
    );
    await conversationRepository.refreshSessions(agent);
  }

  void _onSessionCreated(String deviceId, Session session) {
    final nextSessions = Map<String, List<Session>>.from(state.agentSessions);
    final list = List<Session>.from(nextSessions[deviceId] ?? []);

    final selectedSession = state.selectedSession;
    final replacedTemp = selectedSession != null && selectedSession.id.isEmpty && selectedSession.deviceId == deviceId;
    if (replacedTemp) {
      list.removeWhere((t) => t.id == selectedSession.id);
    }

    final existingIndex = list.indexWhere((t) => t.id == session.id);
    if (existingIndex == -1) {
      list.insert(0, session);
    } else {
      list[existingIndex] = session;
    }

    nextSessions[deviceId] = list;
    final activeAgent = agentCubit.state is DeviceActive ? (agentCubit.state as DeviceActive).activeAgent : null;
    final shouldSelect = replacedTemp || (state.selectedSession == null && activeAgent?.id == deviceId);
    emit(state.copyWith(agentSessions: nextSessions, selectedSession: shouldSelect ? session : null));
  }

  void _onSessionUpdated(String deviceId, String sessionId, Map<String, dynamic> payload) {
    final list = conversationCacheRepository?.sessionsForDevice(deviceId) ?? state.agentSessions[deviceId];
    if (list == null) return;

    final index = list.indexWhere((session) => session.id == sessionId);
    if (index == -1) return;

    final nextSessions = Map<String, List<Session>>.from(state.agentSessions);
    final nextList = List<Session>.from(list);
    final existing = nextList[index];

    final title = payload['title'] as String?;
    final model = payload['model'] as String?;
    final modelProvider = payload['model_provider'] as String? ?? payload['provider_id'] as String?;
    final routeRevision = payload['route_revision'];
    final correctionRaw = payload['thinking_correction'];
    final hasCorrection = correctionRaw is Map;
    final hasThinkingModeKey = payload.containsKey('thinking_mode');
    final thinkingMode = hasThinkingModeKey
        ? payload['thinking_mode'] as String?
        : existing.thinkingMode;
    final thinkingControlRaw = payload['thinking_control'];

    final updated = existing.copyWith(
      title: title ?? existing.title,
      model: model ?? existing.model,
      modelProvider: modelProvider ?? existing.modelProvider,
      routeRevision: routeRevision is num ? routeRevision.toInt() : existing.routeRevision,
      thinkingMode: hasCorrection && !hasThinkingModeKey
          ? null
          : (hasThinkingModeKey ? thinkingMode : existing.thinkingMode),
      clearThinkingMode: hasCorrection && !hasThinkingModeKey,
      thinkingControl: thinkingControlRaw is Map
          ? ThinkingControlDescriptorDto.fromJson(
              Map<String, dynamic>.from(thinkingControlRaw),
            )
          : (hasCorrection ? null : existing.thinkingControl),
      clearThinkingControl: hasCorrection && thinkingControlRaw == null,
      updatedAt: DateTime.now(),
    );
    if (conversationCacheRepository != null) {
      conversationCacheRepository!.applySessionUpdated(deviceId, updated);
      return;
    }
    nextList[index] = updated;
    nextSessions[deviceId] = nextList;

    emit(
      state.copyWith(
        agentSessions: nextSessions,
        selectedSession: state.selectedSession?.id == sessionId ? updated : null,
      ),
    );
  }

  void _onSessionDeleted(String deviceId, String sessionId) {
    _deletedSessionsController.add((deviceId: deviceId, sessionId: sessionId));
    final isCurrentSession = state.selectedSession?.id == sessionId && state.selectedSession?.deviceId == deviceId;

    if (conversationCacheRepository != null) {
      conversationCacheRepository!.applySessionDeleted(deviceId, sessionId);
      _handleDeletionFallback(deviceId, sessionId, isCurrent: isCurrentSession);
      return;
    }
    final list = state.agentSessions[deviceId];
    if (list == null) return;

    final nextSessions = Map<String, List<Session>>.from(state.agentSessions);
    nextSessions[deviceId] = list.where((session) => session.id != sessionId).toList();
    emit(state.copyWith(agentSessions: nextSessions));
    _handleDeletionFallback(deviceId, sessionId, isCurrent: isCurrentSession);
  }

  void _setDeviceLoading(String deviceId, bool isLoading) {
    final nextLoading = Map<String, bool>.from(state.loadingSessions);
    nextLoading[deviceId] = isLoading;
    emit(state.copyWith(loadingSessions: nextLoading));
  }

  List<Session> _normalizeSessionsForAgent(DeviceConfig agent, List<Session> sessions) {
    final routes = conversationRepository.currentRouteSnapshots(agent);
    return sessions
        .map(
          (session) => _applyRouteToSession(
            _normalizeSessionForAgent(agent, session),
            routes[session.id],
          ),
        )
        .toList();
  }

  Session _applyRouteToSession(
    Session session,
    SessionRouteSnapshot? route,
  ) {
    if (route == null || (session.routeRevision != null && session.routeRevision! > route.routeRevision)) {
      return session;
    }
    return session.copyWith(
      model: route.model,
      modelProvider: route.providerInstanceId,
      routeRevision: route.routeRevision,
      clearThinkingControl: true,
      metadata: {
        ...?session.metadata,
        'model': route.model,
        'model_provider': route.providerInstanceId,
        'route_revision': route.routeRevision,
        if (route.providerDisplayName != null) 'provider_display_name': route.providerDisplayName,
      },
    );
  }

  Session _normalizeSessionForAgent(DeviceConfig agent, Session session) {
    if (session.deviceId == agent.id) {
      return session;
    }

    return session.copyWith(
      deviceId: session.deviceId ?? agent.id,
    );
  }

  Session _normalizeSessionForAgentId(String deviceId, Session session) {
    final agent = _agentsFrom(agentCubit.state).where((agent) => agent.id == deviceId).firstOrNull;
    if (agent == null) {
      return session.copyWith(deviceId: session.deviceId ?? deviceId);
    }
    return _normalizeSessionForAgent(agent, session);
  }

  DeviceConfig? _agentForSessionType(List<DeviceConfig> agents, Session session) {
    final matches = agents.where((agent) => agent.id == session.deviceId).toList();
    return matches.length == 1 ? matches.first : null;
  }

  void _emitProcessingFromStore() {
    final nextProcessing = processingStore.processingSessionIdsByAgentId;
    if (_processingMapsEqual(state.processingSessionIds, nextProcessing)) return;
    emit(state.copyWith(processingSessionIds: nextProcessing));
  }

  void _applyAttentionStates(
    String deviceId,
    Map<String, SessionAttentionState> attention,
  ) {
    final nextAttention = Map<String, Map<String, SessionAttentionState>>.from(
      state.attentionStates,
    );
    if (attention.isEmpty) {
      nextAttention.remove(deviceId);
    } else {
      nextAttention[deviceId] = Map.unmodifiable(attention);
    }
    final nextProcessing = Map<String, Set<String>>.from(
      state.processingSessionIds,
    );
    final executing = attention.values
        .where((entry) => entry.executionSnapshot.isExecuting)
        .map((entry) => entry.sessionId)
        .toSet();
    if (executing.isEmpty) {
      nextProcessing.remove(deviceId);
    } else {
      nextProcessing[deviceId] = executing;
    }
    final nextSuspended = Map<String, Set<String>>.from(
      state.suspendedSessionIds,
    );
    final suspended = attention.values
        .where(
          (entry) =>
              entry.pendingSuspendedRequest != null ||
              entry.visualState == SessionAttentionVisualState.blockedOrFatal ||
              entry.visualState == SessionAttentionVisualState.waiting,
        )
        .map((entry) => entry.sessionId)
        .toSet();
    if (suspended.isEmpty) {
      nextSuspended.remove(deviceId);
    } else {
      nextSuspended[deviceId] = suspended;
    }
    emit(
      state.copyWith(
        attentionStates: nextAttention,
        processingSessionIds: nextProcessing,
        suspendedSessionIds: nextSuspended,
      ),
    );
  }

  void _applyRouteSnapshots(
    String deviceId,
    Map<String, SessionRouteSnapshot> routes,
  ) {
    final nextRoutes = Map<String, Map<String, SessionRouteSnapshot>>.from(
      state.routeSnapshots,
    );
    if (routes.isEmpty) {
      nextRoutes.remove(deviceId);
    } else {
      nextRoutes[deviceId] = Map.unmodifiable(routes);
    }
    final sourceSessions =
        conversationCacheRepository?.sessionsForDevice(deviceId) ?? state.agentSessions[deviceId] ?? const <Session>[];
    final updatedSessions = sourceSessions
        .map((session) => _applyRouteToSession(session, routes[session.id]))
        .toList(growable: false);
    final nextSessions = Map<String, List<Session>>.from(state.agentSessions);
    if (updatedSessions.isNotEmpty || nextSessions.containsKey(deviceId)) {
      nextSessions[deviceId] = updatedSessions;
    }
    final selected = state.selectedSession;
    final updatedSelected = selected?.deviceId == deviceId
        ? _applyRouteToSession(selected!, routes[selected.id])
        : selected;
    emit(
      state.copyWith(
        routeSnapshots: nextRoutes,
        agentSessions: nextSessions,
        selectedSession: updatedSelected,
      ),
    );
  }

  bool _processingMapsEqual(Map<String, Set<String>> a, Map<String, Set<String>> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length || !other.containsAll(entry.value)) {
        return false;
      }
    }
    return true;
  }

  bool _canRefreshConversations(DeviceConfig agent) {
    if (!agent.isOnline) return false;
    return agent.id != DeviceInventoryIds.localDevice || agent.isLocalReachable;
  }

  List<DeviceConfig> _agentsFrom(DeviceState agentState) {
    return switch (agentState) {
      DeviceActive(agents: final agents) => agents,
      DeviceNoActive(agents: final agents) => agents,
      _ => const <DeviceConfig>[],
    };
  }

  void _onCacheSnapshot(DeviceConversationCacheSnapshot snapshot) {
    if (isClosed) return;
    final sessionsByDevice = <String, List<Session>>{
      for (final deviceId in snapshot.contexts.keys)
        deviceId: conversationCacheRepository!
            .sessionsForDevice(deviceId)
            .map(
              (session) => _applyRouteToSession(
                session,
                state.routeSnapshots[deviceId]?[session.id],
              ),
            )
            .toList(growable: false),
    };
    final activeDeviceId = snapshot.activeDeviceId;
    final lastDestination = activeDeviceId == null ? null : snapshot.contexts[activeDeviceId]?.lastDestination;
    final presentsNewConversation =
        activeDeviceId != null &&
        (_newConversationDeviceId == activeDeviceId || lastDestination == null || lastDestination.isNewConversation);
    // When the active device changed, the previously selected session belongs
    // to another device. It must not survive as the current selection:
    // keeping it would leave the new device's sidebar with no highlighted
    // conversation (its rows compare against a foreign session id) and block
    // restoring that device's last destination. Invalidate it so the fallback
    // below restores the new device's own last selected session.
    final currentSelected = state.selectedSession;
    final fallback = (currentSelected != null && activeDeviceId != null && currentSelected.deviceId != activeDeviceId)
        ? null
        : currentSelected;
    var selected = presentsNewConversation
        ? null
        : _refreshSelectedSessionFromLists(
            sessionsByDevice,
            fallback: fallback,
          );
    if (lastDestination?.isSession == true && selected == null && activeDeviceId != null) {
      final lastSessionId = lastDestination!.sessionId;
      if (lastSessionId != null) {
        selected = sessionsByDevice[activeDeviceId]?.where((session) => session.id == lastSessionId).firstOrNull;
      }
    }

    emit(
      state.copyWith(
        agentSessions: sessionsByDevice,
        selectedSession: selected,
        clearSelectedSession: selected == null && state.selectedSession != null,
      ),
    );
  }

  DateTime? _eventTimestamp(Map<String, dynamic> payload) {
    for (final key in const [
      'last_user_message_at',
      'timestamp',
      'created_at',
    ]) {
      final raw = payload[key];
      if (raw is String) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  @override
  Future<void> close() async {
    await _agentStateSubscription?.cancel();
    await _cacheSubscription?.cancel();
    for (final subscription in _globalEventSubscriptions) {
      await subscription.cancel();
    }
    _globalEventSubscriptions.clear();
    for (final subscription in _sessionsSubscriptions.values) {
      await subscription.cancel();
    }
    for (final subscription in _sessionCreatedSubscriptions.values) {
      await subscription.cancel();
    }
    for (final subscription in _processingSubscriptions.values) {
      await subscription.cancel();
    }
    for (final subscription in _attentionSubscriptions.values) {
      await subscription.cancel();
    }
    for (final subscription in _routeSubscriptions.values) {
      await subscription.cancel();
    }
    if (_ownsProcessingStore) {
      processingStore.dispose();
    }
    await _deletedSessionsController.close();
    return super.close();
  }
}
