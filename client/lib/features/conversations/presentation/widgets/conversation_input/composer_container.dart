import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/theme/app_typography.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_input_router.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_mic_button.dart';

import '../sidebar/sidebar_composition.dart';
import 'composer_attachment_rail.dart';
import 'composer_helpers.dart';
import 'composer_model_chip.dart';
import 'composer_permission_mode_chip.dart';
import 'composer_send_stop_button.dart';
import 'composer_workspace_warning.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_composer_backdrop.dart';

/// The composer card: input field, attachment rail, and the bottom action row.
class ComposerContainer extends StatelessWidget {
  final SlashCommandTextController chatController;
  final FocusNode chatFocusNode;
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color inputBgColor;
  final Color borderColor;
  final Color dimTextColor;
  final Color chipBgColor;
  final void Function(SlashCommandEntry entry) onSelectSlashSuggestion;
  final void Function({MessageDeliveryIntent intent}) onSendAttempt;
  final VoidCallback? onStop;
  final String? sessionId;
  final Future<bool> Function() onConfirmFullAccess;
  final GlobalKey<PopupMenuButtonState<String>> agentSelectorKey;
  final Future<void> Function(DeviceConfig? activeAgent) onPickAndCreateWorkspace;
  final Future<List<XFile>> Function()? pickAttachmentFiles;
  final bool supportsKeyboardSlashNavigation;
  final ComposerSlashCommandsState slashState;
  final BuildContext context;
  final int maxLines;

  const ComposerContainer({
    required this.chatController,
    required this.chatFocusNode,
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.inputBgColor,
    required this.borderColor,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.onSelectSlashSuggestion,
    required this.onSendAttempt,
    required this.onStop,
    required this.onConfirmFullAccess,
    required this.agentSelectorKey,
    required this.onPickAndCreateWorkspace,
    this.pickAttachmentFiles,
    required this.supportsKeyboardSlashNavigation,
    required this.slashState,
    required this.context,
    required this.maxLines,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final innerBg = Colors.transparent;

    final composerCard = Container(
      decoration: BoxDecoration(
        color: innerBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inputSlice.pendingSuspendedRequest != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: ConversationPermissionCard(
                key: ValueKey(inputSlice.pendingSuspendedRequest!.requestId),
                request: inputSlice.pendingSuspendedRequest!,
                borderColor: borderColor,
              ),
            )
          else ...[
            if (inputSlice.requiresWorkspace && inputSlice.selectedWorkspace == null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: ComposerWorkspaceWarning(onRefresh: () => context.read<ConversationInputCubit>().refreshWorkspaces()),
              ),
            ],
            _buildAttachmentRail(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: MultilineSubmissionShortcuts(
                controller: chatController,
                onSubmit: () {
                  if (slashState.activeQuery != null && slashState.visibleEntries.isNotEmpty) {
                    onSelectSlashSuggestion(slashState.visibleEntries[slashState.highlightedIndex]);
                    return;
                  }
                  onSendAttempt(intent: MessageDeliveryIntent.auto);
                },
                additionalDesktopBindings: {
                  if (supportsKeyboardSlashNavigation && slashState.visibleEntries.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.arrowDown, includeRepeats: false): () {
                      context.read<ComposerSlashCommandsCubit>().moveHighlight(1);
                    },
                  if (supportsKeyboardSlashNavigation && slashState.visibleEntries.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.arrowUp, includeRepeats: false): () {
                      context.read<ComposerSlashCommandsCubit>().moveHighlight(-1);
                    },
                  if (slashState.visibleEntries.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () {
                      context.read<ComposerSlashCommandsCubit>().clear();
                    },
                  // Escape also abandons a pending "send after dictation" wait.
                  // The slash menu owns Escape when it is open, hence the guard.
                  if (slashState.visibleEntries.isEmpty &&
                      (maybeDictationCubit(context)?.state.awaitingSend ?? false))
                    const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () {
                      readDictationCubit(context)?.cancelPendingSend();
                    },
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true, includeRepeats: false): () {
                    onSendAttempt(intent: MessageDeliveryIntent.queue);
                  },
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                    includeRepeats: false,
                  ): () {
                    onSendAttempt(intent: MessageDeliveryIntent.queue);
                  },
                },
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: chatController,
                  builder: (context, value, _) {
                    final plainText = chatController.exportPlainText();
                    final ambientDirection = Directionality.of(context);
                    final textDirection = plainText.trim().isEmpty
                        ? ambientDirection
                        : TextUtils.getTextDirection(plainText);
                    return TextField(
                      key: const Key('chat_input'),
                      controller: chatController,
                      focusNode: chatFocusNode,
                      style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 15,
                        height: 1.5,
                      ),
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      maxLines: maxLines,
                      minLines: 1,
                      textAlign: textDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
                      textDirection: textDirection,
                      decoration: InputDecoration(
                        hintText: Directionality.of(context) == TextDirection.rtl
                            ? 'اسأل سند أي شيء'
                            : 'Ask Sanad anything',
                        hintStyle: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    );
                  },
                ),
              ),
            ),
            _buildBottomRow(context),
          ],
        ],
      ),
    );

    final focusSurface = GestureDetector(
      key: const Key('composer_focus_surface'),
      behavior: HitTestBehavior.opaque,
      onTap: chatFocusNode.requestFocus,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: composerCard,
      ),
    );
    return focusSurface;
  }

  Widget _buildAttachmentRail(BuildContext context) {
    final cubit = maybeInputCubit(context);
    if (cubit == null) return const SizedBox.shrink();
    return BlocBuilder<ConversationInputCubit, ConversationInputState>(
      bloc: cubit,
      buildWhen: (previous, current) =>
          previous.draftAttachments != current.draftAttachments || previous.attachmentError != current.attachmentError,
      builder: (context, state) => ComposerAttachmentRail(
        attachments: state.draftAttachments,
        error: state.attachmentError,
        borderColor: borderColor,
        dimTextColor: dimTextColor,
      ),
    );
  }

  Future<void> _pickFiles(BuildContext context) async {
    final files = await (pickAttachmentFiles ?? openFiles)();
    final items = <ComposerRoutableItem>[];
    for (final file in files) {
      items.add(await ComposerRoutableItem.fromXFile(file));
    }
    final cubit = maybeInputCubit(context);
    if (cubit != null && items.isNotEmpty) {
      await ComposerInputRouter.routeItems(
        items: items,
        controller: chatController,
        inputCubit: cubit,
        activeAgent: agentSlice.activeAgent,
        capability: capabilities,
        source: DraftAttachmentSource.picker,
        draftScope: ConversationInputCubit.draftScopeKey(deviceId: agentSlice.activeAgent?.id, sessionId: sessionId),
      );
    }
    chatFocusNode.requestFocus();
  }

  Widget _buildBottomRow(BuildContext context) {
    final dictationCubit = maybeDictationCubit(context);
    if (dictationCubit == null) {
      return _buildBottomRowContent(context, dictationActive: false);
    }
    // The row is the only place the live meter lives, and every selector in it
    // steps aside while the user speaks, so the swap must follow the session.
    return BlocBuilder<DictationCubit, DictationState>(
      bloc: dictationCubit,
      buildWhen: (previous, current) =>
          previous.status != current.status ||
          previous.isActive != current.isActive,
      builder: (context, state) => _buildBottomRowContent(
        context,
        dictationActive: state.status == DictationStatus.listening,
      ),
    );
  }

  Widget _buildBottomRowContent(
    BuildContext context, {
    required bool dictationActive,
  }) {
    final hasPendingRequest = inputSlice.pendingSuspendedRequest != null;

    // The picker is the only route to provider setup, so it stays available
    // whether or not the device has a capability snapshot or a configured
    // provider. An empty catalog is a valid picker state, not a reason to hide
    // the control.
    final modelChip = !hasPendingRequest
        ? _ComposerBoundModelChip(
            agentSlice: agentSlice,
            inputSlice: inputSlice,
            capabilities: capabilities,
            dimTextColor: dimTextColor,
            chipBgColor: chipBgColor,
            borderColor: borderColor,
          )
        : null;

    final thinkingModeChip = !hasPendingRequest
        ? RouteThinkingModeSelector(
            capabilities: capabilities,
            inputSlice: inputSlice,
            activeAgent: agentSlice.activeAgent,
            chipBuilder: (context, label, {required enabled}) {
              return _buildThinkingModeChipShell(
                context,
                label: label,
                enabled: enabled,
              );
            },
          )
        : null;

    final sendStopButton = ValueListenableBuilder<TextEditingValue>(
      valueListenable: chatController,
      builder: (context, value, _) {
        return ComposerSendStopButton(
          agentSlice: agentSlice,
          inputSlice: inputSlice,
          capabilities: capabilities,
          chatController: chatController,
          onSendAttempt: onSendAttempt,
          onStop: onStop,
          dimTextColor: dimTextColor,
        );
      },
    );

    // Dictation is optional surface-wise: when the app shell has not provided a
    // cubit (some composer tests, embedded composers), the mic simply does not
    // render. When it is provided, visibility follows the agent, never the
    // capability — the capability only styles the inactive state.
    DictationCubit? dictationCubit;
    try {
      dictationCubit = context.read<DictationCubit>();
    } on Object {
      dictationCubit = null;
    }
    final dictationMicButton = dictationCubit != null &&
            agentSlice.activeAgent != null
        ? DictationMicButton(
            chatController: chatController,
            device: agentSlice.activeAgent,
            scopeKey: sessionId,
            focusNode: chatFocusNode,
            dimTextColor: dimTextColor,
          )
        : null;

    // The trailing controls are one slot in every layout, so the element that
    // owns an in-flight action survives the row changing shape underneath it.
    // Only the middle slot swaps (the meter while listening, the selectors
    // otherwise); the mic and the Send/Stop control never move between branches.
    // Moving them did move them: the send continuation resumed on a context the
    // rebuild had already unmounted, and the transcript was never dispatched.
    final isCompact = SidebarBreakpoints.isCompact(context);
    final trailingGap = isCompact ? 4.0 : 8.0;
    final trailingControls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: trailingGap),
        if (dictationMicButton != null) ...[
          dictationMicButton,
          SizedBox(width: trailingGap),
        ],
        sendStopButton,
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: borderColor),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: 'Add attachments',
                button: true,
                child: IconButton(
                  key: const Key('composer_add_attachment'),
                  tooltip: 'Add attachments',
                  icon: Icon(Symbols.add, size: 20, color: dimTextColor),
                  onPressed: () => _pickFiles(context),
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(width: 8),
              // The permission picker steps aside while dictation is active: the
              // row shows the live meter instead, and the value is unchanged.
              if (!dictationActive &&
                  ComposerPermissionGate.shouldShow(
                    hasPendingRequest: hasPendingRequest,
                    capabilities: capabilities,
                    inputSlice: inputSlice,
                  )) ...[
                ComposerPermissionModeChip(
                  permissionMode: inputSlice.permissionMode,
                  isLoadingPermissionMode: inputSlice.isLoadingPermissionMode,
                  dimTextColor: dimTextColor,
                  chipBgColor: chipBgColor,
                  borderColor: borderColor,
                  onConfirmFullAccess: onConfirmFullAccess,
                  workspacePath: inputSlice.selectedWorkspace?.path,
                ),
              ],
            ],
          ),
          // The middle slot is the only one that swaps. While listening, the
          // model and thinking selectors give it to the meter, which fills the
          // space they had; nothing about their state changes, so they return
          // exactly as they were when the session ends.
          Expanded(
            child: dictationActive
                ? const Padding(
                    padding: EdgeInsetsDirectional.only(start: 8),
                    child: DictationComposerBackdrop(),
                  )
                : isCompact
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Flexible(
                        child: Wrap(
                          direction: Axis.horizontal,
                          alignment: WrapAlignment.center,
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (modelChip != null) modelChip,
                            if (thinkingModeChip != null) thinkingModeChip,
                          ],
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      if (modelChip != null) modelChip,
                      if (modelChip != null && thinkingModeChip != null)
                        const SizedBox(width: 8),
                      if (thinkingModeChip != null) thinkingModeChip,
                    ],
                  ),
          ),
          trailingControls,
        ],
      ),
    );
  }

  Widget _buildThinkingModeChipShell(
    BuildContext context, {
    required String label,
    required bool enabled,
  }) {
    final isCompact = SidebarBreakpoints.isCompact(context);
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isCompact ? 4 : 8, vertical: 4),
        decoration: BoxDecoration(
          color: chipBgColor.withValues(alpha: 0.50),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.neurology, size: 16, color: dimTextColor),
            const SizedBox(width: 4),
            // The always-visible control must stay horizontally bounded in a
            // narrow composer: the label shrinks instead of overflowing the row.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.text(context, color: dimTextColor, fontSize: 12),
              ),
            ),
            if (enabled) ...[
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down, size: 12, color: dimTextColor),
            ],
          ],
        ),
      ),
    );
  }
}

/// Binds the composer's conversation state to the reusable
/// [ComposerModelChip]: it resolves the effective route, supplies the live
/// context usage, and forwards a pick to the composer's input cubit.
class _ComposerBoundModelChip extends StatelessWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;

  const _ComposerBoundModelChip({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final selectedSession = context.select<SessionCubit, Session?>((cubit) => cubit.state.selectedSession);
    final contextUsage = context.select<SessionMessagesCubit, LlmUsageSnapshot?>(
      (cubit) => latestContextUsage(cubit.state.messages),
    );

    return ComposerModelChip(
      activeAgent: agentSlice.activeAgent,
      providerId: ComposerModelChip.resolveProviderId(
        nextMessageProviderId: inputSlice.nextMessageProviderId,
        session: selectedSession,
      ),
      modelId: ComposerModelChip.resolveModelId(
        nextMessageModel: inputSlice.nextMessageModel,
        session: selectedSession,
      ),
      contextUsage: contextUsage,
      session: selectedSession,
      dimTextColor: dimTextColor,
      chipBgColor: chipBgColor,
      borderColor: borderColor,
      onModelSelected: (providerId, modelId) {
        unawaited(
          context.read<ConversationInputCubit>().selectModel(
            scope: capabilities.modelSelectionScope,
            providerId: providerId,
            model: modelId,
          ),
        );
      },
    );
  }
}

