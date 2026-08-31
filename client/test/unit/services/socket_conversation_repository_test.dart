import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/data/repositories/socket_conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);

  test('watchSessions stays alive when initial fetch fails and later stream update arrives', () async {
    final client = _TestConversationClient()
      ..connected = true
      ..getSessionsError = StateError('bootstrap failed');
    final repository = SocketConversationRepository(_TestConversationClientRegistry(client));

    final streamFuture = repository.watchSessions(agent).first;

    await Future<void>.delayed(Duration.zero);
    client.emitSessions([
      Session(
        id: 'session-1',
        title: 'Recovered session',
        deviceId: agent.id,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    ]);

    final result = await streamFuture;
    expect(result, hasLength(1));
    expect(result.single.title, 'Recovered session');
  });

  test('getWorkspacePolicy forwards to client', () async {
    final client = _TestConversationClient();
    final repository = SocketConversationRepository(_TestConversationClientRegistry(client));
    client.mockPolicy = const WorkspacePolicy(permissionMode: WorkspacePermissionMode.fullAccess);

    final policy = await repository.getWorkspacePolicy(agent, '/path');
    expect(policy.permissionMode, WorkspacePermissionMode.fullAccess);
    expect(client.lastGetWorkspacePolicyPath, '/path');
  });

  test('setWorkspacePermissionMode forwards to client', () async {
    final client = _TestConversationClient();
    final repository = SocketConversationRepository(_TestConversationClientRegistry(client));
    client.mockPolicy = const WorkspacePolicy(permissionMode: WorkspacePermissionMode.fullAccess);

    final policy = await repository.setWorkspacePermissionMode(
      agent,
      workspaceId: 'ws-1',
      workspacePath: '/path',
      mode: WorkspacePermissionMode.fullAccess,
    );
    expect(policy.permissionMode, WorkspacePermissionMode.fullAccess);
    expect(client.lastSetWorkspacePermissionModeId, 'ws-1');
    expect(client.lastSetWorkspacePermissionModePath, '/path');
    expect(client.lastSetWorkspacePermissionModeMode, WorkspacePermissionMode.fullAccess);
  });
}

class _TestConversationClientRegistry implements ConversationClientRegistry {
  final ConversationClient client;

  _TestConversationClientRegistry(this.client);

  @override
  ConversationClient getOrCreateConversationClientForAgent(DeviceConfig config) => client;
}

class _TestConversationClient implements ConversationClient {
  final _sessionsController = StreamController<List<Session>>.broadcast();
  final _policyController = StreamController<WorkspacePolicy>.broadcast();
  bool connected = false;
  Object? getSessionsError;

  WorkspacePolicy mockPolicy = const WorkspacePolicy();
  String? lastGetWorkspacePolicyPath;
  String? lastSetWorkspacePermissionModeId;
  String? lastSetWorkspacePermissionModePath;
  WorkspacePermissionMode? lastSetWorkspacePermissionModeMode;

  void emitSessions(List<Session> sessions) {
    _sessionsController.add(sessions);
  }

  @override
  DeviceConfig get config => DeviceConfig(id: 'agent-1', name: 'SanadAgent');

  @override
  bool get isConnected => connected;

  @override
  Stream<List<Session>> get sessions => _sessionsController.stream;

  @override
  Stream<Session> get sessionCreated => const Stream.empty();

  @override
  Stream<DeviceProcessingSnapshot> get processing => const Stream.empty();

  @override
  Stream<List<CanonicalEvent>> get messages => const Stream.empty();

  @override
  Stream<List<CanonicalEvent>> get queuedMessages => const Stream.empty();

  @override
  Stream<DeviceSuspendedRequest?> get pendingSuspendedRequest => const Stream.empty();

  @override
  Stream<RuntimeNotice?> get runtimeNotice => const Stream.empty();

  @override
  Stream<StopDraftRecovery> get stopRecoveries => const Stream.empty();

  @override
  Stream<Map<String, SessionAttentionState>> get attentionStates => const Stream.empty();

  @override
  Stream<Map<String, SessionRouteSnapshot>> get routeSnapshots => const Stream.empty();

  @override
  List<CanonicalEvent> get currentMessages => const [];

  @override
  List<CanonicalEvent> get currentQueuedMessages => const [];

  @override
  bool get isProcessing => false;

  @override
  bool get isCurrentConversationProcessing => false;

  @override
  DeviceSuspendedRequest? get currentPendingSuspendedRequest => null;

  @override
  RuntimeNotice? get currentRuntimeNotice => null;

  @override
  Map<String, SessionAttentionState> get currentAttentionStates => const {};

  @override
  Map<String, SessionRouteSnapshot> get currentRouteSnapshots => const {};

  @override
  void activateSession(String sessionId) {}

  @override
  void beginNewSession() {}

  @override
  Future<Session> createSession({
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSession(String sessionId) {
    throw UnimplementedError();
  }

  @override
  Future<SessionQueryResult> getSessions({SessionQueryRequest? query}) async {
    final error = getSessionsError;
    if (error != null) {
      throw error;
    }
    return SessionQueryResult(sessions: const [], hasMore: false);
  }

  @override
  Future<List<DeviceWorkspace>> getWorkspaces() {
    throw UnimplementedError();
  }

  @override
  bool isSessionProcessing(String? sessionId) => false;

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) {
    throw UnimplementedError();
  }

  @override
  Future<List<SlashCommandEntry>> searchSlashCommands({String? query, String? workspaceId}) {
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<void> steerMessage(
    String message, {
    required String requestId,
    required String sessionId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String?> deleteQueuedMessage({required String requestId, required String sessionId}) async => null;

  @override
  Future<String?> cancelPendingSteer({required String requestId, required String sessionId}) async => null;

  @override
  Future<String?> stop({
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String?> claimStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  }) async => commandRequestId ?? 'claim-$stopRequestId';

  @override
  Future<void> acknowledgeStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  }) async {}

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
  }) async => const TurnReplayResult(
    outcome: 'accepted',
    safety: TurnReplaySafety.safe,
    requiresConfirmation: false,
  );

  @override
  Future<SessionCompactResult> compactSession({
    required String sessionId,
  }) async => const SessionCompactResult(outcome: 'accepted');

  @override
  Future<SessionForkResult> forkSession({
    required String sessionId,
    required String targetMessageId,
    required String targetTurnId,
  }) async => const SessionForkResult(outcome: 'accepted');

  @override
  Future<void> retryRuntimeNotice({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> continueWithProvider({
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateSessionPreferences({
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateSessionTitle(String sessionId, String title) {
    throw UnimplementedError();
  }

  @override
  Future<SessionQueryResult> refreshSessions({SessionQueryRequest? query}) {
    throw UnimplementedError();
  }

  @override
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({String? workspaceId, String? path}) {
    throw UnimplementedError();
  }

  @override
  Future<DeviceWorkspace> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> removeWorkspace({required String workspaceId}) async {
    throw UnimplementedError();
  }

  @override
  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> createFolder({
    required String parentPath,
    required String name,
  }) async {}

  @override
  Future<void> renameFolder({required String path, required String newName}) async {}

  @override
  Future<void> deleteFolder({required String path}) async {}

  @override
  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WorkspacePolicy> getWorkspacePolicy(String workspacePath) async {
    lastGetWorkspacePolicyPath = workspacePath;
    return mockPolicy;
  }

  @override
  Future<WorkspacePolicy> setWorkspacePermissionMode({
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  }) async {
    lastSetWorkspacePermissionModeId = workspaceId;
    lastSetWorkspacePermissionModePath = workspacePath;
    lastSetWorkspacePermissionModeMode = mode;
    final updated = mockPolicy.copyWith(permissionMode: mode);
    _policyController.add(updated);
    return updated;
  }

  @override
  Stream<WorkspacePolicy> watchWorkspacePolicy(String workspaceId) {
    return _policyController.stream;
  }
}
