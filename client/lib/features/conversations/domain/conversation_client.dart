import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
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
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

abstract class ConversationClient {
  DeviceConfig get config;
  bool get isConnected;
  Stream<List<Session>> get sessions;
  Stream<Session> get sessionCreated;
  Stream<DeviceProcessingSnapshot> get processing;
  Stream<List<CanonicalEvent>> get messages;
  Stream<List<CanonicalEvent>> get queuedMessages;
  Stream<DeviceSuspendedRequest?> get pendingSuspendedRequest;
  Stream<RuntimeNotice?> get runtimeNotice;
  Stream<StopDraftRecovery> get stopRecoveries;
  Stream<Map<String, SessionAttentionState>> get attentionStates =>
      const Stream<Map<String, SessionAttentionState>>.empty();
  Stream<Map<String, SessionRouteSnapshot>> get routeSnapshots =>
      const Stream<Map<String, SessionRouteSnapshot>>.empty();

  List<CanonicalEvent> get currentMessages;
  List<CanonicalEvent> get currentQueuedMessages;
  bool get isProcessing;
  bool get isCurrentConversationProcessing;
  DeviceSuspendedRequest? get currentPendingSuspendedRequest;
  RuntimeNotice? get currentRuntimeNotice;
  Map<String, SessionAttentionState> get currentAttentionStates => const {};
  Map<String, SessionRouteSnapshot> get currentRouteSnapshots => const {};

  bool isSessionProcessing(String? sessionId);
  void activateSession(String sessionId);
  void beginNewSession();
  Future<Session> createSession({
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  });

  Future<String?> sendMessage(
    String message, {
    String? sessionId,
    String? workspaceId,
    String? context,
    String? providerId,
    String? model,
    String? thinkingMode,
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  });
  Future<void> steerMessage(
    String message, {
    required String requestId,
    required String sessionId,
  });
  Future<String?> deleteQueuedMessage({required String requestId, required String sessionId});
  Future<String?> cancelPendingSteer({required String requestId, required String sessionId});
  Future<String?> stop({
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  });
  Future<String?> claimStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  });
  Future<void> acknowledgeStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  });
  Future<TurnReplayResult> replayTurn({
    required String sessionId,
    required String targetRequestId,
    required TurnReplayAction action,
    String? message,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
    bool confirmedReplayUnsafe = false,
  }) async => const TurnReplayResult(
    outcome: 'unsupported',
    safety: TurnReplaySafety.unknown,
    requiresConfirmation: false,
  );
  Future<SessionCompactResult> compactSession({
    required String sessionId,
  }) async => const SessionCompactResult(outcome: 'unsupported');
  Future<void> retryRuntimeNotice({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  });
  Future<void> continueWithProvider({
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  });
  Future<void> updateSessionPreferences({
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  });
  Future<SessionQueryResult> getSessions({SessionQueryRequest? query});
  Future<SessionQueryResult> refreshSessions({SessionQueryRequest? query});
  Future<List<DeviceWorkspace>> getWorkspaces();
  Future<List<SlashCommandEntry>> searchSlashCommands({
    String? query,
    String? workspaceId,
  });
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({
    String? workspaceId,
    String? path,
  });
  Future<DeviceWorkspace> createWorkspace({
    required String path,
    String? name,
  });
  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  });
  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  });
  Future<void> createFolder({
    required String parentPath,
    required String name,
  });
  Future<void> renameFolder({required String path, required String newName});
  Future<void> deleteFolder({required String path});
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId);
  Future<void> updateSessionTitle(String sessionId, String title);
  Future<void> deleteSession(String sessionId);
  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  });
  Future<WorkspacePolicy> getWorkspacePolicy(String workspacePath);
  Future<WorkspacePolicy> setWorkspacePermissionMode({
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  });
  Stream<WorkspacePolicy> watchWorkspacePolicy(String workspaceId);
}

abstract class ConversationClientRegistry {
  ConversationClient getOrCreateConversationClientForAgent(DeviceConfig config);
}

abstract class ManagedConversationClientRegistry implements ConversationClientRegistry {
  void retainClientsFor(List<DeviceConfig> agents);
  void clear();
  void dispose();
}
