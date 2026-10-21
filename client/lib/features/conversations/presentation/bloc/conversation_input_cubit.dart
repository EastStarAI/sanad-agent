import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'package:sanad_client/features/conversations/presentation/bloc/session_workspace_coordinator.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
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
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';

import 'conversation_input_state.dart';
import 'session_messages_cubit.dart';
import 'session_messages_state.dart';

class ConversationInputCubit extends Cubit<ConversationInputState> {
  static const missingProviderModelError = 'Select a provider and model before sending a message.';

  final SessionMessagesCubit messagesCubit;
  StreamSubscription? _messagesSubscription;
  /// Draft attachments per device/session scope. The attachment error is
  /// transient feedback and is deliberately not part of this cache.
  final Map<String, List<DraftAttachment>> _draftsByScope = {};
  String _draftScope = '';

  ConversationInputCubit({
    required this.messagesCubit,
  }) : super(_stateFromMessages(messagesCubit.state)) {
    _messagesSubscription = messagesCubit.stream.listen((state) {
      emit(
        _stateFromMessages(
          state,
          isAwaitingMessageAcceptance: this.state.isAwaitingMessageAcceptance,
        ).copyWith(
          draftAttachments: this.state.draftAttachments,
          attachmentError: this.state.attachmentError,
        ),
      );
    });
  }

  /// The draft scope key for a device/session (New conversation when
  /// [sessionId] is empty).
  static String draftScopeKey({required String? deviceId, required String? sessionId}) =>
      '${deviceId ?? ''}\u0000${sessionId ?? ''}';

  /// The draft scope the composer is currently bound to.
  String get draftScope => _draftScope;

  void setDraftScope({required String? deviceId, required String? sessionId}) {
    final nextScope = draftScopeKey(deviceId: deviceId, sessionId: sessionId);
    if (nextScope == _draftScope) return;
    if (_draftScope.isNotEmpty) {
      _draftsByScope[_draftScope] = state.draftAttachments;
    }
    _draftScope = nextScope;
    emit(
      state.copyWith(
        draftAttachments: _draftsByScope[nextScope] ?? const [],
        clearAttachmentError: true,
      ),
    );
  }

  void setMessageAcceptancePending(bool isPending) {
    if (state.isAwaitingMessageAcceptance == isPending) return;
    emit(state.copyWith(isAwaitingMessageAcceptance: isPending));
  }

  Future<void> addDraftAttachment({
    required String name,
    required Uint8List bytes,
    required DraftAttachmentSource source,
    required Capability capability,
    String? scope,
  }) async {
    // A multi-file paste/drop completes into the scope that started it, even
    // when the composer rebinds to another conversation while files are read.
    final target = scope ?? _draftScope;
    final current = _scopeAttachments(target);
    final rejection = DraftAttachmentPolicy.check(
      capability: capability,
      existingCount: current.length,
      existingBytes: current.fold<int>(0, (sum, item) => sum + item.sizeBytes),
      nextBytes: bytes.length,
    );
    if (rejection != null) {
      if (target == _draftScope) emit(state.copyWith(attachmentError: rejection));
      return;
    }
    // The same file pasted or dropped twice stays one attachment.
    if (_containsSameContent(current, bytes)) return;
    final item = DraftAttachment(
      id: const Uuid().v4(),
      name: _safeDraftName(name),
      bytes: bytes,
      source: source,
    );
    _setScopeAttachments(target, [...current, item]);
    if (target == _draftScope) emit(state.copyWith(clearAttachmentError: true));
    await Future<void>.delayed(Duration.zero);
    if (isClosed) return;
    _setScopeAttachments(target, [
      for (final attachment in _scopeAttachments(target))
        attachment.id == item.id
            ? attachment.copyWith(
                status: DraftAttachmentStatus.ready,
                clearError: true,
              )
            : attachment,
    ]);
  }

  void removeDraftAttachment(String id) {
    emit(
      state.copyWith(
        draftAttachments: List.unmodifiable(
          state.draftAttachments.where((attachment) => attachment.id != id),
        ),
        clearAttachmentError: true,
      ),
    );
  }

  void setAttachmentError(DraftAttachmentError error) {
    emit(state.copyWith(attachmentError: error));
  }

  void clearAttachmentError() {
    emit(state.copyWith(clearAttachmentError: true));
  }

  void retryDraftAttachment(String id) {
    emit(
      state.copyWith(
        draftAttachments: List.unmodifiable([
          for (final attachment in state.draftAttachments)
            attachment.id == id
                ? attachment.copyWith(
                    status: DraftAttachmentStatus.ready,
                    clearError: true,
                  )
                : attachment,
        ]),
        clearAttachmentError: true,
      ),
    );
  }

  static bool _containsSameContent(List<DraftAttachment> attachments, Uint8List bytes) {
    final sameSize = attachments.where((item) => item.bytes.length == bytes.length).toList(growable: false);
    if (sameSize.isEmpty) return false;
    final digest = sha256.convert(bytes);
    return sameSize.any((item) => sha256.convert(item.bytes) == digest);
  }

  static String _safeDraftName(String input) {
    final name = input.split(RegExp(r'[/\\]')).last.trim();
    return name.isEmpty || name == '.' || name == '..' ? 'attachment' : name;
  }

  /// The route whose resolved thinking control cannot carry a selection.
  ///
  /// Published by the route's thinking selector once it resolves the
  /// authoritative descriptor (`noControl` or `unknown`). It is not emitted as
  /// state and never touches stored thinking preferences.
  ({String providerId, String modelId})? _routeWithoutThinkingControl;

  /// Records whether the resolved thinking control for the route
  /// [providerId]/[modelId] can carry a user selection.
  void reportRouteThinkingAdmission({
    required String? providerId,
    required String? modelId,
    required bool admitsSelection,
  }) {
    final provider = providerId?.trim();
    final model = modelId?.trim();
    if (provider == null || provider.isEmpty || model == null || model.isEmpty) {
      return;
    }
    _routeWithoutThinkingControl = admitsSelection ? null : (providerId: provider, modelId: model);
  }

  /// Whether the next send targets a route whose control offers no selection,
  /// so the hidden carried-over thinking value must not be sent or persisted.
  bool _routeOmitsThinking() {
    final route = _routeWithoutThinkingControl;
    return route != null &&
        route.providerId == state.nextMessageProviderId?.trim() &&
        route.modelId == state.nextMessageModel?.trim();
  }

  Future<void> sendMessage(String text, {MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) async {
    final trimmedText = text.trim();
    final attachments = state.draftAttachments;
    final submittedScope = _draftScope;
    final submittedIds = attachments.map((attachment) => attachment.id).toSet();
    if (trimmedText.isEmpty && attachments.isEmpty) return;
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

    // Sending is a new user action: earlier rejection feedback is stale.
    if (state.attachmentError != null) emit(state.copyWith(clearAttachmentError: true));
    try {
      final accepted = await messagesCubit.sendMessage(
        trimmedText,
        intent: intent,
        omitThinkingMode: _routeOmitsThinking(),
        attachments: [
          for (final attachment in attachments)
            {
              'name': attachment.name,
              'size_bytes': attachment.sizeBytes,
              'sha256': sha256.convert(attachment.bytes).toString(),
              'data_base64': base64Encode(attachment.bytes),
            },
        ],
      );
      if (!accepted && attachments.isNotEmpty) {
        // A refused first send in a New conversation has already created the
        // session and moved the text there: the attachments move with it, so
        // nothing submitted stays behind in the New draft.
        final createdScope = _createdSessionScope(submittedScope);
        if (createdScope != null) _moveDraftAttachments(submittedIds, from: submittedScope, to: createdScope);
        // Never refuse silently: the attachments stay in the draft and the
        // composer states that the send did not go through.
        if (_draftScope == submittedScope || _draftScope == createdScope) {
          emit(state.copyWith(attachmentError: const DraftAttachmentError(DraftAttachmentErrorKind.sendFailed)));
        }
      }
      if (accepted && attachments.isNotEmpty) {
        final cached = _draftsByScope[submittedScope];
        if (cached != null) {
          final remaining = cached.where((item) => !submittedIds.contains(item.id)).toList(growable: false);
          if (remaining.isEmpty) {
            _draftsByScope.remove(submittedScope);
          } else {
            _draftsByScope[submittedScope] = List.unmodifiable(remaining);
          }
        }
        if (_draftScope == submittedScope) {
          final remaining = state.draftAttachments
              .where((item) => !submittedIds.contains(item.id))
              .toList(growable: false);
          emit(state.copyWith(draftAttachments: List.unmodifiable(remaining), clearAttachmentError: remaining.isEmpty));
        }
      }
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  /// The scope of the session a New-conversation send at [submittedScope]
  /// created, or `null` when the send targeted an existing session or created
  /// none.
  String? _createdSessionScope(String submittedScope) {
    final separator = submittedScope.indexOf('\u0000');
    if (separator < 0 || separator != submittedScope.length - 1) return null;
    final created = messagesCubit.state.activeSessionId?.trim();
    if (created == null || created.isEmpty) return null;
    return '${submittedScope.substring(0, separator)}\u0000$created';
  }

  List<DraftAttachment> _scopeAttachments(String scope) =>
      scope == _draftScope ? state.draftAttachments : _draftsByScope[scope] ?? const [];

  void _setScopeAttachments(String scope, List<DraftAttachment> attachments) {
    final value = List<DraftAttachment>.unmodifiable(attachments);
    if (scope == _draftScope) {
      emit(state.copyWith(draftAttachments: value));
    } else if (value.isEmpty) {
      _draftsByScope.remove(scope);
    } else {
      _draftsByScope[scope] = value;
    }
  }

  /// Moves the attachments with [ids] from scope [from] to scope [to],
  /// wherever each scope currently lives (the active state or the cache).
  void _moveDraftAttachments(Set<String> ids, {required String from, required String to}) {
    final source = _scopeAttachments(from);
    final moving = source.where((item) => ids.contains(item.id)).toList(growable: false);
    if (moving.isEmpty) return;
    _setScopeAttachments(from, source.where((item) => !ids.contains(item.id)).toList(growable: false));
    final target = _scopeAttachments(to);
    final present = target.map((item) => item.id).toSet();
    _setScopeAttachments(to, [...target, ...moving.where((item) => !present.contains(item.id))]);
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
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
    required TurnReplayAction action,
    String? message,
    bool confirmedReplayUnsafe = false,
    bool confirmedDropSteers = false,
  }) async {
    try {
      return await messagesCubit.replayTurn(
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: expectedHistoryRevision,
        action: action,
        message: message,
        confirmedReplayUnsafe: confirmedReplayUnsafe,
        confirmedDropSteers: confirmedDropSteers,
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

  Future<SessionForkResult> forkSession({
    required String targetMessageId,
    required String targetTurnId,
  }) async {
    try {
      return await messagesCubit.forkSession(
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return const SessionForkResult(outcome: 'failed');
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

  /// Admits the route's effective thinking selection for display and the next
  /// send without persisting it (see
  /// [SessionMessagesCubit.admitNextMessageThinkingMode]).
  void admitRouteThinkingMode(String? thinkingMode) {
    messagesCubit.admitNextMessageThinkingMode(thinkingMode);
  }

  /// The explicit (user-chosen or conversation-stored) thinking value, without
  /// a route default admitted only for display and the next send. This is the
  /// only thinking value a New Conversation draft may persist.
  String? get explicitNextMessageThinkingMode => messagesCubit.explicitNextMessageThinkingMode;

  /// Restores a New Conversation draft route. Only a complete provider+model
  /// route replaces the current one; a partial or empty draft route is ignored
  /// so the device route or readiness default stays in effect.
  void restoreNewConversationPreferences({
    String? providerId,
    String? model,
    String? thinkingMode,
  }) {
    if (!ConversationDraft.isCompleteRoute(providerId, model)) return;
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

      final activeSessionId = messagesCubit.state.activeSessionId;
      final effectiveScope = (activeSessionId != null && activeSessionId.isNotEmpty)
          ? CapabilityValueScope.session
          : scope;

      switch (effectiveScope) {
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
          messagesCubit.setNextMessagePreferences(
            providerId: providerId,
            model: model,
          );
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
      // Null/empty means provider default (Task 43 Gate H). Pass an empty
      // string so setNextMessagePreferences clears local + persisted preference.
      final normalized = thinkingMode?.trim() ?? '';
      messagesCubit.setNextMessagePreferences(thinkingMode: normalized);

      final activeSessionId = messagesCubit.state.activeSessionId;
      if (activeSessionId != null && activeSessionId.isNotEmpty) {
        await messagesCubit.updateSessionPreferences(
          thinkingMode: normalized,
        );
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
    String? path,
    String? name,
    String? description,
  }) async {
    try {
      return await messagesCubit.createWorkspace(
        path: path,
        name: name,
        description: description,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return null;
    }
  }

  /// Returns why the change was not applied, for the caller to show.
  Future<WorkspacePolicyChangeFailure?> setWorkspacePermissionMode(WorkspacePermissionMode permissionMode) async {
    try {
      return await messagesCubit.setWorkspacePermissionMode(permissionMode);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
      return WorkspacePolicyChangeFailure.failed;
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
