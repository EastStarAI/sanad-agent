import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

class ConversationInputState extends Equatable {
  final bool isProcessing;
  final String? activeSessionId;
  final String? nextMessageProviderId;
  final String? nextMessageModel;
  final String? confirmedNextMessageProviderId;
  final String? confirmedNextMessageModel;
  final String? pendingNextMessageProviderId;
  final String? pendingNextMessageModel;
  final String? nextMessageThinkingMode;
  final List<DeviceWorkspace> availableWorkspaces;
  final DeviceWorkspace? selectedWorkspace;
  final bool isLoadingWorkspaces;
  final bool requiresWorkspace;
  final WorkspacePermissionMode permissionMode;
  final bool isLoadingPermissionMode;
  final DeviceSuspendedRequest? pendingSuspendedRequest;
  final RuntimeNotice? runtimeNotice;
  final SessionExecutionSnapshot? executionSnapshot;
  final SessionAttentionState? attentionState;
  final bool isAwaitingMessageAcceptance;
  final List<CanonicalEvent> queuedMessages;
  final Set<String> queuedMutationRequestIds;
  final Set<String> pendingSteerCancellationRequestIds;
  final String? error;

  const ConversationInputState({
    this.isProcessing = false,
    this.activeSessionId,
    this.nextMessageProviderId,
    this.nextMessageModel,
    this.confirmedNextMessageProviderId,
    this.confirmedNextMessageModel,
    this.pendingNextMessageProviderId,
    this.pendingNextMessageModel,
    this.nextMessageThinkingMode,
    this.availableWorkspaces = const [],
    this.selectedWorkspace,
    this.isLoadingWorkspaces = false,
    this.requiresWorkspace = false,
    this.permissionMode = WorkspacePermissionMode.defaultMode,
    this.isLoadingPermissionMode = false,
    this.pendingSuspendedRequest,
    this.runtimeNotice,
    this.executionSnapshot,
    this.attentionState,
    this.isAwaitingMessageAcceptance = false,
    this.queuedMessages = const [],
    this.queuedMutationRequestIds = const {},
    this.pendingSteerCancellationRequestIds = const {},
    this.error,
  });

  ConversationInputState copyWith({
    bool? isProcessing,
    String? activeSessionId,
    bool clearActiveSessionId = false,
    String? nextMessageProviderId,
    bool clearNextMessageProviderId = false,
    String? nextMessageModel,
    bool clearNextMessageModel = false,
    String? confirmedNextMessageProviderId,
    bool clearConfirmedNextMessageProviderId = false,
    String? confirmedNextMessageModel,
    bool clearConfirmedNextMessageModel = false,
    String? pendingNextMessageProviderId,
    bool clearPendingNextMessageProviderId = false,
    String? pendingNextMessageModel,
    bool clearPendingNextMessageModel = false,
    String? nextMessageThinkingMode,
    bool clearNextMessageThinkingMode = false,
    List<DeviceWorkspace>? availableWorkspaces,
    DeviceWorkspace? selectedWorkspace,
    bool clearSelectedWorkspace = false,
    bool? isLoadingWorkspaces,
    bool? requiresWorkspace,
    WorkspacePermissionMode? permissionMode,
    bool? isLoadingPermissionMode,
    DeviceSuspendedRequest? pendingSuspendedRequest,
    bool clearPendingSuspendedRequest = false,
    RuntimeNotice? runtimeNotice,
    bool clearRuntimeNotice = false,
    SessionExecutionSnapshot? executionSnapshot,
    bool clearExecutionSnapshot = false,
    SessionAttentionState? attentionState,
    bool clearAttentionState = false,
    bool? isAwaitingMessageAcceptance,
    List<CanonicalEvent>? queuedMessages,
    Set<String>? queuedMutationRequestIds,
    Set<String>? pendingSteerCancellationRequestIds,
    String? error,
    bool clearError = false,
  }) {
    return ConversationInputState(
      isProcessing: isProcessing ?? this.isProcessing,
      activeSessionId: clearActiveSessionId ? null : activeSessionId ?? this.activeSessionId,
      nextMessageProviderId: clearNextMessageProviderId ? null : nextMessageProviderId ?? this.nextMessageProviderId,
      nextMessageModel: clearNextMessageModel ? null : nextMessageModel ?? this.nextMessageModel,
      confirmedNextMessageProviderId: clearConfirmedNextMessageProviderId
          ? null
          : confirmedNextMessageProviderId ?? this.confirmedNextMessageProviderId,
      confirmedNextMessageModel: clearConfirmedNextMessageModel
          ? null
          : confirmedNextMessageModel ?? this.confirmedNextMessageModel,
      pendingNextMessageProviderId: clearPendingNextMessageProviderId
          ? null
          : pendingNextMessageProviderId ?? this.pendingNextMessageProviderId,
      pendingNextMessageModel: clearPendingNextMessageModel
          ? null
          : pendingNextMessageModel ?? this.pendingNextMessageModel,
      nextMessageThinkingMode: clearNextMessageThinkingMode
          ? null
          : nextMessageThinkingMode ?? this.nextMessageThinkingMode,
      availableWorkspaces: availableWorkspaces ?? this.availableWorkspaces,
      selectedWorkspace: clearSelectedWorkspace ? null : selectedWorkspace ?? this.selectedWorkspace,
      isLoadingWorkspaces: isLoadingWorkspaces ?? this.isLoadingWorkspaces,
      requiresWorkspace: requiresWorkspace ?? this.requiresWorkspace,
      permissionMode: permissionMode ?? this.permissionMode,
      isLoadingPermissionMode: isLoadingPermissionMode ?? this.isLoadingPermissionMode,
      pendingSuspendedRequest: clearPendingSuspendedRequest
          ? null
          : pendingSuspendedRequest ?? this.pendingSuspendedRequest,
      runtimeNotice: clearRuntimeNotice ? null : runtimeNotice ?? this.runtimeNotice,
      executionSnapshot: clearExecutionSnapshot ? null : executionSnapshot ?? this.executionSnapshot,
      attentionState: clearAttentionState ? null : attentionState ?? this.attentionState,
      isAwaitingMessageAcceptance: isAwaitingMessageAcceptance ?? this.isAwaitingMessageAcceptance,
      queuedMessages: queuedMessages ?? this.queuedMessages,
      queuedMutationRequestIds: queuedMutationRequestIds ?? this.queuedMutationRequestIds,
      pendingSteerCancellationRequestIds: pendingSteerCancellationRequestIds ?? this.pendingSteerCancellationRequestIds,
      error: clearError ? null : error ?? this.error,
    );
  }

  @override
  List<Object?> get props => [
    isProcessing,
    activeSessionId,
    nextMessageProviderId,
    nextMessageModel,
    confirmedNextMessageProviderId,
    confirmedNextMessageModel,
    pendingNextMessageProviderId,
    pendingNextMessageModel,
    nextMessageThinkingMode,
    availableWorkspaces,
    selectedWorkspace,
    isLoadingWorkspaces,
    requiresWorkspace,
    permissionMode,
    isLoadingPermissionMode,
    pendingSuspendedRequest,
    runtimeNotice,
    executionSnapshot,
    attentionState,
    isAwaitingMessageAcceptance,
    queuedMessages,
    queuedMutationRequestIds,
    pendingSteerCancellationRequestIds,
    error,
  ];
}
