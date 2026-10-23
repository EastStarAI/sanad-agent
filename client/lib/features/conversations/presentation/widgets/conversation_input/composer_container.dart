import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_input_router.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import '../sidebar/sidebar_composition.dart';
import 'composer_attachment_rail.dart';
import 'composer_helpers.dart';
import 'composer_model_chip.dart';
import 'composer_permission_mode_chip.dart';
import 'composer_send_stop_button.dart';
import 'composer_workspace_warning.dart';

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
      child: composerCard,
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
    final hasPendingRequest = inputSlice.pendingSuspendedRequest != null;

    final modelChip = !hasPendingRequest && capabilities.supportsModelChange
        ? ComposerModelChip(
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
          sessionId: sessionId,
        );
      },
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: borderColor),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              if (!hasPendingRequest &&
                  capabilities.supportsToolPermissions &&
                  inputSlice.selectedWorkspace != null) ...[
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
          if (SidebarBreakpoints.isCompact(context))
            Expanded(
              child: Row(
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
                  const SizedBox(width: 4),
                  sendStopButton,
                ],
              ),
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (modelChip != null) ...[
                  modelChip,
                  const SizedBox(width: 8),
                ],
                if (thinkingModeChip != null) ...[
                  thinkingModeChip,
                  const SizedBox(width: 8),
                ],
                sendStopButton,
              ],
            ),
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
                style: GoogleFonts.inter(color: dimTextColor, fontSize: 12),
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

