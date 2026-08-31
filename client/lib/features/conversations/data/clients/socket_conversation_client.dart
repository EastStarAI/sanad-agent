import 'package:logging/logging.dart';
import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/data/mappers/device_event_mapper.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_commands.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_event_handler.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_request_id.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

class SocketConversationClient implements ConversationClient {
  static final _logger = Logger('SocketConversationClient');

  final DeviceConfig _config;
  final DeviceEventMapper _mapper;
  final DeviceConversationStore _store;
  final _sessionsController = StreamController<List<Session>>.broadcast();
  final _sessionCreatedController = StreamController<Session>.broadcast();
  ConversationCommandGateway? _gateway;
  ConversationCommands? _commands;
  ConversationEventHandler? _eventHandler;
  StreamSubscription<Map<String, dynamic>>? _sessionEventsSubscription;
  StreamSubscription<SocketLifecycleState>? _socketLifecycleSubscription;
  SanadSocketService? _socketService;
  List<Session>? _lastSessionsSnapshot;
  final Map<String, SessionQueryResult> _sessionQueryCache = {};
  final Map<String, Future<SessionQueryResult>> _sessionQueryRequests = {};
  bool _sessionsHydrationPending = true;
  Future<SessionQueryResult>? _defaultRefreshInFlight;
  int _defaultRefreshGeneration = 0;
  int _sessionQueryGeneration = 0;

  static const _defaultSessionQueryCacheKey = '__default__';
  static const _legacyDefaultPageSize = 100;

  SocketConversationClient({
    required DeviceConfig config,
    required SanadSocketService socketService,
    required DeviceCapabilitiesStore capabilitiesStore,
    DeviceConversationStoreSnapshot? initialStoreSnapshot,
  }) : _config = config,
       _mapper = UnifiedDeviceMapper(),
       _store = DeviceConversationStore(
         thinkingStreamMode: capabilitiesStore.getForAgent(config.id).thinkingStreamMode,
         initialSnapshot: initialStoreSnapshot,
       ) {
    _bindSocketService(socketService);
    unawaited(
      capabilitiesStore.ensureFreshForAgent(_config).then((caps) {
        _store.setThinkingStreamMode(caps.thinkingStreamMode);
      }),
    );
  }

  @override
  DeviceConfig get config => _config;

  @override
  bool get isConnected => _socketService?.isConnected ?? false;

  @override
  Stream<List<Session>> get sessions => _sessionsController.stream;

  @override
  Stream<Session> get sessionCreated => _sessionCreatedController.stream;

  @override
  Stream<DeviceProcessingSnapshot> get processing => _store.processing;

  @override
  Stream<List<CanonicalEvent>> get messages => _store.messages;

  @override
  Stream<List<CanonicalEvent>> get queuedMessages => _store.queuedMessages;

  @override
  Stream<DeviceSuspendedRequest?> get pendingSuspendedRequest => _store.pendingSuspendedRequest;

  @override
  Stream<RuntimeNotice?> get runtimeNotice => _store.runtimeNotice;

  @override
  Stream<StopDraftRecovery> get stopRecoveries => _store.stopRecoveries;

  @override
  Stream<Map<String, SessionAttentionState>> get attentionStates => _store.attentionStates;

  @override
  Stream<Map<String, SessionRouteSnapshot>> get routeSnapshots => _store.routeSnapshots;

  @override
  List<CanonicalEvent> get currentMessages => _store.currentMessages;

  @override
  List<CanonicalEvent> get currentQueuedMessages => _store.currentQueuedMessages;

  @override
  DeviceSuspendedRequest? get currentPendingSuspendedRequest => _store.currentPendingSuspendedRequest;

  @override
  RuntimeNotice? get currentRuntimeNotice => _store.currentRuntimeNotice;

  @override
  Map<String, SessionAttentionState> get currentAttentionStates => _store.currentAttentionStates;

  @override
  Map<String, SessionRouteSnapshot> get currentRouteSnapshots => _store.currentRouteSnapshots;

  DeviceConversationStoreSnapshot get storeSnapshot => _store.snapshot;

  @override
  bool get isProcessing => _store.isProcessing;

  @override
  bool get isCurrentConversationProcessing => _store.isCurrentConversationProcessing;

  @override
  bool isSessionProcessing(String? sessionId) => _store.isSessionProcessing(sessionId);

  @override
  void activateSession(String sessionId) {
    _store.activateSession(sessionId);
  }

  @override
  void beginNewSession() {
    _store.beginNewSession();
  }

  @override
  Future<Session> createSession({
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    return _commands!
        .createSession(
          title: title,
          isTitlePlaceholder: isTitlePlaceholder,
          workspaceId: workspaceId,
          providerId: providerId,
          model: model,
          thinkingMode: thinkingMode,
        )
        .then((session) {
          _invalidateSessionsSnapshot();
          return session;
        });
  }

  @override
  Future<String?> sendMessage(
    String message, {
    String? sessionId,
    String? workspaceId,
    String? context,
    String? providerId,
    String? model,
    String? thinkingMode,
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  }) {
    return _commands!.sendMessage(
      message,
      sessionId: sessionId,
      workspaceId: workspaceId,
      context: context,
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      intent: intent,
    );
  }

  @override
  Future<void> steerMessage(
    String message, {
    required String requestId,
    required String sessionId,
  }) {
    return _commands!.steerMessage(
      message,
      requestId: requestId,
      sessionId: sessionId,
    );
  }

  @override
  Future<String?> deleteQueuedMessage({required String requestId, required String sessionId}) =>
      _commands!.deleteQueuedMessage(requestId: requestId, sessionId: sessionId);

  @override
  Future<String?> cancelPendingSteer({required String requestId, required String sessionId}) =>
      _commands!.cancelPendingSteer(requestId: requestId, sessionId: sessionId);

  @override
  Future<String?> stop({
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  }) {
    return _commands!.stop(
      sessionId: sessionId,
      requestId: requestId,
      recoveryOwnerToken: recoveryOwnerToken,
    );
  }

  @override
  Future<String?> claimStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  }) => _commands!.claimStopRecovery(
    sessionId: sessionId,
    stopRequestId: stopRequestId,
    commandRequestId: commandRequestId,
  );

  @override
  Future<void> acknowledgeStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  }) => _commands!.acknowledgeStopRecovery(
    sessionId: sessionId,
    stopRequestId: stopRequestId,
    claimantId: claimantId,
    recoveryOwnerToken: recoveryOwnerToken,
  );

  @override
  Future<TurnReplayResult> replayTurn({
    required String sessionId,
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
    required TurnReplayAction action,
    String? message,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
    bool confirmedReplayUnsafe = false,
    bool confirmedDropSteers = false,
  }) => _commands!.replayTurn(
    sessionId: sessionId,
    targetRequestId: targetRequestId,
    targetMessageId: targetMessageId,
    targetTurnId: targetTurnId,
    expectedHistoryRevision: expectedHistoryRevision,
    action: action,
    message: message,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
    thinkingMode: thinkingMode,
    confirmedReplayUnsafe: confirmedReplayUnsafe,
    confirmedDropSteers: confirmedDropSteers,
  );

  @override
  Future<SessionForkResult> forkSession({
    required String sessionId,
    required String targetMessageId,
    required String targetTurnId,
  }) => _commands!.forkSession(
    sessionId: sessionId,
    targetMessageId: targetMessageId,
    targetTurnId: targetTurnId,
  );

  @override
  Future<SessionCompactResult> compactSession({
    required String sessionId,
  }) => _commands!.compactSession(sessionId: sessionId);

  @override
  Future<void> retryRuntimeNotice({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  }) {
    return _commands!.retryRuntimeNotice(
      sessionId: sessionId,
      requestId: requestId,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
    );
  }

  @override
  Future<void> continueWithProvider({
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  }) {
    return _commands!.continueWithProvider(
      sessionId: sessionId,
      providerInstanceId: providerInstanceId,
      requestId: requestId,
      modelId: modelId,
    );
  }

  @override
  Future<void> updateSessionPreferences({
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    return _commands!.updateSessionPreferences(
      sessionId: sessionId,
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
    );
  }

  @override
  Future<SessionQueryResult> getSessions({SessionQueryRequest? query}) async {
    final resolvedQuery = query;
    final queryKey = _sessionQueryCacheKeyFor(resolvedQuery);
    final isLegacyDefault = resolvedQuery == null;
    final exactCached = _sessionQueryCache[queryKey];
    if (exactCached != null && (!isLegacyDefault || !_sessionsHydrationPending)) {
      return exactCached;
    }
    if (isLegacyDefault) {
      final cached = _lastSessionsSnapshot;
      if (!_sessionsHydrationPending && cached != null) {
        return SessionQueryResult(sessions: cached, hasMore: false);
      }
    }

    if (!isConnected || _commands == null) {
      if (exactCached != null) {
        return exactCached;
      }
      return SessionQueryResult(
        sessions: isLegacyDefault ? (_lastSessionsSnapshot ?? const []) : const [],
        hasMore: false,
      );
    }

    try {
      if (isLegacyDefault) {
        return await _fetchLegacyDefaultSessions();
      }
      return await _fetchSessionQuery(
        resolvedQuery,
        queryKey: queryKey,
      );
    } catch (error) {
      _logger.severe('[SocketConversationClient] Failed to fetch sessions: $error');
      if (exactCached != null) {
        return exactCached;
      }
      if (isLegacyDefault && _lastSessionsSnapshot != null) {
        return SessionQueryResult(sessions: _lastSessionsSnapshot!, hasMore: false);
      }
      rethrow;
    }
  }

  Future<SessionQueryResult> _fetchSessionQuery(
    SessionQueryRequest query, {
    required String queryKey,
  }) {
    final inFlight = _sessionQueryRequests[queryKey];
    if (inFlight != null) {
      return inFlight;
    }

    final generation = _sessionQueryGeneration;
    final future = _commands!.getSessions(query: query).then((result) {
      if (generation == _sessionQueryGeneration) {
        _sessionQueryCache[queryKey] = result;
      }
      return result;
    });
    _sessionQueryRequests[queryKey] = future;
    return future.whenComplete(() {
      if (identical(_sessionQueryRequests[queryKey], future)) {
        final _ = _sessionQueryRequests.remove(queryKey);
      }
    });
  }

  Future<SessionQueryResult> _fetchLegacyDefaultSessions() {
    final inFlight = _defaultRefreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final generation = ++_defaultRefreshGeneration;
    final future = _fetchLegacyDefaultSessionsUncached(generation);
    _defaultRefreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_defaultRefreshInFlight, future)) {
        _defaultRefreshInFlight = null;
      }
    });
  }

  Future<SessionQueryResult> _fetchLegacyDefaultSessionsUncached(
    int generation,
  ) async {
    final allSessions = <Session>[];
    final seenIds = <String>{};
    String? cursor;

    while (true) {
      final page = await _commands!.getSessions(
        query: SessionQueryRequest(
          limit: _legacyDefaultPageSize,
          cursor: cursor,
        ),
      );
      for (final session in page.sessions) {
        if (seenIds.add(session.id)) {
          allSessions.add(session);
        }
      }
      if (!page.hasMore || page.nextCursor == null) {
        final result = SessionQueryResult(
          sessions: allSessions,
          hasMore: false,
        );
        if (generation == _defaultRefreshGeneration) {
          _lastSessionsSnapshot = allSessions;
          _sessionQueryCache[_defaultSessionQueryCacheKey] = result;
          _sessionsHydrationPending = false;
          _publishDefaultSessions(allSessions);
        }
        return result;
      }
      cursor = page.nextCursor;
    }
  }

  @override
  Future<SessionQueryResult> refreshSessions({SessionQueryRequest? query}) {
    _invalidateSessionsSnapshot();
    return getSessions(query: query);
  }

  @override
  Future<List<DeviceWorkspace>> getWorkspaces() {
    return _commands!.getWorkspaces();
  }

  @override
  Future<List<SlashCommandEntry>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) {
    return _commands!.searchSlashCommands(
      query: query,
      workspaceId: workspaceId,
    );
  }

  @override
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({
    String? workspaceId,
    String? path,
  }) {
    return _commands!.browseWorkspaceTree(
      workspaceId: workspaceId,
      path: path,
    );
  }

  @override
  Future<DeviceWorkspace> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) {
    return _commands!.createWorkspace(
      path: path,
      name: name,
      description: description,
    );
  }

  @override
  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) {
    return _commands!.renameWorkspace(
      workspaceId: workspaceId,
      displayName: displayName,
    );
  }

  @override
  Future<void> removeWorkspace({required String workspaceId}) {
    return _commands!.removeWorkspace(workspaceId: workspaceId);
  }

  @override
  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) {
    return _commands!.relocateWorkspace(
      workspaceId: workspaceId,
      newPath: newPath,
    );
  }

  @override
  Future<void> createFolder({
    required String parentPath,
    required String name,
  }) {
    return _commands!.createFolder(parentPath: parentPath, name: name);
  }

  @override
  Future<void> renameFolder({required String path, required String newName}) {
    return _commands!.renameFolder(path: path, newName: newName);
  }

  @override
  Future<void> deleteFolder({required String path}) {
    return _commands!.deleteFolder(path: path);
  }

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) {
    return _commands!.loadSessionHistory(sessionId);
  }

  Future<void> synchronizeAfterReconnect() async {
    await getSessions();
    final activeSessionId = _store.currentSessionId;
    if (activeSessionId != null && activeSessionId.isNotEmpty && isConnected) {
      await loadSessionHistory(activeSessionId);
    }
  }

  @override
  Future<void> updateSessionTitle(String sessionId, String title) {
    return _commands!.updateSessionTitle(sessionId, title).then((_) {
      _invalidateSessionsSnapshot();
    });
  }

  @override
  Future<void> deleteSession(String sessionId) {
    return _commands!.deleteSession(sessionId).then((_) {
      _invalidateSessionsSnapshot();
    });
  }

  @override
  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) {
    return _commands!.respondToSuspendedRequest(
      request,
      allow: allow,
      scope: scope,
      comment: comment,
      answer: answer,
    );
  }

  void updateSocketService(SanadSocketService socketService) {
    if (identical(_socketService, socketService)) {
      return;
    }
    _bindSocketService(socketService);
  }

  void _invalidateSessionsSnapshot() {
    _defaultRefreshGeneration++;
    _defaultRefreshInFlight = null;
    _sessionQueryGeneration++;
    _sessionQueryRequests.clear();
    _sessionsHydrationPending = true;
    _clearSessionQueryCache();
  }

  void _bindSocketService(SanadSocketService socketService) {
    _disposeTransportBindings();
    _sessionsHydrationPending = true;
    _socketService = socketService;

    final gateway = SocketConversationCommandGateway(
      config: _config,
      controller: socketService,
    );
    _gateway = gateway;
    _commands = ConversationCommands(
      gateway: gateway,
      conversationStore: _store,
      mapper: _mapper,
    );
    _eventHandler = ConversationEventHandler(
      deviceId: _config.id,
      gateway: gateway,
      conversationStore: _store,
      mapper: _mapper,
    );
    _sessionEventsSubscription = gateway.events.listen(_forwardSessionEvent);
    _socketLifecycleSubscription = socketService.lifecycleStateStream.listen((state) {
      if (state != SocketLifecycleState.ready) {
        _sessionsHydrationPending = true;
      }
    });
  }

  void _forwardSessionEvent(Map<String, dynamic> event) {
    final payload = event['payload'] as Map<String, dynamic>? ?? {};
    final eventName = event['event'] as String?;
    final requestId = event['request_id'] as String? ?? payload['request_id'] as String?;

    if (eventName == 'sessions_list') {
      if (requestId != null && requestId.isNotEmpty) {
        return;
      }
      final sessions = payload['sessions'] as List? ?? [];
      final mapped = sessions.map((session) {
        final sessionPayload = Map<String, dynamic>.from(session as Map);
        final sessionId = (sessionPayload['session_id'] ?? sessionPayload['id'])?.toString();
        if (sessionId != null && sessionId.isNotEmpty) {
          _store.hydrateSessionState(sessionPayload, sessionId: sessionId);
        }
        return Session.fromJson(sessionPayload);
      }).toList();
      _lastSessionsSnapshot = mapped;
      _sessionQueryCache[_defaultSessionQueryCacheKey] = SessionQueryResult(
        sessions: mapped,
        nextCursor: payload['next_cursor']?.toString(),
        hasMore: payload['has_more'] == true,
      );
      _sessionsHydrationPending = false;
      _publishDefaultSessions(mapped);
      return;
    }

    if (eventName == 'session_created') {
      _invalidateSessionsSnapshot();
      final sessionPayload = Map<String, dynamic>.from(payload);
      final deviceId = event['device_id'] as String?;
      if (deviceId != null && sessionPayload['device_id'] == null) {
        sessionPayload['device_id'] = deviceId;
      }
      if (!_sessionCreatedController.isClosed) {
        _sessionCreatedController.add(Session.fromJson(sessionPayload));
      }
      return;
    }

    if (eventName == 'session_updated' || eventName == 'session_deleted' || eventName == 'user_message') {
      _invalidateSessionsSnapshot();
      if (eventName == 'user_message' && isConnected && _commands != null && _lastSessionsSnapshot != null) {
        unawaited(_fetchLegacyDefaultSessions());
      }
    }
  }

  void _publishDefaultSessions(List<Session> sessions) {
    if (!_sessionsController.isClosed) {
      _sessionsController.add(sessions);
    }
  }

  void _clearSessionQueryCache() {
    _sessionQueryCache.clear();
  }

  String _sessionQueryCacheKeyFor(SessionQueryRequest? query) =>
      query == null ? _defaultSessionQueryCacheKey : query.cacheKey;

  void _disposeTransportBindings() {
    final sessionEventsSubscription = _sessionEventsSubscription;
    if (sessionEventsSubscription != null) {
      unawaited(sessionEventsSubscription.cancel());
    }
    _sessionEventsSubscription = null;

    final socketLifecycleSubscription = _socketLifecycleSubscription;
    if (socketLifecycleSubscription != null) {
      unawaited(socketLifecycleSubscription.cancel());
    }
    _socketLifecycleSubscription = null;

    final eventHandler = _eventHandler;
    if (eventHandler != null) {
      eventHandler.dispose();
    }
    _eventHandler = null;

    final gateway = _gateway;
    if (gateway != null) {
      gateway.dispose();
    }
    _gateway = null;
    _commands = null;
  }

  @override
  Future<WorkspacePolicy> getWorkspacePolicy(String workspacePath) async {
    final gateway = _gateway;
    if (gateway == null) {
      throw StateError('Command gateway not initialized');
    }
    final requestId = generateConversationRequestId();
    final result = await gateway.request(
      command: 'workspace.get_policy',
      payload: {
        'request_id': requestId,
        'workspace_path': workspacePath,
      },
      requestId: requestId,
    );
    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      return WorkspacePolicy.fromJson(payload);
    }
    throw StateError('Failed to get workspace policy');
  }

  @override
  Future<WorkspacePolicy> setWorkspacePermissionMode({
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  }) async {
    final gateway = _gateway;
    if (gateway == null) {
      throw StateError('Command gateway not initialized');
    }
    final requestId = generateConversationRequestId();
    final result = await gateway.request(
      command: 'workspace.set_permission_mode',
      payload: {
        'request_id': requestId,
        'workspace_id': workspaceId,
        'workspace_path': workspacePath,
        'permission_mode': mode.value,
      },
      requestId: requestId,
    );
    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      return WorkspacePolicy.fromJson(payload);
    }
    throw StateError('Failed to set workspace permission mode');
  }

  @override
  Stream<WorkspacePolicy> watchWorkspacePolicy(String workspaceId) {
    final gateway = _gateway;
    if (gateway == null) {
      return const Stream.empty();
    }
    return gateway.events
        .where((event) {
          final eventName = event['event'] as String?;
          if (eventName != 'workspace.policy_changed') return false;
          final payload = event['payload'] as Map<String, dynamic>? ?? {};
          return payload['workspace_id'] == workspaceId;
        })
        .map((event) {
          final payload = event['payload'] as Map<String, dynamic>? ?? {};
          final policyJson = payload['policy'] is Map<String, dynamic>
              ? payload['policy'] as Map<String, dynamic>
              : payload;
          return WorkspacePolicy.fromJson(policyJson);
        });
  }

  void dispose() {
    _disposeTransportBindings();
    unawaited(_sessionsController.close());
    unawaited(_sessionCreatedController.close());
    _store.dispose();
  }
}
