import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/runtime_notice_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/slash_suggestion_surface.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'composer_container.dart';
import 'composer_helpers.dart';
import 'composer_paste_capture.dart';

/// The conversation composer: runtime notice, slash suggestions, and the card.
class ConversationInputComposer extends StatelessWidget {
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
  final Future<ClipboardReader?> Function()? readClipboard;

  final int maxLines;

  const ConversationInputComposer({
    super.key,
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
    this.readClipboard,
    this.maxLines = 8,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final supportsKeyboardSlashNavigation = !kIsWeb
        ? !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        : true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      maybeInputCubit(context)?.setDraftScope(
        deviceId: agentSlice.activeAgent?.id,
        sessionId: sessionId,
      );
    });

    return BlocBuilder<ComposerSlashCommandsCubit, ComposerSlashCommandsState>(
      builder: (context, slashState) {
        return Column(
          children: [
            if (inputSlice.runtimeNotice != null) ...[
              RuntimeNoticeCard(
                notice: inputSlice.runtimeNotice!,
                borderColor: borderColor,
                inputBgColor: inputBgColor,
                dimTextColor: dimTextColor,
                onStop: inputSlice.runtimeNotice!.actions.contains('stop')
                    ? () => context.read<ConversationInputCubit>().stop()
                    : null,
                onRetry: inputSlice.runtimeNotice!.actions.contains('retry')
                    ? () => context.read<ConversationInputCubit>().retryRuntimeNotice()
                    : null,
                onChangeProvider: _supportsProviderChange(inputSlice.runtimeNotice!)
                    ? () => _showProviderSelection(context)
                    : null,
              ),
              const SizedBox(height: 10),
            ],
            if (slashState.activeQuery != null && slashState.visibleEntries.isNotEmpty) ...[
              SlashSuggestionSurface(
                entries: slashState.visibleEntries,
                onSelected: onSelectSlashSuggestion,
                onHighlightChanged: (index) => context.read<ComposerSlashCommandsCubit>().updateHighlightIndex(index),
                borderColor: borderColor,
                query: slashState.activeQuery?.query ?? '',
                highlightedIndex: slashState.highlightedIndex,
              ),
              const SizedBox(height: 10),
            ],
            ComposerPasteCapture(
              chatController: chatController,
              chatFocusNode: chatFocusNode,
              agentSlice: agentSlice,
              capabilities: capabilities,
              readClipboard: readClipboard,
              sessionId: sessionId,
              child: ComposerContainer(
                chatController: chatController,
                chatFocusNode: chatFocusNode,
                agentSlice: agentSlice,
                inputSlice: inputSlice,
                capabilities: capabilities,
                inputBgColor: inputBgColor,
                borderColor: borderColor,
                dimTextColor: dimTextColor,
                chipBgColor: chipBgColor,
                onSelectSlashSuggestion: onSelectSlashSuggestion,
                onSendAttempt: onSendAttempt,
                onStop: onStop,
                sessionId: sessionId,
                onConfirmFullAccess: onConfirmFullAccess,
                supportsKeyboardSlashNavigation: supportsKeyboardSlashNavigation,
                slashState: slashState,
                context: context,
                agentSelectorKey: agentSelectorKey,
                onPickAndCreateWorkspace: onPickAndCreateWorkspace,
                pickAttachmentFiles: pickAttachmentFiles,
                maxLines: maxLines,
              ),
            ),
          ],
        );
      },
    );
  }

  bool _supportsProviderChange(RuntimeNotice notice) {
    return notice.actions.contains('change_provider') || notice.actions.contains('continue_with_provider');
  }

  Future<void> _showProviderSelection(BuildContext context) async {
    final activeAgent = agentSlice.activeAgent;
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    final activeProviderId = inputSlice.nextMessageProviderId?.trim().isNotEmpty == true
        ? inputSlice.nextMessageProviderId?.trim()
        : selectedSession?.modelProvider?.trim();
    final activeModelId = inputSlice.nextMessageModel?.trim().isNotEmpty == true
        ? inputSlice.nextMessageModel?.trim()
        : selectedSession?.model?.trim();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ModelPickerDialog(
        agent: activeAgent,
        activeProviderId: activeProviderId,
        activeModelId: activeModelId,
        onSelected: (providerId, modelId) {
          unawaited(
            context.read<ConversationInputCubit>().continueWithProvider(
              providerInstanceId: providerId,
              modelId: modelId,
            ),
          );
        },
      ),
    );
  }
}

