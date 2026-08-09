import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:flutter/foundation.dart';

@immutable
class ConversationInputAgentSlice {
  final DeviceConfig? activeAgent;
  final List<DeviceConfig> agents;

  const ConversationInputAgentSlice({
    required this.activeAgent,
    required this.agents,
  });

  bool get hasActiveAgent => activeAgent != null;
  bool get isOnline => activeAgent?.isOnline ?? false;
  String? get capabilityAgentId => activeAgent?.id;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConversationInputAgentSlice &&
        other.activeAgent == activeAgent &&
        _sameAgents(other.agents, agents);
  }

  @override
  int get hashCode => Object.hash(
    activeAgent,
    Object.hashAll(agents.map((agent) => Object.hash(agent.id, agent.name, agent.isOnline))),
  );

  static bool _sameAgents(List<DeviceConfig> a, List<DeviceConfig> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

@immutable
class ConversationInputSlice {
  final bool isProcessing;
  final String? nextMessageModel;
  final String? nextMessageProviderId;
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

  const ConversationInputSlice({
    required this.isProcessing,
    required this.nextMessageModel,
    required this.nextMessageProviderId,
    required this.nextMessageThinkingMode,
    required this.availableWorkspaces,
    required this.selectedWorkspace,
    required this.isLoadingWorkspaces,
    required this.requiresWorkspace,
    required this.permissionMode,
    required this.isLoadingPermissionMode,
    required this.pendingSuspendedRequest,
    required this.runtimeNotice,
    this.executionSnapshot,
    this.attentionState,
    this.isAwaitingMessageAcceptance = false,
    required this.queuedMessages,
    this.queuedMutationRequestIds = const {},
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConversationInputSlice &&
        other.isProcessing == isProcessing &&
        other.nextMessageModel == nextMessageModel &&
        other.nextMessageProviderId == nextMessageProviderId &&
        other.nextMessageThinkingMode == nextMessageThinkingMode &&
        other.isLoadingWorkspaces == isLoadingWorkspaces &&
        other.requiresWorkspace == requiresWorkspace &&
        other.permissionMode == permissionMode &&
        other.isLoadingPermissionMode == isLoadingPermissionMode &&
        other.pendingSuspendedRequest == pendingSuspendedRequest &&
        other.runtimeNotice == runtimeNotice &&
        other.executionSnapshot == executionSnapshot &&
        other.attentionState == attentionState &&
        other.isAwaitingMessageAcceptance == isAwaitingMessageAcceptance &&
        other.selectedWorkspace == selectedWorkspace &&
        _sameWorkspaces(other.availableWorkspaces, availableWorkspaces) &&
        _sameMessages(other.queuedMessages, queuedMessages) &&
        setEquals(other.queuedMutationRequestIds, queuedMutationRequestIds);
  }

  @override
  int get hashCode => Object.hash(
    isProcessing,
    nextMessageModel,
    nextMessageProviderId,
    nextMessageThinkingMode,
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
    Object.hashAll(availableWorkspaces),
    Object.hashAll(queuedMessages),
    Object.hashAllUnordered(queuedMutationRequestIds),
  );

  static bool _sameWorkspaces(List<DeviceWorkspace> a, List<DeviceWorkspace> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameMessages(List<CanonicalEvent> a, List<CanonicalEvent> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
