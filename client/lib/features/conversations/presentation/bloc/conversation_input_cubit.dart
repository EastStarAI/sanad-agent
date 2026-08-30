import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';

import 'conversation_input_state.dart';
import 'session_messages_cubit.dart';
import 'session_messages_state.dart';

class ConversationInputCubit extends Cubit<ConversationInputState> {
  static const missingProviderModelError = 'Select a provider and model before sending a message.';

  final SessionMessagesCubit messagesCubit;
  StreamSubscription? _messagesSubscription;

  ConversationInputCubit({
    required this.messagesCubit,
  }) : super(_stateFromMessages(messagesCubit.state)) {
    _messagesSubscription = messagesCubit.stream.listen((state) {
      emit(
        _stateFromMessages(
          state,
          isAwaitingMessageAcceptance: this.state.isAwaitingMessageAcceptance,
        ),
      );
    });
  }

  void setMessageAcceptancePending(bool isPending) {
    if (state.isAwaitingMessageAcceptance == isPending) return;
    emit(state.copyWith(isAwaitingMessageAcceptance: isPending));
  }

  Future<void> sendMessage(String text, {MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) return;
    if (state.pendingSuspendedRequest != null) {
      emit(
        state.copyWith(
          error: 'Resolve the pending clarifying question or permission request before sending another message.',
        ),
      );
      return;
    }
    if (!_hasText(state.nextMessageProviderId) || !_hasText(state.nextMessageModel)) {
      emit(state.copyWith(error: missingProviderModelError));
      return;
    }
    if (state.requiresWorkspace && state.selectedWorkspace == null) {
      emit(state.copyWith(error: 'Select a workspace before sending your first Sanad Agent message.'));
      return;
    }

    try {
      await messagesCubit.sendMessage(trimmedText, intent: intent);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  /// Applies the daemon-owned route, preserving user intent unless the caller
  /// has just completed provider setup and owns the authoritative replacement.
  void initializeProviderSelection({
    String? providerId,
    String? model,
    bool replaceExisting = false,
  }) {
    if (!replaceExisting && _hasText(state.nextMessageProviderId) && _hasText(state.nextMessageModel)) {
      return;
    }
    if (!_hasText(providerId) || !_hasText(model)) return;
    messagesCubit.setNextMessagePreferences(
      providerId: providerId!.trim(),
      model: model!.trim(),
    );
  }

  static bool _hasText(String? value) => value?.trim().isNotEmpty == true;

  Future<void> steerMessage(String text, {required String requestId}) async {
    try {
      await messagesCubit.steerMessage(text, requestId: requestId);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> deleteQueuedMessage({required String requestId}) =>
      messagesCubit.deleteQueuedMessage(requestId: requestId);

  Future<void> cancelPendingSteer({required String requestId}) =>
      messagesCubit.cancelPendingSteer(requestId: requestId);

  Future<void> stop() async {
    await messagesCubit.stop();
  }

  Future<TurnReplayResult> replayTurn({
    required String targetRequestId,
    required TurnReplayAction action,
    String? message,
    bool confirmedReplayUnsafe = false,
  }) async {
    try {
      return await messagesCubit.replayTurn(
        targetRequestId: targetRequestId,
        action: action,
        message: message,
        confirmedReplayUnsafe: confirmedReplayUnsafe,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return const TurnReplayResult(
        outcome: 'failed',
        safety: TurnReplaySafety.unknown,
        requiresConfirmation: false,
      );
    }
  }

  Future<SessionCompactResult> compactSession() async {
    try {
      return await messagesCubit.compactSession();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return const SessionCompactResult(outcome: 'failed');
    }
  }

  Future<void> retryRuntimeNotice() async {
    try {
      await messagesCubit.retryRuntimeNotice();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> continueWithProvider({
    required String providerInstanceId,
    String? modelId,
  }) async {
    try {
      await messagesCubit.continueWithProvider(
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> approvePendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    required String scope,
  }) async {
    try {
      await messagesCubit.respondToSuspendedRequest(
        request,
        allow: true,
        scope: scope,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> denyPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    String? comment,
  }) async {
    try {
      await messagesCubit.respondToSuspendedRequest(
        request,
        allow: false,
        scope: request.scope,
        comment: comment,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> answerPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    required String answer,
  }) async {
    try {
      await messagesCubit.respondToSuspendedRequest(
        request,
        allow: true,
        answer: answer,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> updateSessionPreferences({
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    try {
      await messagesCubit.updateSessionPreferences(
        providerId: providerId,
        model: model,
        thinkingMode: thinkingMode,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void restoreNewConversationPreferences({
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    messagesCubit.replaceNextMessagePreferences(
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
    );
  }

  Future<void> selectModel({
    required CapabilityValueScope scope,
    String? providerId,
    String? model,
  }) async {
    try {
      if (state.runtimeNotice != null) {
        messagesCubit.setNextMessagePreferences(
          providerId: providerId,
          model: model,
        );
        return;
      }

      switch (scope) {
        case CapabilityValueScope.session:
          messagesCubit.stagePendingRouteSelection(
            providerId: providerId,
            model: model,
          );
          await messagesCubit.updateSessionPreferences(
            providerId: providerId,
            model: model,
          );
          break;
        case CapabilityValueScope.message:
          messagesCubit.setNextMessagePreferences(
            providerId: providerId,
            model: model,
          );
          break;
        case CapabilityValueScope.none:
          break;
      }
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> selectThinkingMode({
    required CapabilityValueScope scope,
    String? thinkingMode,
  }) async {
    try {
      // Always update local preference first (for UI and persistence)
      messagesCubit.setNextMessagePreferences(thinkingMode: thinkingMode);

      switch (scope) {
        case CapabilityValueScope.session:
          await messagesCubit.updateSessionPreferences(thinkingMode: thinkingMode);
          break;
        case CapabilityValueScope.message:
          // Already handled by setNextMessagePreferences
          break;
        case CapabilityValueScope.none:
          break;
      }
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void clearError() {
    emit(state.copyWith(clearError: true));
  }

  Future<void> refreshWorkspaces() async {
    try {
      await messagesCubit.refreshWorkspaces();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void selectWorkspace(DeviceWorkspace workspace) {
    messagesCubit.selectWorkspace(workspace);
  }

  void clearWorkspace() {
    messagesCubit.clearWorkspace();
  }

  Future<List<SlashCommandEntry>> searchSlashCommands({String? query}) {
    return messagesCubit.searchSlashCommands(query: query);
  }

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({String? path}) {
    return messagesCubit.browseWorkspaceTree(path: path);
  }

  Future<DeviceWorkspace?> createWorkspace({
    required String path,
    String? name,
  }) async {
    try {
      return await messagesCubit.createWorkspace(path: path, name: name);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return null;
    }
  }

  Future<void> setWorkspacePermissionMode(WorkspacePermissionMode permissionMode) async {
    try {
      await messagesCubit.setWorkspacePermissionMode(permissionMode);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  static ConversationInputState _stateFromMessages(
    SessionMessagesState state, {
    bool isAwaitingMessageAcceptance = false,
  }) {
    return ConversationInputState(
      isProcessing: state.isProcessing,
      activeSessionId: state.activeSessionId,
      nextMessageProviderId: state.nextMessageProviderId,
      nextMessageModel: state.nextMessageModel,
      confirmedNextMessageProviderId: state.confirmedNextMessageProviderId,
      confirmedNextMessageModel: state.confirmedNextMessageModel,
      pendingNextMessageProviderId: state.pendingNextMessageProviderId,
      pendingNextMessageModel: state.pendingNextMessageModel,
      nextMessageThinkingMode: state.nextMessageThinkingMode,
      availableWorkspaces: state.availableWorkspaces,
      selectedWorkspace: state.selectedWorkspace,
      isLoadingWorkspaces: state.isLoadingWorkspaces,
      requiresWorkspace: state.requiresWorkspace,
      permissionMode: state.permissionMode,
      isLoadingPermissionMode: state.isLoadingPermissionMode,
      pendingSuspendedRequest: state.pendingSuspendedRequest,
      runtimeNotice: state.runtimeNotice,
      executionSnapshot: state.executionSnapshot,
      attentionState: state.attentionState,
      isAwaitingMessageAcceptance: isAwaitingMessageAcceptance,
      queuedMessages: state.queuedMessages,
      queuedMutationRequestIds: state.queuedMutationRequestIds,
      pendingSteerCancellationRequestIds: state.pendingSteerCancellationRequestIds,
      error: state.error,
    );
  }

  @override
  Future<void> close() async {
    await _messagesSubscription?.cancel();
    return super.close();
  }
}
