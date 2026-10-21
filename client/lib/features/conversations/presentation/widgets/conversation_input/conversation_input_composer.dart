import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_input_router.dart';
import 'package:sanad_client/features/conversations/presentation/utils/draft_attachment_error_text.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';
import 'package:sanad_client/features/conversations/presentation/utils/provider_route_label.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/context_usage_indicator.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/runtime_notice_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import '../sidebar/sidebar_composition.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/slash_suggestion_surface.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:flutter/foundation.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_state.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';

String _formatAttachmentBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}

ConversationInputCubit? _maybeInputCubit(BuildContext context) {
  try {
    return context.read<ConversationInputCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

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
      _maybeInputCubit(context)?.setDraftScope(
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
            _ComposerPasteCapture(
              chatController: chatController,
              chatFocusNode: chatFocusNode,
              agentSlice: agentSlice,
              capabilities: capabilities,
              readClipboard: readClipboard,
              child: _UnifiedComposerContainer(
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

class ComposerPasteIntent extends Intent {
  const ComposerPasteIntent();
}

/// Routes Cmd/Ctrl+V to the composer paste pipeline only while the message
/// field owns focus. When it does not, the action is disabled so the shortcut
/// falls through to the focused field's own paste behavior.
class _ComposerPasteAction extends Action<ComposerPasteIntent> {
  _ComposerPasteAction({required this.isComposerFocused, required this.onPaste});

  final bool Function() isComposerFocused;
  final VoidCallback onPaste;

  @override
  bool isEnabled(ComposerPasteIntent intent) => isComposerFocused();

  @override
  Object? invoke(ComposerPasteIntent intent) {
    onPaste();
    return null;
  }
}

class _ComposerPasteCapture extends StatefulWidget {
  const _ComposerPasteCapture({
    required this.chatController,
    required this.chatFocusNode,
    required this.agentSlice,
    required this.capabilities,
    required this.child,
    this.readClipboard,
  });

  final SlashCommandTextController chatController;
  final FocusNode chatFocusNode;
  final ConversationInputAgentSlice agentSlice;
  final Capability capabilities;
  final Widget child;
  final Future<ClipboardReader?> Function()? readClipboard;

  @override
  State<_ComposerPasteCapture> createState() => _ComposerPasteCaptureState();
}

class _ComposerPasteCaptureState extends State<_ComposerPasteCapture> {
  static const List<FileFormat> _supportedImageFormats = [
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.gif,
    Formats.tiff,
    Formats.bmp,
    Formats.heic,
    Formats.heif,
    Formats.svg,
    Formats.ico,
  ];

  static String _extensionForFormat(FileFormat format) {
    if (format == Formats.png) return 'png';
    if (format == Formats.jpeg) return 'jpg';
    if (format == Formats.webp) return 'webp';
    if (format == Formats.gif) return 'gif';
    if (format == Formats.tiff) return 'tiff';
    if (format == Formats.bmp) return 'bmp';
    if (format == Formats.heic) return 'heic';
    if (format == Formats.heif) return 'heif';
    if (format == Formats.svg) return 'svg';
    if (format == Formats.ico) return 'ico';
    return 'png';
  }

  Future<void> _handlePaste(BuildContext context) async {
    final readerFuture = widget.readClipboard?.call() ?? SystemClipboard.instance?.read();

    if (readerFuture == null) {
      _fallbackTextPaste();
      return;
    }

    try {
      final reader = await readerFuture;
      if (reader == null || !mounted) {
        _fallbackTextPaste();
        return;
      }

      final hasFileOrImage = reader.items.any(
        (item) => item.canProvide(Formats.fileUri) || _supportedImageFormats.any(item.canProvide),
      );

      if (!hasFileOrImage) {
        _fallbackTextPaste();
        return;
      }

      final items = <ComposerRoutableItem>[];
      final seenPaths = <String>{};

      for (final item in reader.items) {
        if (item.canProvide(Formats.fileUri)) {
          final uri = await item.readValue(Formats.fileUri);
          if (uri != null && uri.isScheme('file')) {
            try {
              final filePath = uri.toFilePath();
              if (seenPaths.add(filePath)) {
                items.add(ComposerRoutableItem.fromFilePathSync(filePath));
              }
            } catch (_) {}
          }
          continue;
        }

        for (final format in _supportedImageFormats) {
          if (item.canProvide(format)) {
            final bytes = await item.readFileBytes(format);
            if (bytes != null && bytes.isNotEmpty) {
              final suggestedName = await item.getSuggestedName();
              items.add(
                ComposerRoutableItem.fromImageBytes(
                  bytes: bytes,
                  formatName: _extensionForFormat(format),
                  suggestedName: suggestedName,
                ),
              );
              break;
            }
          }
        }
      }

      if (items.isEmpty) {
        _fallbackTextPaste();
        return;
      }

      final cubit = _maybeInputCubit(context);
      if (cubit != null) {
        await ComposerInputRouter.routeItems(
          items: items,
          controller: widget.chatController,
          inputCubit: cubit,
          activeAgent: widget.agentSlice.activeAgent,
          capability: widget.capabilities,
          source: DraftAttachmentSource.paste,
        );
      }
      widget.chatFocusNode.requestFocus();
    } catch (_) {
      _fallbackTextPaste();
    }
  }

  void _fallbackTextPaste() {
    final focusContext = widget.chatFocusNode.context;
    if (focusContext != null && focusContext.mounted) {
      Actions.maybeInvoke(
        focusContext,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, meta: true): ComposerPasteIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, control: true): ComposerPasteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ComposerPasteIntent: _ComposerPasteAction(
            isComposerFocused: () => widget.chatFocusNode.hasFocus,
            onPaste: () => unawaited(_handlePaste(context)),
          ),
        },
        child: widget.child,
      ),
    );
  }
}

extension on DataReader {
  Future<Uint8List?> readFileBytes(FileFormat format) {
    final completer = Completer<Uint8List?>();
    final progress = getFile(
      format,
      (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      onError: completer.completeError,
    );
    if (progress == null) completer.complete(null);
    return completer.future;
  }
}

class _AttachmentRail extends StatelessWidget {
  const _AttachmentRail({
    required this.attachments,
    required this.error,
    required this.borderColor,
    required this.dimTextColor,
  });

  final List<DraftAttachment> attachments;
  final DraftAttachmentError? error;
  final Color borderColor;
  final Color dimTextColor;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty && error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attachments.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final attachment in attachments)
                  Container(
                    key: ValueKey('draft_attachment_${attachment.id}'),
                    width: 180,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: attachment.isImage
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.memory(
                                    attachment.bytes,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(Symbols.image, size: 20),
                                  ),
                                )
                              : Center(child: FileExtensionIcon(fileName: attachment.name, size: 20)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                attachment.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${_formatAttachmentBytes(attachment.sizeBytes)} · ${attachment.status.name}',
                                style: TextStyle(fontSize: 11, color: dimTextColor),
                              ),
                            ],
                          ),
                        ),
                        if (attachment.status == DraftAttachmentStatus.failed)
                          IconButton(
                            key: ValueKey('retry_attachment_${attachment.id}'),
                            tooltip: 'Retry attachment',
                            onPressed: () => context.read<ConversationInputCubit>().retryDraftAttachment(attachment.id),
                            icon: const Icon(Symbols.refresh, size: 18),
                            visualDensity: VisualDensity.compact,
                          ),
                        IconButton(
                          key: ValueKey('remove_attachment_${attachment.id}'),
                          tooltip: 'Remove attachment',
                          onPressed: () => context.read<ConversationInputCubit>().removeDraftAttachment(attachment.id),
                          icon: const Icon(Symbols.close, size: 18),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (error case final error?) ...[
            const SizedBox(height: 6),
            _AttachmentErrorLine(
              error: error,
              onDismiss: () => context.read<ConversationInputCubit>().clearAttachmentError(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Transient attachment rejection with an explicit dismiss control.
class _AttachmentErrorLine extends StatelessWidget {
  const _AttachmentErrorLine({required this.error, required this.onDismiss});

  final DraftAttachmentError error;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final color = Theme.of(context).colorScheme.error;
    return Row(
      children: [
        Expanded(
          child: Text(
            DraftAttachmentErrorText.describe(l10n, error),
            key: const Key('attachment_error'),
            style: TextStyle(color: color, fontSize: 12),
          ),
        ),
        IconButton(
          key: const Key('attachment_error_dismiss'),
          tooltip: l10n.attachmentErrorDismiss,
          onPressed: onDismiss,
          icon: Icon(Symbols.close, size: 16, color: color),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _UnifiedComposerContainer extends StatelessWidget {
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

  const _UnifiedComposerContainer({
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
                child: _WorkspaceWarning(onRefresh: () => context.read<ConversationInputCubit>().refreshWorkspaces()),
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
    final cubit = _maybeInputCubit(context);
    if (cubit == null) return const SizedBox.shrink();
    return BlocBuilder<ConversationInputCubit, ConversationInputState>(
      bloc: cubit,
      buildWhen: (previous, current) =>
          previous.draftAttachments != current.draftAttachments || previous.attachmentError != current.attachmentError,
      builder: (context, state) => _AttachmentRail(
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
    final cubit = _maybeInputCubit(context);
    if (cubit != null && items.isNotEmpty) {
      await ComposerInputRouter.routeItems(
        items: items,
        controller: chatController,
        inputCubit: cubit,
        activeAgent: agentSlice.activeAgent,
        capability: capabilities,
        source: DraftAttachmentSource.picker,
      );
    }
    chatFocusNode.requestFocus();
  }

  Widget _buildBottomRow(BuildContext context) {
    final hasPendingRequest = inputSlice.pendingSuspendedRequest != null;

    final modelChip = !hasPendingRequest && capabilities.supportsModelChange
        ? _ModelChip(
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
        return _SendStopButton(
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
                _PermissionModeChip(
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

class _PermissionModeChip extends StatelessWidget {
  final WorkspacePermissionMode permissionMode;
  final bool isLoadingPermissionMode;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;
  final Future<bool> Function() onConfirmFullAccess;
  final String? workspacePath;

  const _PermissionModeChip({
    required this.permissionMode,
    required this.isLoadingPermissionMode,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
    required this.onConfirmFullAccess,
    this.workspacePath,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = isLoadingPermissionMode
        ? (l10n?.loading ?? 'Loading…')
        : (l10n != null ? _modeLabel(permissionMode, l10n) : permissionMode.value);
    final path = workspacePath?.trim();
    final tooltipText = path != null && path.isNotEmpty
        ? (l10n != null
              ? l10n.workspacePermissionModeTooltipWithRoot(
                  _modeLabel(permissionMode, l10n),
                  path,
                )
              : 'Permission: ${permissionMode.value}\nExecution Root: $path')
        : (l10n?.workspacePermissionModeTooltip ?? 'Select Permission Mode');

    return PopupMenuButton<WorkspacePermissionMode>(
      key: const Key('permission_mode_selector_button'),
      tooltip: tooltipText,
      enabled: !isLoadingPermissionMode,
      child: _buildChip(context, label),
      itemBuilder: (context) => WorkspacePermissionMode.values
          .map(
            (mode) => PopupMenuItem<WorkspacePermissionMode>(
              value: mode,
              height: 40,
              child: Row(
                children: [
                  Icon(
                    permissionMode == mode ? Icons.check : Icons.shield_outlined,
                    size: 16,
                    color: permissionMode == mode ? Theme.of(context).colorScheme.primary : dimTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n != null ? _modeLabel(mode, l10n) : mode.value,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      onSelected: (mode) async {
        if (mode == permissionMode) return;
        if (mode == WorkspacePermissionMode.fullAccess) {
          final confirmed = await onConfirmFullAccess();
          if (!context.mounted || !confirmed) return;
        }
        if (!context.mounted) return;
        await context.read<ConversationInputCubit>().setWorkspacePermissionMode(mode);
      },
    );
  }

  String _modeLabel(
    WorkspacePermissionMode mode,
    AppLocalizations l10n,
  ) {
    switch (mode) {
      case WorkspacePermissionMode.defaultMode:
        return l10n.workspacePermissionModeDefault;
      case WorkspacePermissionMode.fullAccess:
        return l10n.workspacePermissionModeFullAccess;
    }
  }

  Widget _buildChip(BuildContext context, String text) {
    final theme = Theme.of(context);
    final isFullAccess = !isLoadingPermissionMode && permissionMode == WorkspacePermissionMode.fullAccess;
    final color = isFullAccess ? theme.colorScheme.tertiary : dimTextColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: chipBgColor.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.shield_outlined,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: GoogleFonts.inter(color: color, fontSize: 11),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.keyboard_arrow_down,
            size: 12,
            color: color,
          ),
        ],
      ),
    );
  }
}

class _ModelChip extends StatefulWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;

  const _ModelChip({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
  });

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  // (97h) No provider display-name fetch lives in this widget anymore; the
  // resource owner (`ProviderUsageCubit`) resolves `model.snapshot` and
  // `provider.usage.support` once per (device, query) and shares in-flight
  // requests. Widget lifecycle only asks the owner to ensure the logical
  // resource it consumes, which is a no-op when unchanged — rebuild/theme/
  // responsive remounts stay at zero extra Agent requests.
  bool _didSyncInitialResource = false;

  @override
  void initState() {
    super.initState();
    _syncProviderResource();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSyncInitialResource) return;
    _didSyncInitialResource = true;
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    _syncProviderResource(selectedSession: selectedSession);
  }

  @override
  void didUpdateWidget(covariant _ModelChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final agentChanged = oldWidget.agentSlice.activeAgent?.id != widget.agentSlice.activeAgent?.id;
    final providerChanged = oldWidget.inputSlice.nextMessageProviderId != widget.inputSlice.nextMessageProviderId;
    if (agentChanged || providerChanged) {
      _syncProviderResource();
    }
  }

  /// Asks the resource owner to ensure the catalog and the active provider's
  /// usage/support are loaded for the current device. The owner dedupes by
  /// (device, query) and shares in-flight requests, so repeated calls from
  /// rebuilds and remounts cost zero Agent requests after the first load.
  void _syncProviderResource({Session? selectedSession}) {
    if (!getIt.isRegistered<ProviderUsageCubit>()) return;
    final cubit = getIt<ProviderUsageCubit>();
    final resolved = selectedSession ?? (mounted ? context.read<SessionCubit>().state.selectedSession : null);
    final activeProviderId = _activeProviderId(resolved);
    if (activeProviderId == null || activeProviderId.isEmpty) return;
    unawaited(cubit.ensureProviderDisplayNames(agent: widget.agentSlice.activeAgent));
    unawaited(
      cubit.ensureInstanceUsage(
        agent: widget.agentSlice.activeAgent,
        instanceId: activeProviderId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedSession = context.select<SessionCubit, Session?>((cubit) => cubit.state.selectedSession);
    final contextUsage = context.select<SessionMessagesCubit, LlmUsageSnapshot?>(
      (cubit) => latestContextUsage(cubit.state.messages),
    );
    final showProgress = getIt.isRegistered<ProviderUsageCubit>();

    Widget buildChip(
      BuildContext context,
      Map<String, String> providerDisplayNames,
      double? progress,
      Color? progressColor,
    ) {
      final currentModel = _currentModelLabel(
        selectedSession,
        nextMessageModel: widget.inputSlice.nextMessageModel,
        providerDisplayNames: providerDisplayNames,
      );

      return InkWell(
        key: const Key('model_selector_btn'),
        onTap: () => _openModelPicker(context),
        borderRadius: BorderRadius.circular(8),
        child: _buildModelChip(context, currentModel, contextUsage, progress, progressColor),
      );
    }

    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) => previous.selectedSession != current.selectedSession,
      listener: (context, state) {
        _syncProviderResource(selectedSession: state.selectedSession);
      },
      child: showProgress
          ? BlocBuilder<ProviderUsageCubit, ProviderUsageState>(
              bloc: getIt<ProviderUsageCubit>(),
              builder: (context, usageState) {
                final theme = Theme.of(context);
                final deviceId = widget.agentSlice.activeAgent?.id ?? getIt<ProviderUsageCubit>().localDeviceId;
                final providerDisplayNames = usageState.displayNamesFor(deviceId);
                final activeProviderId = _activeProviderId(selectedSession);
                double? progress;
                Color? progressColor;

                if (activeProviderId != null && activeProviderId.isNotEmpty) {
                  final entry = usageState.entry(deviceId, activeProviderId);
                  final supports = usageState.support.supports(deviceId, activeProviderId);

                  if (supports && entry != null && entry.phase != ProviderUsagePhase.hidden) {
                    final hasSnapshot = entry.hasVisibleSnapshot;
                    if (hasSnapshot && entry.result?.snapshot?.windows != null) {
                      double maxProgress = 0.0;
                      for (final window in entry.result!.snapshot!.windows) {
                        final remaining = window.remainingPercent;
                        final used = window.usedPercent;
                        final p = (used ?? (remaining != null ? 100.0 - remaining : 0.0)) / 100.0;
                        if (p > maxProgress) {
                          maxProgress = p;
                        }
                      }
                      progress = maxProgress.clamp(0.0, 1.0);

                      Color getProgressColor(double value) {
                        if (value >= 0.9) return const Color(0xFFE53935);
                        return theme.colorScheme.primary;
                      }

                      progressColor = getProgressColor(progress);
                    }
                  }
                }

                return buildChip(context, providerDisplayNames, progress, progressColor);
              },
            )
          : Builder(
              builder: (context) => buildChip(context, const {}, null, null),
            ),
    );
  }

  void _openModelPicker(BuildContext context) {
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    final activeProviderId = widget.inputSlice.nextMessageProviderId?.trim().isNotEmpty == true
        ? widget.inputSlice.nextMessageProviderId!.trim()
        : selectedSession?.modelProvider?.trim();
    final activeModelId = widget.inputSlice.nextMessageModel?.trim().isNotEmpty == true
        ? widget.inputSlice.nextMessageModel!.trim()
        : selectedSession?.model?.trim();

    unawaited(
      showDialog(
        context: context,
        builder: (dialogContext) => ModelPickerDialog(
          agent: widget.agentSlice.activeAgent,
          activeProviderId: activeProviderId,
          activeModelId: activeModelId,
          onSelected: (providerId, modelId) {
            unawaited(
              context.read<ConversationInputCubit>().selectModel(
                scope: widget.capabilities.modelSelectionScope,
                providerId: providerId,
                model: modelId,
              ),
            );
            unawaited(
              getIt<ProviderSetupClient>().modelRecentRecord(
                providerInstanceId: providerId,
                modelId: modelId,
                agent: widget.agentSlice.activeAgent,
              ),
            );
          },
        ),
      ),
    );
  }

  String? _activeProviderId(Session? session) {
    final nextProviderId = widget.inputSlice.nextMessageProviderId?.trim();
    if (nextProviderId != null && nextProviderId.isNotEmpty) return nextProviderId;
    final sessionProvider = session?.modelProvider?.trim();
    if (sessionProvider != null && sessionProvider.isNotEmpty) return sessionProvider;
    final metadataProvider = session?.metadata?['provider']?.toString().trim();
    if (metadataProvider != null && metadataProvider.isNotEmpty) return metadataProvider;
    final metadataModelProvider = session?.metadata?['model_provider']?.toString().trim();
    if (metadataModelProvider != null && metadataModelProvider.isNotEmpty) return metadataModelProvider;
    return null;
  }

  String _currentModelLabel(
    Session? session, {
    String? nextMessageModel,
    Map<String, String> providerDisplayNames = const {},
  }) {
    final activeProviderId = _activeProviderId(session);
    final activeModelId = nextMessageModel?.trim().isNotEmpty == true
        ? nextMessageModel!.trim()
        : session?.model?.trim();
    if (activeModelId == null || activeModelId.isEmpty) return 'Select model';
    var cleanModelName = activeModelId;
    if (activeProviderId != null && activeProviderId.isNotEmpty) {
      final prefix = '${activeProviderId.toLowerCase()}/';
      if (cleanModelName.toLowerCase().startsWith(prefix)) cleanModelName = cleanModelName.substring(prefix.length);
    }
    if (cleanModelName.contains('/')) cleanModelName = cleanModelName.split('/').last;
    final providerDisplayName = resolveProviderDisplayName(
      session: session,
      providerId: activeProviderId,
      providerDisplayNames: providerDisplayNames,
    );
    if (providerDisplayName != null && providerDisplayName.isNotEmpty) {
      return '$providerDisplayName | $cleanModelName';
    }
    return cleanModelName;
  }

  Widget _buildModelChip(
    BuildContext context,
    String text,
    LlmUsageSnapshot? contextUsage,
    double? progress,
    Color? progressColor,
  ) {
    final parts = text.split(' | ');
    final provider = parts.length > 1 ? parts[0] : null;
    final model = parts.length > 1 ? parts[1] : text;

    final useTwoLineLayout = provider != null && SidebarBreakpoints.isCompact(context);

    return Container(
      decoration: BoxDecoration(
        color: widget.chipBgColor.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.borderColor),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (progress != null && progressColor != null)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      color: progressColor.withValues(alpha: 0.20),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: useTwoLineLayout ? 2 : 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (contextUsage?.usageFraction != null) ...[
                    ContextUsageIndicator(usage: contextUsage!),
                    const SizedBox(width: 6),
                  ],
                  if (useTwoLineLayout)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          model,
                          style: GoogleFonts.inter(
                            color: widget.dimTextColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          provider,
                          style: GoogleFonts.inter(
                            color: widget.dimTextColor.withValues(alpha: 0.7),
                            fontSize: 9,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    )
                  else
                    Text(
                      text,
                      style: GoogleFonts.inter(color: widget.dimTextColor, fontSize: 11),
                    ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down, size: 12, color: widget.dimTextColor),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendStopButton extends StatelessWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final SlashCommandTextController chatController;
  final void Function({MessageDeliveryIntent intent}) onSendAttempt;
  final VoidCallback? onStop;
  final Color dimTextColor;
  final String? sessionId;

  const _SendStopButton({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.chatController,
    required this.onSendAttempt,
    required this.onStop,
    required this.dimTextColor,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = chatController.exportPlainText().trim().isEmpty;

    final hasWorkspace = !inputSlice.requiresWorkspace || inputSlice.selectedWorkspace != null;
    final inputCubit = _maybeInputCubit(context);
    final attachments = inputCubit == null
        ? const <DraftAttachment>[]
        : context.watch<ConversationInputCubit>().state.draftAttachments;
    final attachmentsReady = attachments.every(
      (attachment) => attachment.status == DraftAttachmentStatus.ready,
    );
    final hasContent = !isEmpty || attachments.isNotEmpty;
    final canSend =
        agentSlice.isOnline &&
        hasContent &&
        attachmentsReady &&
        hasWorkspace &&
        inputSlice.pendingSuspendedRequest == null;

    final executionSnapshot = inputSlice.executionSnapshot;
    final isStopping = executionSnapshot?.isStopping ?? false;
    final showStopButton = capabilities.supportsStop && (executionSnapshot?.canStop == true || isStopping) && isEmpty;

    final showVoiceButton =
        capabilities.supportsVoiceCall &&
        agentSlice.hasActiveAgent &&
        agentSlice.isOnline &&
        isEmpty &&
        executionSnapshot?.hasActiveWork != true;

    if (showStopButton) {
      return SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: const Key('stop_message_btn'),
          tooltip: isStopping ? 'Stopping response' : 'Stop response',
          onPressed: isStopping ? null : onStop,
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
            side: BorderSide(
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.2),
            ),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
          ),
          icon: isStopping
              ? SizedBox(
                  key: const Key('stop_message_progress_indicator'),
                  width: 16,
                  height: 16,
                  child: AppProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.error,
                  ),
                )
              : Icon(
                  Icons.stop_circle_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
        ),
      );
    }

    if (inputSlice.isAwaitingMessageAcceptance) {
      return SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: const Key('send_message_acceptance_indicator'),
          tooltip: 'Waiting for message acceptance',
          onPressed: null,
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.onSurface,
            disabledBackgroundColor: Theme.of(context).colorScheme.onSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
          ),
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: AppProgressIndicator(
              strokeWidth: 2,
              color: Colors.black,
            ),
          ),
        ),
      );
    }

    if (showVoiceButton) {
      return SizedBox(
        width: 32,
        height: 32,
        child: BlocBuilder<VoiceStreamCubit, VoiceStreamState>(
          builder: (context, voiceState) {
            final isActive = voiceState.isSessionActive;
            final isConnecting = voiceState.status == VoiceSessionStatus.connecting;
            return IconButton(
              key: const Key('voice_chat_btn'),
              tooltip: isActive ? 'Stop voice session' : 'Start voice session',
              onPressed: () async {
                final voiceCubit = context.read<VoiceStreamCubit>();
                if (isActive) {
                  await voiceCubit.stopVoiceSession();
                } else {
                  final activeAgent = agentSlice.activeAgent;
                  if (activeAgent != null) {
                    await voiceCubit.startVoiceSession(
                      agent: activeAgent,
                      sessionId: sessionId ?? 'default',
                    );
                  }
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: isActive
                    ? (isConnecting ? Colors.orange.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1))
                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: EdgeInsets.zero,
              ),
              icon: Icon(
                isConnecting ? Icons.hourglass_empty : Symbols.earthquake,
                size: 16,
                color: isActive ? (isConnecting ? Colors.orange : Colors.red) : Theme.of(context).colorScheme.primary,
              ),
            );
          },
        ),
      );
    }

    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: const Key('send_message_btn'),
        tooltip: executionSnapshot?.isExecuting == true
            ? 'Press Enter to steer • Ctrl/Cmd+Enter to queue'
            : 'Send message',
        onPressed: canSend ? () => onSendAttempt(intent: MessageDeliveryIntent.auto) : null,
        style: IconButton.styleFrom(
          backgroundColor: canSend ? Theme.of(context).colorScheme.onSurface : dimTextColor.withValues(alpha: 0.1),
          disabledBackgroundColor: dimTextColor.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: EdgeInsets.zero,
        ),
        icon: Icon(
          Icons.arrow_upward_rounded,
          size: 16,
          color: canSend ? Theme.of(context).colorScheme.surface : dimTextColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

class _WorkspaceWarning extends StatelessWidget {
  final VoidCallback onRefresh;

  const _WorkspaceWarning({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRefresh,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.error.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_open_outlined, size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Select a workspace before your first Sanad Agent message.',
                style: GoogleFonts.inter(
                  color: colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 12, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
