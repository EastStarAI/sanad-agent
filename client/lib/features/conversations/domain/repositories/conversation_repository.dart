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

abstract class ConversationRepository {
  Stream<List<Session>> watchSessions(DeviceConfig agent);
  Stream<Session> watchSessionCreated(DeviceConfig agent);
  Stream<DeviceProcessingSnapshot> watchProcessing(DeviceConfig agent);
  Stream<List<CanonicalEvent>> watchMessages(DeviceConfig agent);
  Stream<List<CanonicalEvent>> watchQueuedMessages(DeviceConfig agent);
  Stream<DeviceSuspendedRequest?> watchPendingSuspension(DeviceConfig agent);
  Stream<RuntimeNotice?> watchRuntimeNotice(DeviceConfig agent);
  Stream<StopDraftRecovery> watchStopRecoveries(DeviceConfig agent);
  Stream<Map<String, SessionAttentionState>> watchAttentionStates(
    DeviceConfig agent,
  ) => const Stream<Map<String, SessionAttentionState>>.empty();
  Stream<Map<String, SessionRouteSnapshot>> watchRouteSnapshots(
    DeviceConfig agent,
  ) => const Stream<Map<String, SessionRouteSnapshot>>.empty();

  List<CanonicalEvent> currentMessages(DeviceConfig agent);
  List<CanonicalEvent> currentQueuedMessages(DeviceConfig agent);
  bool isProcessing(DeviceConfig agent);
  bool isCurrentConversationProcessing(DeviceConfig agent);
  bool isSessionProcessing(DeviceConfig agent, String? sessionId);
  DeviceSuspendedRequest? currentPendingSuspendedRequest(DeviceConfig agent);
  RuntimeNotice? currentRuntimeNotice(DeviceConfig agent);
  Map<String, SessionAttentionState> currentAttentionStates(
    DeviceConfig agent,
  ) => const {};
  Map<String, SessionRouteSnapshot> currentRouteSnapshots(
    DeviceConfig agent,
  ) => const {};

  void activateSession(DeviceConfig agent, String sessionId);
  void beginNewSession(DeviceConfig agent);
  Future<Session> createSession(
    DeviceConfig agent, {
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  });

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
  });
  Future<void> steerMessage(
    DeviceConfig agent,
    String message, {
    required String requestId,
    required String sessionId,
  });
  Future<String?> deleteQueuedMessage(DeviceConfig agent, {required String requestId, required String sessionId});
  Future<String?> cancelPendingSteer(DeviceConfig agent, {required String requestId, required String sessionId});
  Future<String?> stop(
    DeviceConfig agent, {
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  });
  Future<String?> claimStopRecovery(
    DeviceConfig agent, {
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  });
  Future<void> acknowledgeStopRecovery(
    DeviceConfig agent, {
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  });
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
    outcome: 'unsupported',
    safety: TurnReplaySafety.unknown,
    requiresConfirmation: false,
  );
  Future<SessionCompactResult> compactSession(
    DeviceConfig agent, {
    required String sessionId,
  }) async => const SessionCompactResult(outcome: 'unsupported');
  Future<void> retryRuntimeNotice(
    DeviceConfig agent, {
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  });
  Future<void> continueWithProvider(
    DeviceConfig agent, {
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  });
  Future<void> updateSessionPreferences(
    DeviceConfig agent, {
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  });
  Future<SessionQueryResult> getSessions(DeviceConfig agent, {SessionQueryRequest? query});
  Future<SessionQueryResult> refreshSessions(DeviceConfig agent, {SessionQueryRequest? query});
  Future<List<DeviceWorkspace>> getWorkspaces(DeviceConfig agent);
  Future<List<SlashCommandEntry>> searchSlashCommands(
    DeviceConfig agent, {
    String? query,
    String? workspaceId,
  });
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree(
    DeviceConfig agent, {
    String? workspaceId,
    String? path,
  });
  Future<DeviceWorkspace> createWorkspace(
    DeviceConfig agent, {
    required String path,
    String? name,
  });
  Future<DeviceWorkspace> renameWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String displayName,
  });
  Future<DeviceWorkspace> relocateWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String newPath,
  });
  Future<void> createFolder(
    DeviceConfig agent, {
    required String parentPath,
    required String name,
  });
  Future<void> renameFolder(
    DeviceConfig agent, {
    required String path,
    required String newName,
  });
  Future<void> deleteFolder(
    DeviceConfig agent, {
    required String path,
  });
  Future<List<CanonicalEvent>> loadSessionHistory(DeviceConfig agent, String sessionId);
  Future<void> updateSessionTitle(DeviceConfig agent, String sessionId, String title);
  Future<void> deleteSession(DeviceConfig agent, String sessionId);
  Future<void> respondToSuspendedRequest(
    DeviceConfig agent,
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  });
  Future<WorkspacePolicy> getWorkspacePolicy(DeviceConfig agent, String workspacePath);
  Future<WorkspacePolicy> setWorkspacePermissionMode(
    DeviceConfig agent, {
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  });
  Stream<WorkspacePolicy> watchWorkspacePolicy(DeviceConfig agent, String workspaceId);
}
