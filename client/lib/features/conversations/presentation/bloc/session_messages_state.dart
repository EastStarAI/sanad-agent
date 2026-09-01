import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:equatable/equatable.dart';

class SessionMessagesState extends Equatable {
  final List<CanonicalEvent> messages;
  final List<CanonicalEvent> queuedMessages;
  final Set<String> queuedMutationRequestIds;
  final Set<String> pendingSteerCancellationRequestIds;
  final bool isProcessing;
  final String? error;
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
  final String? requestedSessionId;
  final bool isHistoryLoading;
  final String? historyLoadError;
  final bool showDelayedLoading;
  final bool hasOlderHistory;
  final bool isOlderHistoryLoading;
  final String? olderHistoryError;

  const SessionMessagesState({
    this.messages = const [],
    this.queuedMessages = const [],
    this.queuedMutationRequestIds = const {},
    this.pendingSteerCancellationRequestIds = const {},
    this.isProcessing = false,
    this.error,
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
    this.requestedSessionId,
    this.isHistoryLoading = false,
    this.historyLoadError,
    this.showDelayedLoading = false,
    this.hasOlderHistory = false,
    this.isOlderHistoryLoading = false,
    this.olderHistoryError,
  });

  SessionMessagesState copyWith({
    List<CanonicalEvent>? messages,
    List<CanonicalEvent>? queuedMessages,
    Set<String>? queuedMutationRequestIds,
    Set<String>? pendingSteerCancellationRequestIds,
    bool? isProcessing,
    String? error,
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
    String? requestedSessionId,
    bool clearRequestedSessionId = false,
    bool? isHistoryLoading,
    String? historyLoadError,
    bool clearHistoryLoadError = false,
    bool? showDelayedLoading,
    bool? hasOlderHistory,
    bool? isOlderHistoryLoading,
    String? olderHistoryError,
    bool clearOlderHistoryError = false,
  }) {
    return SessionMessagesState(
      messages: messages ?? this.messages,
      queuedMessages: queuedMessages ?? this.queuedMessages,
      queuedMutationRequestIds: queuedMutationRequestIds ?? this.queuedMutationRequestIds,
      pendingSteerCancellationRequestIds: pendingSteerCancellationRequestIds ?? this.pendingSteerCancellationRequestIds,
      isProcessing: isProcessing ?? this.isProcessing,
      error: error, // Can be nullified
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
      requestedSessionId: clearRequestedSessionId ? null : requestedSessionId ?? this.requestedSessionId,
      isHistoryLoading: isHistoryLoading ?? this.isHistoryLoading,
      historyLoadError: clearHistoryLoadError ? null : historyLoadError ?? this.historyLoadError,
      showDelayedLoading: showDelayedLoading ?? this.showDelayedLoading,
      hasOlderHistory: hasOlderHistory ?? this.hasOlderHistory,
      isOlderHistoryLoading: isOlderHistoryLoading ?? this.isOlderHistoryLoading,
      olderHistoryError: clearOlderHistoryError ? null : olderHistoryError ?? this.olderHistoryError,
    );
  }

  ConversationVisualState get visualState {
    if (activeSessionId != null) {
      return ConversationVisualState.activeSession;
    }
    if (requestedSessionId != null || isHistoryLoading || historyLoadError != null) {
      return ConversationVisualState.loadingTransition;
    }
    return ConversationVisualState.newConversation;
  }

  @override
  List<Object?> get props => [
    messages,
    queuedMessages,
    queuedMutationRequestIds,
    pendingSteerCancellationRequestIds,
    isProcessing,
    error,
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
    requestedSessionId,
    isHistoryLoading,
    historyLoadError,
    showDelayedLoading,
    hasOlderHistory,
    isOlderHistoryLoading,
    olderHistoryError,
  ];
}
