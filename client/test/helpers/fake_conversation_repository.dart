import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

class FakeConversationRepository implements ConversationRepository {
  bool transportReady = true;
  final Map<String, List<Session>> _sessionsByAgentId = {};
  final Map<String, List<CanonicalEvent>> _messagesByAgentId = {};
  final Map<String, List<CanonicalEvent>> _queuedMessagesByAgentId = {};
  final Map<String, DeviceProcessingSnapshot> _processingByAgentId = {};
  final Map<String, StreamController<List<Session>>> _sessionsControllers = {};
  final Map<String, StreamController<Session>> _sessionCreatedControllers = {};
  final Map<String, StreamController<DeviceProcessingSnapshot>> _processingControllers = {};
  final Map<String, StreamController<List<CanonicalEvent>>> _messagesControllers = {};
  final Map<String, StreamController<List<CanonicalEvent>>> _queuedMessagesControllers = {};
  final Map<String, StreamController<DeviceSuspendedRequest?>> _pendingSuspensionControllers = {};
  final Map<String, StreamController<RuntimeNotice?>> _runtimeNoticeControllers = {};
  final Map<String, DeviceSuspendedRequest?> _pendingSuspendedByAgentId = {};
  final Map<String, RuntimeNotice?> _runtimeNoticeByAgentId = {};
  final Map<String, Map<String, SessionAttentionState>> _attentionByAgentId = {};
  final Map<String, StreamController<Map<String, SessionAttentionState>>> _attentionControllers = {};
  final Map<String, Map<String, SessionRouteSnapshot>> _routesByAgentId = {};
  final Map<String, StreamController<Map<String, SessionRouteSnapshot>>> _routeControllers = {};
  final StreamController<StopDraftRecovery> _stopRecoveriesController = StreamController.broadcast();

  final List<String> activatedSessionIds = [];
  final List<String> loadedHistorySessionIds = [];
  final List<String> sentMessages = [];
  final List<Map<String, String?>> sentMessageRequests = [];
  final List<Map<String, String?>> steerMessageRequests = [];
  final List<String?> stoppedSessionIds = [];
  final List<Map<String, String?>> retriedRuntimeNotices = [];
  final List<Map<String, String?>> continuedRuntimeNotices = [];
  SessionCompactResult compactSessionResult = const SessionCompactResult(outcome: 'accepted');
  Future<SessionCompactResult> Function()? compactSessionHandler;
  int compactSessionCalls = 0;
  final List<Map<String, String?>> updatedSessionPreferences = [];
  final List<Map<String, Object?>> createdSessionRequests = [];
  final List<DeviceWorkspace> workspaces = [];
  final List<Map<String, String?>> createdWorkspaces = [];
  final List<String> removedWorkspaceIds = [];
  final List<Map<String, String?>> slashCommandSearchRequests = [];
  final List<Map<String, String?>> browseWorkspaceTreeRequests = [];
  final List<Map<String, String?>> permissionResponses = [];
  List<SlashCommandEntry> slashCommandResults = const [];
  WorkspaceTreeSnapshot? workspaceTreeSnapshot;
  Future<SessionQueryResult> Function(DeviceConfig agent, SessionQueryRequest? query)? refreshSessionsHandler;
  Future<List<DeviceWorkspace>> Function(DeviceConfig agent)? getWorkspacesHandler;
  Future<WorkspaceTreeSnapshot> Function({
    DeviceConfig? agent,
    String? workspaceId,
    String? path,
  })?
  browseWorkspaceTreeHandler;
  int beginNewSessionCalls = 0;
  int stopCalls = 0;
  bool currentConversationProcessing = false;

  void seedSessions(DeviceConfig agent, List<Session> sessions) {
    _sessionsByAgentId[agent.id] = List<Session>.from(sessions);
  }

  void setMessages(DeviceConfig agent, List<CanonicalEvent> messages) {
    _messagesByAgentId[agent.id] = List<CanonicalEvent>.from(messages);
    _messagesController(agent.id).add(currentMessages(agent));
  }

  void setProcessing(DeviceConfig agent, DeviceProcessingSnapshot snapshot) {
    _processingByAgentId[agent.id] = snapshot;
    _processingController(agent.id).add(snapshot);
  }

  @override
  Stream<List<Session>> watchSessions(DeviceConfig agent) async* {
    if (agent.isOnline && transportReady) {
      yield (await getSessions(agent)).sessions;
    }
    yield* _sessionsController(agent.id).stream;
  }

  @override
  Stream<Session> watchSessionCreated(DeviceConfig agent) => _sessionCreatedController(agent.id).stream;

  @override
  Stream<DeviceProcessingSnapshot> watchProcessing(DeviceConfig agent) => _processingController(agent.id).stream;

  @override
  Stream<List<CanonicalEvent>> watchMessages(DeviceConfig agent) => _messagesController(agent.id).stream;

  @override
  Stream<List<CanonicalEvent>> watchQueuedMessages(DeviceConfig agent) => _queuedMessagesController(agent.id).stream;

  @override
  Stream<DeviceSuspendedRequest?> watchPendingSuspension(DeviceConfig agent) =>
      _pendingSuspensionController(agent.id).stream;

  @override
  Stream<RuntimeNotice?> watchRuntimeNotice(DeviceConfig agent) => _runtimeNoticeController(agent.id).stream;

  @override
  Stream<StopDraftRecovery> watchStopRecoveries(DeviceConfig agent) => _stopRecoveriesController.stream;

  @override
  Stream<Map<String, SessionAttentionState>> watchAttentionStates(
    DeviceConfig agent,
  ) async* {
    yield currentAttentionStates(agent);
    yield* _attentionController(agent.id).stream;
  }

  @override
  Stream<Map<String, SessionRouteSnapshot>> watchRouteSnapshots(
    DeviceConfig agent,
  ) async* {
    yield currentRouteSnapshots(agent);
    yield* _routeController(agent.id).stream;
  }

  @override
  List<CanonicalEvent> currentMessages(DeviceConfig agent) =>
      List.unmodifiable(_messagesByAgentId[agent.id] ?? const []);

  @override
  bool isProcessing(DeviceConfig agent) =>
      (_processingByAgentId[agent.id] ?? const DeviceProcessingSnapshot()).isProcessing;

  @override
  bool isCurrentConversationProcessing(DeviceConfig agent) => currentConversationProcessing;

  @override
  bool isSessionProcessing(DeviceConfig agent, String? sessionId) {
    return (_processingByAgentId[agent.id] ?? const DeviceProcessingSnapshot()).isSessionProcessing(sessionId);
  }

  @override
  DeviceSuspendedRequest? currentPendingSuspendedRequest(DeviceConfig agent) => _pendingSuspendedByAgentId[agent.id];

  @override
  RuntimeNotice? currentRuntimeNotice(DeviceConfig agent) => _runtimeNoticeByAgentId[agent.id];

  @override
  Map<String, SessionAttentionState> currentAttentionStates(
    DeviceConfig agent,
  ) => Map.unmodifiable(_attentionByAgentId[agent.id] ?? const {});

  void setAttentionStates(
    DeviceConfig agent,
    Map<String, SessionAttentionState> attention,
  ) {
    _attentionByAgentId[agent.id] = Map.of(attention);
    _attentionController(agent.id).add(currentAttentionStates(agent));
  }

  @override
  Map<String, SessionRouteSnapshot> currentRouteSnapshots(
    DeviceConfig agent,
  ) => Map.unmodifiable(_routesByAgentId[agent.id] ?? const {});

  void setRouteSnapshots(
    DeviceConfig agent,
    Map<String, SessionRouteSnapshot> routes,
  ) {
    _routesByAgentId[agent.id] = Map.of(routes);
    _routeController(agent.id).add(currentRouteSnapshots(agent));
  }

  @override
  void activateSession(DeviceConfig agent, String sessionId) {
    activatedSessionIds.add(sessionId);
  }

  @override
  void beginNewSession(DeviceConfig agent) {
    beginNewSessionCalls += 1;
  }

  @override
  Future<Session> createSession(
    DeviceConfig agent, {
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    createdSessionRequests.add({
      'device_id': agent.id,
      'title': title,
      if (isTitlePlaceholder) 'title_is_placeholder': true,
      'workspace_id': workspaceId,
      if (providerId != null) 'provider_id': providerId,
      if (model != null) 'model': model,
      if (thinkingMode != null) 'thinking_mode': thinkingMode,
    });
    final session = Session(
      id: 'session-${createdSessionRequests.length}',
      title: title ?? 'New Session',
      deviceId: agent.id,
      model: model,
      modelProvider: providerId,
      thinkingMode: thinkingMode,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      workspaceId: workspaceId,
    );
    if (_sessionsByAgentId[agent.id] == null) {
      _sessionsByAgentId[agent.id] = [];
    }
    _sessionsByAgentId[agent.id]!.add(session);
    _sessionsController(agent.id).add(_sessionsByAgentId[agent.id]!);
    _sessionCreatedController(agent.id).add(session);
    return session;
  }

  @override
  Future<String?> sendMessage(
    DeviceConfig agent,
    String message, {
    String? sessionId,
    String? workspaceId,
    String? context,
    String? providerId,
    String? model,
    String? thinkingMode,
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  }) async {
    sentMessages.add(message);
    sentMessageRequests.add({
      'device_id': agent.id,
      'session_id': sessionId,
      'workspace_id': workspaceId,
      'message': message,
      'context': context,
      'model': model,
      'thinking_mode': thinkingMode,
      'intent': intent.name,
    });
    return 'fake-request-${sentMessageRequests.length}';
  }

  @override
  Future<void> steerMessage(
    DeviceConfig agent,
    String message, {
    required String requestId,
    required String sessionId,
  }) async {
    steerMessageRequests.add({
      'device_id': agent.id,
      'message': message,
      'request_id': requestId,
      'session_id': sessionId,
    });
  }

  @override
  Future<String?> deleteQueuedMessage(
    DeviceConfig agent, {
    required String requestId,
    required String sessionId,
  }) async => 'delete-$requestId';

  @override
  Future<String?> cancelPendingSteer(
    DeviceConfig agent, {
    required String requestId,
    required String sessionId,
  }) async => 'cancel-$requestId';

  @override
  List<CanonicalEvent> currentQueuedMessages(DeviceConfig agent) =>
      List.unmodifiable(_queuedMessagesByAgentId[agent.id] ?? const []);

  void setQueuedMessages(DeviceConfig agent, List<CanonicalEvent> queuedMessages) {
    _queuedMessagesByAgentId[agent.id] = List<CanonicalEvent>.from(queuedMessages);
    _queuedMessagesController(agent.id).add(currentQueuedMessages(agent));
  }

  @override
  Future<String?> stop(
    DeviceConfig agent, {
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  }) async {
    stopCalls += 1;
    stoppedSessionIds.add(sessionId);
    return requestId ?? 'stop-$stopCalls';
  }

  @override
  Future<String?> claimStopRecovery(
    DeviceConfig agent, {
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  }) async => commandRequestId ?? 'claim-$stopRequestId';

  @override
  Future<void> acknowledgeStopRecovery(
    DeviceConfig agent, {
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  }) async {}

  @override
  Future<TurnReplayResult> replayTurn(
    DeviceConfig agent, {
    required String sessionId,
    required String targetRequestId,
    required TurnReplayAction action,
    String? message,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
    bool confirmedReplayUnsafe = false,
  }) async => const TurnReplayResult(
    outcome: 'accepted',
    safety: TurnReplaySafety.safe,
    requiresConfirmation: false,
  );

  @override
  Future<SessionCompactResult> compactSession(
    DeviceConfig agent, {
    required String sessionId,
  }) async {
    compactSessionCalls += 1;
    final handler = compactSessionHandler;
    if (handler != null) return handler();
    return compactSessionResult;
  }

  @override
  Future<void> retryRuntimeNotice(
    DeviceConfig agent, {
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  }) async {
    retriedRuntimeNotices.add({
      'device_id': agent.id,
      'session_id': sessionId,
      'request_id': requestId,
      'provider_instance_id': providerInstanceId,
      'model_id': modelId,
    });
  }

  @override
  Future<void> continueWithProvider(
    DeviceConfig agent, {
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  }) async {
    continuedRuntimeNotices.add({
      'device_id': agent.id,
      'session_id': sessionId,
      'provider_instance_id': providerInstanceId,
      'request_id': requestId,
      'model_id': modelId,
    });
  }

  @override
  Future<void> updateSessionPreferences(
    DeviceConfig agent, {
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    updatedSessionPreferences.add({
      'device_id': agent.id,
      'session_id': sessionId,
      'provider_id': providerId,
      'model': model,
      'thinking_mode': thinkingMode,
    });
  }

  @override
  Future<SessionQueryResult> getSessions(DeviceConfig agent, {SessionQueryRequest? query}) async {
    if (!transportReady) {
      return SessionQueryResult(sessions: const [], hasMore: false);
    }
    final allSessions = _sessionsByAgentId[agent.id] ?? const <Session>[];
    final filtered = _applySessionQuery(allSessions, query);
    if (query == null || query.isDefault) {
      _sessionsController(agent.id).add(List<Session>.from(filtered.sessions));
    }
    return filtered;
  }

  @override
  Future<SessionQueryResult> refreshSessions(DeviceConfig agent, {SessionQueryRequest? query}) async {
    final handler = refreshSessionsHandler;
    if (handler != null) return handler(agent, query);
    return getSessions(agent, query: query);
  }

  SessionQueryResult _applySessionQuery(
    List<Session> source,
    SessionQueryRequest? query,
  ) {
    final ordered = List<Session>.from(source)
      ..sort((a, b) {
        final aTime = a.lastMessageAt ?? a.createdAt;
        final bTime = b.lastMessageAt ?? b.createdAt;
        final byTime = bTime.compareTo(aTime);
        if (byTime != 0) {
          return byTime;
        }
        return b.id.compareTo(a.id);
      });
    if (query == null) {
      return SessionQueryResult(sessions: ordered, hasMore: false);
    }

    var filtered = ordered
        .where((session) {
          if (query.unscopedOnly) {
            return session.workspaceId == null || session.workspaceId!.trim().isEmpty;
          }
          if (query.workspaceId != null && query.workspaceId!.trim().isNotEmpty) {
            return session.workspaceId == query.workspaceId!.trim();
          }
          return true;
        })
        .toList(growable: false);

    if (query.cursor != null) {
      final index = filtered.indexWhere((session) => session.id == query.cursor);
      if (index >= 0 && index + 1 < filtered.length) {
        filtered = filtered.sublist(index + 1);
      } else if (index >= 0) {
        filtered = const [];
      }
    }

    final limit = query.limit;
    if (limit == null || filtered.length <= limit) {
      return SessionQueryResult(sessions: filtered, hasMore: false);
    }

    final page = filtered.take(limit).toList(growable: false);
    return SessionQueryResult(
      sessions: page,
      nextCursor: page.last.id,
      hasMore: true,
    );
  }

  @override
  Future<List<DeviceWorkspace>> getWorkspaces(DeviceConfig agent) async {
    final handler = getWorkspacesHandler;
    if (handler != null) return handler(agent);
    return workspaces;
  }

  @override
  Future<List<SlashCommandEntry>> searchSlashCommands(
    DeviceConfig agent, {
    String? query,
    String? workspaceId,
  }) async {
    slashCommandSearchRequests.add({
      'device_id': agent.id,
      'query': query,
      'workspace_id': workspaceId,
    });
    return slashCommandResults;
  }

  @override
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree(
    DeviceConfig agent, {
    String? workspaceId,
    String? path,
  }) async {
    browseWorkspaceTreeRequests.add({
      'device_id': agent.id,
      'workspace_id': workspaceId,
      'path': path,
    });
    final handler = browseWorkspaceTreeHandler;
    if (handler != null) {
      return handler(agent: agent, workspaceId: workspaceId, path: path);
    }
    return workspaceTreeSnapshot ??
        const WorkspaceTreeSnapshot(
          workspaceId: '',
          rootPath: '',
          path: '',
          parentPath: null,
          entries: [],
          truncated: false,
        );
  }

  @override
  Future<DeviceWorkspace> createWorkspace(
    DeviceConfig agent, {
    String? path,
    String? name,
    String? description,
  }) async {
    createdWorkspaces.add({
      'device_id': agent.id,
      'path': path,
      'name': name,
      'description': description,
    });
    return DeviceWorkspace(
      id: path ?? name ?? 'workspace',
      path: path ?? name ?? 'workspace',
      name: name ?? path ?? 'workspace',
    );
  }

  @override
  Future<DeviceWorkspace> renameWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String displayName,
  }) async {
    return DeviceWorkspace(id: workspaceId, name: displayName, path: workspaceId);
  }

  @override
  Future<void> removeWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
  }) async {
    removedWorkspaceIds.add(workspaceId);
    workspaces.removeWhere((workspace) => workspace.id == workspaceId);
  }

  @override
  Future<DeviceWorkspace> relocateWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String newPath,
  }) async {
    return DeviceWorkspace(id: workspaceId, name: workspaceId, path: newPath);
  }

  @override
  Future<void> createFolder(
    DeviceConfig agent, {
    required String parentPath,
    required String name,
  }) async {}

  @override
  Future<void> renameFolder(
    DeviceConfig agent, {
    required String path,
    required String newName,
  }) async {}

  @override
  Future<void> deleteFolder(
    DeviceConfig agent, {
    required String path,
  }) async {}

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(DeviceConfig agent, String sessionId) async {
    loadedHistorySessionIds.add(sessionId);
    return const [];
  }

  @override
  Future<void> updateSessionTitle(DeviceConfig agent, String sessionId, String title) async {
    final sessions = _sessionsByAgentId[agent.id] ?? const <Session>[];
    _sessionsByAgentId[agent.id] = sessions.map((session) {
      if (session.id == sessionId) {
        return session.copyWith(title: title, updatedAt: DateTime.now());
      }
      return session;
    }).toList();
  }

  @override
  Future<void> deleteSession(DeviceConfig agent, String sessionId) async {
    final sessions = _sessionsByAgentId[agent.id] ?? const <Session>[];
    _sessionsByAgentId[agent.id] = sessions.where((session) => session.id != sessionId).toList();
  }

  @override
  Future<void> respondToSuspendedRequest(
    DeviceConfig agent,
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) async {
    permissionResponses.add({
      'device_id': agent.id,
      'request_id': request.requestId,
      'allow': allow.toString(),
      'scope': scope,
      'comment': comment,
      'answer': answer,
    });
    _pendingSuspendedByAgentId[agent.id] = null;
    _pendingSuspensionController(agent.id).add(null);
  }

  final Map<String, WorkspacePolicy> seededWorkspacePolicies = {};
  final List<Map<String, dynamic>> setPermissionModeRequests = [];
  final Map<String, StreamController<WorkspacePolicy>> _policyControllers = {};

  @override
  Future<WorkspacePolicy> getWorkspacePolicy(DeviceConfig agent, String workspacePath) async {
    return seededWorkspacePolicies[workspacePath] ?? const WorkspacePolicy();
  }

  @override
  Future<WorkspacePolicy> setWorkspacePermissionMode(
    DeviceConfig agent, {
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  }) async {
    setPermissionModeRequests.add({
      'device_id': agent.id,
      'workspace_id': workspaceId,
      'workspace_path': workspacePath,
      'mode': mode,
    });
    final updated = (seededWorkspacePolicies[workspacePath] ?? const WorkspacePolicy()).copyWith(permissionMode: mode);
    seededWorkspacePolicies[workspacePath] = updated;
    _policyController(workspaceId).add(updated);
    return updated;
  }

  @override
  Stream<WorkspacePolicy> watchWorkspacePolicy(DeviceConfig agent, String workspaceId) {
    return _policyController(workspaceId).stream;
  }

  StreamController<WorkspacePolicy> _policyController(String workspaceId) {
    return _policyControllers.putIfAbsent(
      workspaceId,
      () => StreamController<WorkspacePolicy>.broadcast(),
    );
  }

  void setPendingSuspendedRequest(DeviceConfig agent, DeviceSuspendedRequest? request) {
    final previous = _pendingSuspendedByAgentId[agent.id];
    _pendingSuspendedByAgentId[agent.id] = request;
    _pendingSuspensionController(agent.id).add(request);
    final sessionId = request?.sessionId ?? previous?.sessionId;
    if (sessionId != null) {
      final current = _attentionByAgentId[agent.id]?[sessionId];
      final attention = SessionAttentionState(
        sessionId: sessionId,
        executionSnapshot: current?.executionSnapshot ?? SessionExecutionSnapshot.virtualIdle(sessionId),
        runtimeNotice: current?.runtimeNotice,
        pendingSuspendedRequest: request,
      );
      setAttentionStates(agent, {
        ..._attentionByAgentId[agent.id] ?? const {},
        sessionId: attention,
      });
    }
  }

  void setRuntimeNotice(DeviceConfig agent, RuntimeNotice? notice) {
    final previous = _runtimeNoticeByAgentId[agent.id];
    _runtimeNoticeByAgentId[agent.id] = notice;
    _runtimeNoticeController(agent.id).add(notice);
    final sessionId = notice?.sessionId ?? previous?.sessionId;
    if (sessionId != null) {
      final current = _attentionByAgentId[agent.id]?[sessionId];
      final attention = SessionAttentionState(
        sessionId: sessionId,
        executionSnapshot: current?.executionSnapshot ?? SessionExecutionSnapshot.virtualIdle(sessionId),
        runtimeNotice: notice,
        pendingSuspendedRequest: current?.pendingSuspendedRequest,
      );
      setAttentionStates(agent, {
        ..._attentionByAgentId[agent.id] ?? const {},
        sessionId: attention,
      });
    }
  }

  Future<void> dispose() async {
    for (final controller in [
      ..._sessionsControllers.values,
      ..._sessionCreatedControllers.values,
      ..._processingControllers.values,
      ..._messagesControllers.values,
      ..._queuedMessagesControllers.values,
      ..._pendingSuspensionControllers.values,
      ..._runtimeNoticeControllers.values,
      ..._attentionControllers.values,
      ..._routeControllers.values,
      ..._policyControllers.values,
      _stopRecoveriesController,
    ]) {
      await controller.close();
    }
  }

  StreamController<Map<String, SessionRouteSnapshot>> _routeController(
    String agentId,
  ) => _routeControllers.putIfAbsent(
    agentId,
    () => StreamController<Map<String, SessionRouteSnapshot>>.broadcast(),
  );

  StreamController<List<Session>> _sessionsController(String deviceId) {
    return _sessionsControllers.putIfAbsent(deviceId, () => StreamController<List<Session>>.broadcast());
  }

  StreamController<Session> _sessionCreatedController(String deviceId) {
    return _sessionCreatedControllers.putIfAbsent(deviceId, () => StreamController<Session>.broadcast());
  }

  StreamController<DeviceProcessingSnapshot> _processingController(String deviceId) {
    return _processingControllers.putIfAbsent(deviceId, () => StreamController<DeviceProcessingSnapshot>.broadcast());
  }

  StreamController<List<CanonicalEvent>> _messagesController(String deviceId) {
    return _messagesControllers.putIfAbsent(deviceId, () => StreamController<List<CanonicalEvent>>.broadcast());
  }

  StreamController<List<CanonicalEvent>> _queuedMessagesController(String deviceId) {
    return _queuedMessagesControllers.putIfAbsent(deviceId, () => StreamController<List<CanonicalEvent>>.broadcast());
  }

  StreamController<DeviceSuspendedRequest?> _pendingSuspensionController(String deviceId) {
    return _pendingSuspensionControllers.putIfAbsent(
      deviceId,
      () => StreamController<DeviceSuspendedRequest?>.broadcast(),
    );
  }

  StreamController<RuntimeNotice?> _runtimeNoticeController(String deviceId) {
    return _runtimeNoticeControllers.putIfAbsent(
      deviceId,
      () => StreamController<RuntimeNotice?>.broadcast(),
    );
  }

  StreamController<Map<String, SessionAttentionState>> _attentionController(
    String deviceId,
  ) {
    return _attentionControllers.putIfAbsent(
      deviceId,
      () => StreamController<Map<String, SessionAttentionState>>.broadcast(),
    );
  }
}
