import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
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
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

class SocketConversationRepository implements ConversationRepository {
  final ConversationClientRegistry _clientRegistry;

  SocketConversationRepository(this._clientRegistry);

  @override
  Stream<List<Session>> watchSessions(DeviceConfig agent) async* {
    final client = _clientFor(agent);
    if (agent.isOnline && client.isConnected) {
      try {
        final result = await client.getSessions();
        yield result.sessions;
      } catch (_) {}
    }
    yield* client.sessions;
  }

  @override
  Stream<Session> watchSessionCreated(DeviceConfig agent) => _clientFor(agent).sessionCreated;

  @override
  Stream<DeviceProcessingSnapshot> watchProcessing(DeviceConfig agent) => _clientFor(agent).processing;

  @override
  Stream<List<CanonicalEvent>> watchMessages(DeviceConfig agent) => _clientFor(agent).messages;

  @override
  Stream<List<CanonicalEvent>> watchQueuedMessages(DeviceConfig agent) => _clientFor(agent).queuedMessages;

  @override
  Stream<DeviceSuspendedRequest?> watchPendingSuspension(DeviceConfig agent) =>
      _clientFor(agent).pendingSuspendedRequest;

  @override
  Stream<RuntimeNotice?> watchRuntimeNotice(DeviceConfig agent) => _clientFor(agent).runtimeNotice;

  @override
  Stream<StopDraftRecovery> watchStopRecoveries(DeviceConfig agent) => _clientFor(agent).stopRecoveries;

  @override
  Stream<Map<String, SessionAttentionState>> watchAttentionStates(
    DeviceConfig agent,
  ) async* {
    final client = _clientFor(agent);
    yield client.currentAttentionStates;
    yield* client.attentionStates;
  }

  @override
  Stream<Map<String, SessionRouteSnapshot>> watchRouteSnapshots(
    DeviceConfig agent,
  ) async* {
    final client = _clientFor(agent);
    yield client.currentRouteSnapshots;
    yield* client.routeSnapshots;
  }

  @override
  List<CanonicalEvent> currentMessages(DeviceConfig agent) => _clientFor(agent).currentMessages;

  @override
  List<CanonicalEvent> currentQueuedMessages(DeviceConfig agent) => _clientFor(agent).currentQueuedMessages;

  @override
  bool isProcessing(DeviceConfig agent) => _clientFor(agent).isProcessing;

  @override
  bool isCurrentConversationProcessing(DeviceConfig agent) => _clientFor(agent).isCurrentConversationProcessing;

  @override
  bool isSessionProcessing(DeviceConfig agent, String? sessionId) => _clientFor(agent).isSessionProcessing(sessionId);

  @override
  DeviceSuspendedRequest? currentPendingSuspendedRequest(DeviceConfig agent) =>
      _clientFor(agent).currentPendingSuspendedRequest;

  @override
  RuntimeNotice? currentRuntimeNotice(DeviceConfig agent) => _clientFor(agent).currentRuntimeNotice;

  @override
  Map<String, SessionAttentionState> currentAttentionStates(
    DeviceConfig agent,
  ) => _clientFor(agent).currentAttentionStates;

  @override
  Map<String, SessionRouteSnapshot> currentRouteSnapshots(DeviceConfig agent) =>
      _clientFor(agent).currentRouteSnapshots;

  @override
  void activateSession(DeviceConfig agent, String sessionId) {
    _clientFor(agent).activateSession(sessionId);
  }

  @override
  void beginNewSession(DeviceConfig agent) {
    _clientFor(agent).beginNewSession();
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
  }) {
    return _clientFor(agent).createSession(
      title: title,
      isTitlePlaceholder: isTitlePlaceholder,
      workspaceId: workspaceId,
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
    );
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
  }) {
    return _clientFor(agent).sendMessage(
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
    DeviceConfig agent,
    String message, {
    required String requestId,
    required String sessionId,
  }) {
    return _clientFor(agent).steerMessage(message, requestId: requestId, sessionId: sessionId);
  }

  @override
  Future<String?> deleteQueuedMessage(
    DeviceConfig agent, {
    required String requestId,
    required String sessionId,
  }) => _clientFor(agent).deleteQueuedMessage(requestId: requestId, sessionId: sessionId);

  @override
  Future<String?> cancelPendingSteer(
    DeviceConfig agent, {
    required String requestId,
    required String sessionId,
  }) => _clientFor(agent).cancelPendingSteer(requestId: requestId, sessionId: sessionId);

  @override
  Future<String?> stop(
    DeviceConfig agent, {
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  }) {
    return _clientFor(agent).stop(
      sessionId: sessionId,
      requestId: requestId,
      recoveryOwnerToken: recoveryOwnerToken,
    );
  }

  @override
  Future<String?> claimStopRecovery(
    DeviceConfig agent, {
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  }) => _clientFor(agent).claimStopRecovery(
    sessionId: sessionId,
    stopRequestId: stopRequestId,
    commandRequestId: commandRequestId,
  );

  @override
  Future<void> acknowledgeStopRecovery(
    DeviceConfig agent, {
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  }) => _clientFor(agent).acknowledgeStopRecovery(
    sessionId: sessionId,
    stopRequestId: stopRequestId,
    claimantId: claimantId,
    recoveryOwnerToken: recoveryOwnerToken,
  );

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
  }) => _clientFor(agent).replayTurn(
    sessionId: sessionId,
    targetRequestId: targetRequestId,
    action: action,
    message: message,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
    thinkingMode: thinkingMode,
    confirmedReplayUnsafe: confirmedReplayUnsafe,
  );

  @override
  Future<SessionCompactResult> compactSession(
    DeviceConfig agent, {
    required String sessionId,
  }) => _clientFor(agent).compactSession(sessionId: sessionId);

  @override
  Future<void> retryRuntimeNotice(
    DeviceConfig agent, {
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  }) {
    return _clientFor(agent).retryRuntimeNotice(
      sessionId: sessionId,
      requestId: requestId,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
    );
  }

  @override
  Future<void> continueWithProvider(
    DeviceConfig agent, {
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  }) {
    return _clientFor(agent).continueWithProvider(
      sessionId: sessionId,
      providerInstanceId: providerInstanceId,
      requestId: requestId,
      modelId: modelId,
    );
  }

  @override
  Future<void> updateSessionPreferences(
    DeviceConfig agent, {
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    return _clientFor(agent).updateSessionPreferences(
      sessionId: sessionId,
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
    );
  }

  @override
  Future<SessionQueryResult> getSessions(
    DeviceConfig agent, {
    SessionQueryRequest? query,
  }) {
    return _clientFor(agent).getSessions(query: query);
  }

  @override
  Future<SessionQueryResult> refreshSessions(
    DeviceConfig agent, {
    SessionQueryRequest? query,
  }) {
    return _clientFor(agent).refreshSessions(query: query);
  }

  @override
  Future<List<DeviceWorkspace>> getWorkspaces(DeviceConfig agent) {
    return _clientFor(agent).getWorkspaces();
  }

  @override
  Future<List<SlashCommandEntry>> searchSlashCommands(
    DeviceConfig agent, {
    String? query,
    String? workspaceId,
  }) {
    return _clientFor(agent).searchSlashCommands(query: query, workspaceId: workspaceId);
  }

  @override
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree(
    DeviceConfig agent, {
    String? workspaceId,
    String? path,
  }) {
    return _clientFor(agent).browseWorkspaceTree(workspaceId: workspaceId, path: path);
  }

  @override
  Future<DeviceWorkspace> createWorkspace(
    DeviceConfig agent, {
    String? path,
    String? name,
    String? description,
  }) {
    return _clientFor(agent).createWorkspace(path: path, name: name, description: description);
  }

  @override
  Future<DeviceWorkspace> renameWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String displayName,
  }) {
    return _clientFor(agent).renameWorkspace(workspaceId: workspaceId, displayName: displayName);
  }

  @override
  Future<void> removeWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
  }) {
    return _clientFor(agent).removeWorkspace(workspaceId: workspaceId);
  }

  @override
  Future<DeviceWorkspace> relocateWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String newPath,
  }) {
    return _clientFor(agent).relocateWorkspace(workspaceId: workspaceId, newPath: newPath);
  }

  @override
  Future<void> createFolder(
    DeviceConfig agent, {
    required String parentPath,
    required String name,
  }) {
    return _clientFor(agent).createFolder(parentPath: parentPath, name: name);
  }

  @override
  Future<void> renameFolder(
    DeviceConfig agent, {
    required String path,
    required String newName,
  }) {
    return _clientFor(agent).renameFolder(path: path, newName: newName);
  }

  @override
  Future<void> deleteFolder(DeviceConfig agent, {required String path}) {
    return _clientFor(agent).deleteFolder(path: path);
  }

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(
    DeviceConfig agent,
    String sessionId,
  ) {
    return _clientFor(agent).loadSessionHistory(sessionId);
  }

  @override
  Future<List<CanonicalEvent>> loadOlderSessionHistory(
    DeviceConfig agent,
    String sessionId,
  ) {
    return _clientFor(agent).loadOlderSessionHistory(sessionId);
  }

  @override
  Future<List<CanonicalEvent>> loadAnchoredSessionHistory(
    DeviceConfig agent,
    String sessionId,
    String anchorEventId,
  ) {
    return _clientFor(agent).loadAnchoredSessionHistory(
      sessionId,
      anchorEventId,
    );
  }

  @override
  bool historyHasMore(DeviceConfig agent) => _clientFor(agent).historyHasMore;

  @override
  Future<void> updateSessionTitle(
    DeviceConfig agent,
    String sessionId,
    String title,
  ) {
    return _clientFor(agent).updateSessionTitle(sessionId, title);
  }

  @override
  Future<void> deleteSession(DeviceConfig agent, String sessionId) {
    return _clientFor(agent).deleteSession(sessionId);
  }

  @override
  Future<void> respondToSuspendedRequest(
    DeviceConfig agent,
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) {
    return _clientFor(agent).respondToSuspendedRequest(
      request,
      allow: allow,
      scope: scope,
      comment: comment,
      answer: answer,
    );
  }

  @override
  Future<WorkspacePolicy> getWorkspacePolicy(
    DeviceConfig agent,
    String workspacePath,
  ) {
    return _clientFor(agent).getWorkspacePolicy(workspacePath);
  }

  @override
  Future<WorkspacePolicy> setWorkspacePermissionMode(
    DeviceConfig agent, {
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  }) {
    return _clientFor(agent).setWorkspacePermissionMode(
      workspaceId: workspaceId,
      workspacePath: workspacePath,
      mode: mode,
    );
  }

  @override
  Stream<WorkspacePolicy> watchWorkspacePolicy(
    DeviceConfig agent,
    String workspaceId,
  ) {
    return _clientFor(agent).watchWorkspacePolicy(workspaceId);
  }

  ConversationClient _clientFor(DeviceConfig agent) {
    return _clientRegistry.getOrCreateConversationClientForAgent(agent);
  }
}
