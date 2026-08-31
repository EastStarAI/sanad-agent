import 'dart:async';
import 'dart:ui';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_text_editing.dart';
import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/queued_messages_box.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_state.dart';
import 'package:sanad_client/features/voice/presentation/widgets/voice_stream_panel.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_context_chips.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';

class ConversationInputPanel extends StatefulWidget {
  final void Function(String, {MessageDeliveryIntent intent}) onSendMessage;
  final VoidCallback? onStop;
  final String? sessionId;

  @visibleForTesting
  static VoidCallback? debugOnBottomActionsBuild;

  @visibleForTesting
  static Future<String?> Function()? debugPickDirectoryPath;

  @visibleForTesting
  static ValueChanged<String>? debugOnValidationError;

  final bool showBlur;
  final int maxLines;

  const ConversationInputPanel({
    super.key,
    required this.onSendMessage,
    this.onStop,
    this.sessionId,
    this.showBlur = true,
    this.maxLines = 8,
  });

  @override
  State<ConversationInputPanel> createState() => _ConversationInputPanelState();
}

class _ConversationInputPanelState extends State<ConversationInputPanel> {
  static const Duration _draftDebounceDelay = Duration(milliseconds: 500);

  final SlashCommandTextController _chatController = SlashCommandTextController();
  final GlobalKey<PopupMenuButtonState<String>> _agentSelectorKey = GlobalKey();
  final FocusNode _chatFocusNode = FocusNode();
  late final ComposerSlashCommandsCubit _slashCommandsCubit;
  late final ConversationInputCubit _inputCubit;
  ConversationCacheRepository? _draftRepository;
  Timer? _draftSaveDebouncer;
  StreamSubscription? _draftCleanupSubscription;
  bool _isSettingDraftText = false;
  bool _hasUnsavedDraftChanges = false;
  bool _isRestoringDraftContext = false;
  final Set<String> _runtimeActionsInFlight = <String>{};
  String? _boundDeviceId;
  String? _observedPendingRequestId;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _inputCubit = context.read<ConversationInputCubit>();
    _boundDeviceId = _deviceIdFromState(context.read<DeviceCubit>().state);
    try {
      _draftRepository = context.read<ConversationCacheRepository>();
    } catch (_) {
      _draftRepository = null;
    }
    _slashCommandsCubit = ComposerSlashCommandsCubit(
      searcher: ({query, workspaceId}) {
        return _inputCubit.searchSlashCommands(query: query);
      },
    );
    _chatController.addListener(_handleComposerChanged);
    _initDraftBinding();
    _focusNewConversationComposer();
  }

  void _focusNewConversationComposer() {
    if (widget.sessionId?.isNotEmpty == true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_chatFocusNode.hasFocus) {
        _chatFocusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant ConversationInputPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _draftSaveDebouncer?.cancel();
      if (_hasUnsavedDraftChanges) {
        _saveDraftNow(
          sessionIdOverride: oldWidget.sessionId,
          useSessionIdOverride: true,
        );
      }
      _initDraftBinding();
      _focusNewConversationComposer();
    }
  }

  void _initDraftBinding() {
    if (_draftRepository == null) return;
    _loadDraft();
    _subscribeDraftCleanup();
  }

  @override
  void dispose() {
    _draftSaveDebouncer?.cancel();
    if (_hasUnsavedDraftChanges) {
      _saveDraftNow();
    }
    _chatController.removeListener(_handleComposerChanged);
    unawaited(_draftCleanupSubscription?.cancel());
    _chatFocusNode.dispose();
    _chatController.dispose();
    unawaited(_slashCommandsCubit.close());
    super.dispose();
  }

  ConversationInputAgentSlice _selectAgentSlice(DeviceState state) {
    return switch (state) {
      DeviceActive(activeAgent: final activeAgent, agents: final agents) => ConversationInputAgentSlice(
        activeAgent: activeAgent,
        agents: agents,
      ),
      DeviceNoActive(agents: final agents) => ConversationInputAgentSlice(
        activeAgent: null,
        agents: agents,
      ),
      _ => const ConversationInputAgentSlice(activeAgent: null, agents: <DeviceConfig>[]),
    };
  }

  ConversationInputSlice _selectConversationSlice(ConversationInputState state) {
    return ConversationInputSlice(
      isProcessing: state.isProcessing,
      nextMessageModel: state.nextMessageModel,
      nextMessageProviderId: state.nextMessageProviderId,
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
      isAwaitingMessageAcceptance: state.isAwaitingMessageAcceptance,
      queuedMessages: state.queuedMessages,
      queuedMutationRequestIds: state.queuedMutationRequestIds,
    );
  }

  bool _validateSelections(
    ConversationInputAgentSlice agentSlice,
    ConversationInputSlice inputSlice,
  ) {
    final activeAgent = agentSlice.activeAgent;
    if (activeAgent == null) {
      _agentSelectorKey.currentState?.showButtonMenu();
      return false;
    }

    if (!activeAgent.isOnline) {
      _showValidationError('${activeAgent.name} is currently offline');
      return false;
    }

    if (inputSlice.nextMessageProviderId?.trim().isNotEmpty != true ||
        inputSlice.nextMessageModel?.trim().isNotEmpty != true) {
      _showValidationError(ConversationInputCubit.missingProviderModelError);
      return false;
    }

    if (inputSlice.requiresWorkspace && inputSlice.selectedWorkspace == null) {
      _showValidationError(
        'Choose a workspace before sending your first Sanad Agent message',
      );
      unawaited(context.read<ConversationInputCubit>().refreshWorkspaces());
      return false;
    }

    return true;
  }

  void _showValidationError(String message) {
    ConversationInputPanel.debugOnValidationError?.call(message);
    ToastUtils.showError(context, message);
  }

  void _handleComposerChanged() {
    _slashCommandsCubit.onComposerChanged(_chatController.value);
    if (_isSettingDraftText) return;
    _hasUnsavedDraftChanges = true;
    _observedPendingRequestId = null;
    _setPendingAcceptance(null);
    _scheduleDraftSave();
  }

  void _setPendingAcceptance(String? requestId) {
    _inputCubit.setMessageAcceptancePending(requestId?.trim().isNotEmpty == true);
  }

  void _handleSendAttempt(
    ConversationInputAgentSlice agentSlice,
    ConversationInputSlice inputSlice, {
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  }) {
    if (inputSlice.isAwaitingMessageAcceptance) return;
    if (!_validateSelections(agentSlice, inputSlice)) return;

    final dispatchExport = _chatController.exportForDispatch();
    final text = dispatchExport.plainText.trim();
    if (text.isEmpty) return;

    unawaited(_dispatchComposerText(text, intent: intent));
  }

  Future<void> _dispatchComposerText(
    String text, {
    required MessageDeliveryIntent intent,
  }) async {
    final invocation = SkillComposerUtils.parseLeadingRuntimeInvocation(text);
    if (invocation != null) {
      final entry = await _resolveRuntimeAction(invocation.command);
      if (!mounted) return;
      if (entry != null) {
        if (invocation.arguments.isNotEmpty) {
          _showValidationError(
            '${entry.invocationText} does not accept arguments.',
          );
          return;
        }
        await _dispatchRuntimeAction(entry);
        return;
      }
    }

    _draftSaveDebouncer?.cancel();
    _saveDraftNow();
    _setPendingAcceptance('dispatching');
    widget.onSendMessage(text, intent: intent);
    _slashCommandsCubit.clear();
  }

  Future<SlashCommandEntry?> _resolveRuntimeAction(String command) async {
    bool matches(SlashCommandEntry entry) =>
        entry.type == SlashCommandType.runtimeAction &&
        entry.command.trim().replaceFirst(RegExp(r'^/+'), '').toLowerCase() == command;

    for (final entry in _slashCommandsCubit.state.availableEntries) {
      if (matches(entry)) return entry;
    }
    final entries = await _inputCubit.searchSlashCommands(query: command);
    for (final entry in entries) {
      if (matches(entry)) return entry;
    }
    return null;
  }

  Future<void> _dispatchRuntimeAction(SlashCommandEntry entry) async {
    final command = entry.command.trim().replaceFirst(RegExp(r'^/+'), '').toLowerCase();
    if (!_runtimeActionsInFlight.add(command)) return;
    try {
      final handler = <String, Future<void> Function()>{
        'compact': _dispatchCompactCommand,
      }[command];
      if (handler == null) {
        _showValidationError(
          '${entry.invocationText} is not supported by this client.',
        );
        return;
      }
      await handler();
    } finally {
      _runtimeActionsInFlight.remove(command);
    }
  }

  Future<void> _dispatchCompactCommand() async {
    final sessionId = widget.sessionId?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      _showValidationError('Create or select a session before running /compact.');
      return;
    }
    final result = await _inputCubit.compactSession();
    if (!mounted) return;
    if (result.accepted) {
      _chatController.clear();
      _slashCommandsCubit.clear();
      _hasUnsavedDraftChanges = false;
      _saveDraftNow();
      return;
    }
    if (result.sessionBusy) {
      _showValidationError('Session is busy. Try /compact again when idle.');
      return;
    }
    if (result.compactionInProgress) {
      _showValidationError('Context compaction is already in progress.');
      return;
    }
    _showValidationError(
      result.failureReason == null
          ? 'Context compaction could not start.'
          : 'Context compaction failed: ${result.failureReason}',
    );
  }

  void _selectSlashSuggestion(SlashCommandEntry entry) {
    final query = _slashCommandsCubit.state.activeQuery;
    if (query == null) {
      return;
    }

    if (entry.type.selectionAction == SlashCommandSelectionAction.executeImmediately) {
      _chatController.value = _slashCommandsCubit.applySelection(
        SkillComposerUtils.applySlashSelectionText(
          _chatController.value,
          query: query,
          replacement: entry.invocationText,
        ),
      );
      _chatFocusNode.requestFocus();
      unawaited(_dispatchRuntimeAction(entry));
      return;
    }

    _chatController.value = _slashCommandsCubit.applySelection(
      _chatController.applySlashCommandSelection(
        value: _chatController.value,
        query: query,
        entry: entry,
      ),
    );
    _chatFocusNode.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // Draft management
  // ---------------------------------------------------------------------------

  void _scheduleDraftSave() {
    if (_isSettingDraftText || _isRestoringDraftContext || _draftRepository == null) return;
    _draftSaveDebouncer?.cancel();
    _draftSaveDebouncer = Timer(_draftDebounceDelay, () {
      if (!mounted) return;
      _saveDraftNow();
    });
  }

  void _saveDraftNow({
    String? sessionIdOverride,
    bool useSessionIdOverride = false,
    String? deviceIdOverride,
    bool preserveBoundContext = false,
  }) {
    final repo = _draftRepository;
    final deviceId = deviceIdOverride ?? _boundDeviceId;
    if (repo == null || deviceId == null) return;

    final text = _chatController.exportPlainText();
    final sessionId = useSessionIdOverride ? sessionIdOverride : widget.sessionId;
    final inputState = _inputCubit.state;

    if (sessionId != null && sessionId.isNotEmpty) {
      final existing = repo.sessionDraft(deviceId, sessionId);
      repo.setSessionDraft(
        deviceId,
        sessionId,
        ConversationDraft(
          text: text,
          workspaceId: existing?.workspaceId,
          providerId: preserveBoundContext
              ? existing?.providerId
              : inputState.nextMessageProviderId ?? existing?.providerId,
          model: preserveBoundContext ? existing?.model : inputState.nextMessageModel ?? existing?.model,
          thinkingMode: preserveBoundContext
              ? existing?.thinkingMode
              : inputState.nextMessageThinkingMode ?? existing?.thinkingMode,
          permissionMode: preserveBoundContext ? existing?.permissionMode : inputState.permissionMode.name,
          pendingRequestId: null,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } else {
      if (preserveBoundContext) {
        repo.setNewConversationDraft(
          deviceId,
          text: text,
          clearPendingRequest: true,
        );
      } else {
        repo.setNewConversationDraft(
          deviceId,
          text: text,
          workspaceId: inputState.selectedWorkspace?.id,
          providerId: inputState.nextMessageProviderId,
          model: inputState.nextMessageModel,
          thinkingMode: inputState.nextMessageThinkingMode,
          clearWorkspace: inputState.selectedWorkspace == null,
          clearProvider: inputState.nextMessageProviderId == null,
          clearModel: inputState.nextMessageModel == null,
          clearThinkingMode: inputState.nextMessageThinkingMode == null,
          clearPermissionMode: true,
          clearPendingRequest: true,
        );
      }
    }
    _hasUnsavedDraftChanges = false;
  }

  void _loadDraft() {
    final repo = _draftRepository;
    final deviceId = _boundDeviceId;
    if (repo == null || deviceId == null) return;

    final sessionId = widget.sessionId;
    ConversationDraft? draft;

    if (sessionId != null && sessionId.isNotEmpty) {
      draft = repo.sessionDraft(deviceId, sessionId);
    } else {
      draft = repo.newConversationDraft(deviceId);
    }

    _observedPendingRequestId = draft?.pendingRequestId;
    _setPendingAcceptance(draft?.pendingRequestId);
    _setComposerText((draft != null && !draft.isEmpty) ? draft.text : '');
    _hasUnsavedDraftChanges = false;
    if ((sessionId == null || sessionId.isEmpty) && draft != null && !draft.isEmpty) {
      unawaited(_restoreNewConversationDraftContext(draft, deviceId));
    }
  }

  void _subscribeDraftCleanup() {
    unawaited(_draftCleanupSubscription?.cancel());
    final repo = _draftRepository;
    if (repo == null) return;
    _draftCleanupSubscription = repo.snapshotStream.listen((snapshot) {
      if (!mounted) return;
      final deviceId = _boundDeviceId;
      if (deviceId == null) return;
      final sessionId = widget.sessionId;
      final isNewConversation = sessionId == null || sessionId.isEmpty;
      final authoritativeDraft = !isNewConversation
          ? snapshot.sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)]
          : repo.newConversationDraft(deviceId);
      if (isNewConversation &&
          authoritativeDraft != null &&
          !authoritativeDraft.isEmpty &&
          !_isRestoringDraftContext &&
          !_draftContextMatchesInput(authoritativeDraft)) {
        unawaited(_restoreNewConversationDraftContext(authoritativeDraft, deviceId));
      }
      final pendingRequestId = !isNewConversation
          ? snapshot
                .sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(
                  deviceId,
                  sessionId,
                )]
                ?.pendingRequestId
          : snapshot.contexts[deviceId]?.newConversationDraftPendingRequestId;
      _setPendingAcceptance(pendingRequestId);
      if (pendingRequestId != null) {
        _observedPendingRequestId = pendingRequestId;
      } else if (_observedPendingRequestId != null) {
        _observedPendingRequestId = null;
        _setComposerText('');
        _hasUnsavedDraftChanges = false;
      } else if (!_hasUnsavedDraftChanges &&
          authoritativeDraft != null &&
          authoritativeDraft.text != _chatController.exportPlainText()) {
        _setComposerText(authoritativeDraft.text);
      }
    });
  }

  bool _draftContextMatchesInput(ConversationDraft draft) {
    final state = _inputCubit.state;
    return state.selectedWorkspace?.id == draft.workspaceId &&
        state.nextMessageProviderId == draft.providerId &&
        state.nextMessageModel == draft.model &&
        state.nextMessageThinkingMode == draft.thinkingMode;
  }

  Future<void> _restoreNewConversationDraftContext(
    ConversationDraft draft,
    String deviceId,
  ) async {
    _isRestoringDraftContext = true;
    try {
      if (draft.workspaceId != null) {
        var workspace = _inputCubit.state.availableWorkspaces.where((item) => item.id == draft.workspaceId).firstOrNull;
        if (workspace == null && !_inputCubit.state.isLoadingWorkspaces) {
          await _inputCubit.refreshWorkspaces();
          if (!mounted || _boundDeviceId != deviceId) return;
          workspace = _inputCubit.state.availableWorkspaces.where((item) => item.id == draft.workspaceId).firstOrNull;
        }
        if (workspace != null && _inputCubit.state.selectedWorkspace?.id != workspace.id) {
          _inputCubit.selectWorkspace(workspace);
        }
      } else if (_inputCubit.state.selectedWorkspace != null && !_inputCubit.state.requiresWorkspace) {
        _inputCubit.clearWorkspace();
      }
      _inputCubit.restoreNewConversationPreferences(
        providerId: draft.providerId,
        model: draft.model,
        thinkingMode: draft.thinkingMode,
      );
    } finally {
      _isRestoringDraftContext = false;
    }
  }

  void _handleDeviceChanged(DeviceState state) {
    final nextDeviceId = _deviceIdFromState(state);
    if (nextDeviceId == _boundDeviceId) return;
    _draftSaveDebouncer?.cancel();
    if (_hasUnsavedDraftChanges) {
      _saveDraftNow(
        deviceIdOverride: _boundDeviceId,
        preserveBoundContext: true,
      );
    }
    _boundDeviceId = nextDeviceId;
    _observedPendingRequestId = null;
    _initDraftBinding();
  }

  void _handleInputContextChanged(ConversationInputState state) {
    unawaited(_slashCommandsCubit.loadForWorkspace(state.selectedWorkspace?.id));
    if ((widget.sessionId == null || widget.sessionId!.isEmpty) && !_isRestoringDraftContext) {
      _hasUnsavedDraftChanges = true;
      _observedPendingRequestId = null;
      _scheduleDraftSave();
    }
  }

  void _setComposerText(String text) {
    _isSettingDraftText = true;
    _chatController.text = text;
    _isSettingDraftText = false;
  }

  void _insertDroppedPaths(Iterable<String> paths) {
    final next = insertDroppedPathsAtSelection(_chatController.value, paths);
    if (next == _chatController.value) return;
    _chatController.value = next;
    _chatFocusNode.requestFocus();
  }

  String? _deviceIdFromState(DeviceState deviceState) {
    if (deviceState is DeviceActive) return deviceState.activeAgent.id;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inputBgColor = theme.colorScheme.surface;
    final chipBgColor = theme.colorScheme.surfaceContainerHighest;
    final borderColor = theme.colorScheme.outline.withValues(alpha: 0.20);
    final dimTextColor = theme.colorScheme.onSurfaceVariant;

    final mainContent = BlocProvider<ComposerSlashCommandsCubit>.value(
      value: _slashCommandsCubit,
      child: MultiBlocListener(
        listeners: [
          BlocListener<DeviceCubit, DeviceState>(
            listenWhen: (previous, current) => _deviceIdFromState(previous) != _deviceIdFromState(current),
            listener: (context, state) => _handleDeviceChanged(state),
          ),
          BlocListener<ConversationInputCubit, ConversationInputState>(
            listenWhen: (previous, current) =>
                previous.selectedWorkspace?.id != current.selectedWorkspace?.id ||
                previous.nextMessageProviderId != current.nextMessageProviderId ||
                previous.nextMessageModel != current.nextMessageModel ||
                previous.nextMessageThinkingMode != current.nextMessageThinkingMode ||
                previous.permissionMode != current.permissionMode,
            listener: (context, state) => _handleInputContextChanged(state),
          ),
        ],
        child: BlocSelector<DeviceCubit, DeviceState, ConversationInputAgentSlice>(
          selector: _selectAgentSlice,
          builder: (context, agentSlice) {
            return BlocSelector<ConversationInputCubit, ConversationInputState, ConversationInputSlice>(
              selector: _selectConversationSlice,
              builder: (context, inputSlice) {
                return BlocSelector<DeviceCapabilitiesCubit, DeviceCapabilitiesState, Capability>(
                  selector: (state) => state.getForAgent(agentSlice.capabilityAgentId ?? ''),
                  builder: (context, capabilities) {
                    assert(() {
                      ConversationInputPanel.debugOnBottomActionsBuild?.call();
                      return true;
                    }());

                    return BlocBuilder<VoiceStreamCubit, VoiceStreamState>(
                      builder: (context, voiceState) {
                        if (voiceState.isSessionActive && agentSlice.activeAgent != null) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            color: Colors.transparent,
                            child: VoiceStreamPanel(
                              voiceState: voiceState,
                              agent: agentSlice.activeAgent!,
                              borderColor: borderColor,
                              inputBgColor: inputBgColor,
                            ),
                          );
                        }

                        return Container(
                          padding: const EdgeInsets.all(8),
                          color: Colors.transparent,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (inputSlice.queuedMessages.isNotEmpty) ...[
                                QueuedMessagesBox(
                                  messages: inputSlice.queuedMessages,
                                  borderColor: borderColor,
                                  inputBgColor: inputBgColor,
                                  dimTextColor: dimTextColor,
                                  onSteer: (text, {required requestId}) {
                                    unawaited(
                                      context.read<ConversationInputCubit>().steerMessage(text, requestId: requestId),
                                    );
                                  },
                                  onDelete: ({required requestId}) {
                                    unawaited(
                                      context.read<ConversationInputCubit>().deleteQueuedMessage(requestId: requestId),
                                    );
                                  },
                                  pendingRequestIds: inputSlice.queuedMutationRequestIds,
                                ),
                                const SizedBox(height: 12),
                              ],
                              ConversationInputComposer(
                                chatController: _chatController,
                                chatFocusNode: _chatFocusNode,
                                agentSlice: agentSlice,
                                inputSlice: inputSlice,
                                capabilities: capabilities,
                                inputBgColor: inputBgColor,
                                borderColor: borderColor,
                                dimTextColor: dimTextColor,
                                chipBgColor: chipBgColor,
                                onSelectSlashSuggestion: _selectSlashSuggestion,
                                onSendAttempt: ({intent = MessageDeliveryIntent.auto}) =>
                                    _handleSendAttempt(agentSlice, inputSlice, intent: intent),
                                onStop: widget.onStop,
                                sessionId: widget.sessionId,
                                onConfirmFullAccess: _confirmFullAccess,
                                agentSelectorKey: _agentSelectorKey,
                                onPickAndCreateWorkspace: _pickAndCreateWorkspace,
                                maxLines: widget.maxLines,
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );

    final isBlurEnabled = widget.showBlur;
    final decoration = BoxDecoration(
      color: _isDragging
          ? theme.colorScheme.primary.withValues(alpha: 0.1)
          : (isBlurEnabled ? theme.colorScheme.surface.withValues(alpha: 0.35) : theme.colorScheme.surface),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: _isDragging ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.30),
        width: 1.0,
      ),
    );

    final borderCard = DropTarget(
      onDragEntered: (details) {
        setState(() {
          _isDragging = true;
        });
      },
      onDragExited: (details) {
        setState(() {
          _isDragging = false;
        });
      },
      onDragDone: (details) {
        setState(() {
          _isDragging = false;
        });
        _insertDroppedPaths(details.files.map((file) => file.path));
      },
      child: Container(
        margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: isBlurEnabled
              ? BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Container(
                    decoration: decoration,
                    child: mainContent,
                  ),
                )
              : Container(
                  decoration: decoration,
                  child: mainContent,
                ),
        ),
      ),
    );

    final isNewChat = widget.sessionId == null || widget.sessionId!.isEmpty;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: SidebarBreakpoints.maxConversationWidth,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isNewChat)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                child: BlocSelector<DeviceCubit, DeviceState, ConversationInputAgentSlice>(
                  selector: _selectAgentSlice,
                  builder: (context, agentSlice) {
                    return BlocSelector<ConversationInputCubit, ConversationInputState, ConversationInputSlice>(
                      selector: _selectConversationSlice,
                      builder: (context, inputSlice) {
                        return BlocSelector<DeviceCapabilitiesCubit, DeviceCapabilitiesState, Capability>(
                          selector: (state) => state.getForAgent(agentSlice.capabilityAgentId ?? ''),
                          builder: (context, capabilities) {
                            return Row(
                              children: [
                                ConversationContextChips(
                                  agentSelectorKey: _agentSelectorKey,
                                  agentSlice: agentSlice,
                                  inputSlice: inputSlice,
                                  capabilities: capabilities,
                                  sessionId: widget.sessionId,
                                  inputBgColor: Colors.transparent,
                                  chipBgColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
                                  borderColor: borderColor,
                                  dimTextColor: dimTextColor,
                                  onPickAndCreateWorkspace: _pickAndCreateWorkspace,
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            borderCard,
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndCreateWorkspace(DeviceConfig? activeAgent) async {
    final selected = await WorkspacePickerHelper.promptCreateWorkspace(
      context: context,
      device: activeAgent,
      debugLocalPath: ConversationInputPanel.debugPickDirectoryPath,
    );
    if (!mounted || selected == null) {
      return;
    }

    final workspace = await context.read<ConversationInputCubit>().createWorkspace(
      path: selected.path,
      name: selected.name,
      description: selected.description,
    );
    if (!mounted || workspace == null) {
      return;
    }

    ToastUtils.showSuccess(context, 'Workspace selected: ${workspace.name}');
  }

  Future<bool> _confirmFullAccess() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('Enable Full Access?'),
          content: Text(
            'Full Access lets Sanad Agent run local tools in this workspace without repeated approval prompts.',
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enable'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }
}
