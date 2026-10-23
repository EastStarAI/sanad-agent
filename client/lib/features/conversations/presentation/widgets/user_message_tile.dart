import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:sanad_client/utils/format_utils.dart';
import 'package:sanad_client/utils/link_utils.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/inline_edit_attachment_thumbnail.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_attachment_grid.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_link_builder.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';

enum InlineEditAttachmentStatus { ready, failed }

class InlineEditAttachmentSelection {
  const InlineEditAttachmentSelection({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class InlineEditAttachment {
  const InlineEditAttachment({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.isImage,
    required this.isExisting,
    this.attachment,
    this.bytes,
    this.status = InlineEditAttachmentStatus.ready,
    this.error,
  });

  factory InlineEditAttachment.existing(UserMessageAttachment attachment) => InlineEditAttachment(
    id: attachment.id,
    name: attachment.safeName,
    sizeBytes: attachment.sizeBytes,
    isImage: attachment.isImage,
    isExisting: true,
    attachment: attachment,
  );

  final String id;
  final String name;
  final int sizeBytes;
  final bool isImage;
  final bool isExisting;

  /// The canonical attachment an existing edit item references; its preview
  /// loads through the same media loader as the message bubble. New items
  /// carry their local [bytes] instead and have no canonical attachment.
  final UserMessageAttachment? attachment;
  final Uint8List? bytes;
  final InlineEditAttachmentStatus status;
  final String? error;
}

class UserMessageTile extends StatefulWidget {
  final CanonicalEvent event;
  final String? sessionId;
  final Future<void> Function(String requestId)? onCancelPendingSteer;
  final bool isCancellingPendingSteer;
  final bool canReplay;
  final bool isEditing;
  final bool isReplayPending;
  final TextEditingController? editController;
  final VoidCallback? onBeginEdit;
  final VoidCallback? onCancelEdit;
  final Future<void> Function()? onSubmitEdit;
  final Future<void> Function()? onRetry;
  final UserAttachmentMediaLoader? attachmentMediaLoader;
  final List<InlineEditAttachment> editAttachments;
  final String? editAttachmentError;
  final Future<void> Function()? onAddEditAttachment;
  final ValueChanged<String>? onRemoveEditAttachment;
  final ValueChanged<String>? onRetryEditAttachment;

  /// Dismisses [editAttachmentError]; `null` hides the close control.
  final VoidCallback? onDismissEditAttachmentError;
  final Future<void> Function(String? url)? onOpenUrl;

  const UserMessageTile({
    super.key,
    required this.event,
    this.sessionId,
    this.onCancelPendingSteer,
    this.isCancellingPendingSteer = false,
    this.canReplay = false,
    this.isEditing = false,
    this.isReplayPending = false,
    this.editController,
    this.onBeginEdit,
    this.onCancelEdit,
    this.onSubmitEdit,
    this.onRetry,
    this.attachmentMediaLoader,
    this.editAttachments = const [],
    this.editAttachmentError,
    this.onAddEditAttachment,
    this.onRemoveEditAttachment,
    this.onRetryEditAttachment,
    this.onDismissEditAttachmentError,
    this.onOpenUrl,
  });

  @override
  State<UserMessageTile> createState() => _UserMessageTileState();
}

class _UserMessageTileState extends State<UserMessageTile> with SingleTickerProviderStateMixin {
  bool _isExpanded = false;

  String get _effectiveSessionId => widget.sessionId ?? widget.event.sessionId ?? '';

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
  }

  Future<void> _handleOpenUrl(String? url) async {
    if (url == null || url.toLowerCase().startsWith('file://')) {
      return;
    }
    if (widget.onOpenUrl != null) {
      await widget.onOpenUrl!(url);
    } else {
      await openExternalUrl(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final timestampText = EventMetadataFormatter.timestampText(
      widget.event.timestamp,
      context,
    );
    final pendingState = widget.event.metadata?['pending_steer_state']?.toString();
    final requestId = widget.event.requestId;
    final isPending = pendingState == 'pending';
    final attachments = widget.event.userAttachments;

    final textDirection = TextUtils.getTextDirection(widget.event.text);
    final textStyle = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: 14,
      height: 1.5,
    );

    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = (screenWidth - 88).clamp(100.0, double.infinity);

    final span = TextSpan(
      text: UserMessageLinkBuilder.measurableText(widget.event.text),
      style: textStyle,
    );
    final tp = TextPainter(text: span, textDirection: textDirection);
    tp.layout(maxWidth: maxBubbleWidth);

    final lines = tp.computeLineMetrics();
    final isOverflowing = lines.length > 5;
    final maxCollapsedHeight = isOverflowing
        ? (lines.take(5).fold(0.0, (sum, line) => sum + line.height) + 6.0)
        : tp.size.height;

    final markdownWidget = MarkdownBody(
      data: widget.event.text,
      softLineBreak: true,
      styleSheet: MarkdownStyleHelper.getStyleSheet(context).copyWith(p: textStyle),
      onTapLink: (text, href, title) => unawaited(_handleOpenUrl(href)),
      builders: {
        'code': AppInlineCodeBuilder(context),
        'a': UserMessageLinkBuilder(context, onOpenUrl: _handleOpenUrl),
      },
    );

    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            margin: const EdgeInsets.only(
              left: 48,
              right: 16,
              top: 12,
              bottom: 8,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16).copyWith(topRight: Radius.zero),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: widget.isEditing
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: _buildInlineEditor(context),
                  )
                : InkWell(
                    onTap: isOverflowing ? _toggleExpanded : null,
                    borderRadius: BorderRadius.circular(16).copyWith(topRight: Radius.zero),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (attachments.isNotEmpty) ...[
                            UserAttachmentGrid(
                              attachments: attachments,
                              sessionId: _effectiveSessionId,
                              loader: widget.attachmentMediaLoader,
                            ),
                            if (widget.event.text.isNotEmpty) const SizedBox(height: 10),
                          ],
                          SelectionArea(
                            child: Directionality(
                              textDirection: textDirection,
                              child: KeyedSubtree(
                                key: Key(
                                  'user_message_body:${widget.event.id}',
                                ),
                                child: AnimatedSize(
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeInOut,
                                  alignment: Alignment.topCenter,
                                  child: (isOverflowing && !_isExpanded)
                                      ? SizedBox(
                                          height: maxCollapsedHeight,
                                          child: ClipRect(
                                            child: OverflowBox(
                                              minHeight: 0,
                                              maxHeight: double.infinity,
                                              alignment: Alignment.topCenter,
                                              child: markdownWidget,
                                            ),
                                          ),
                                        )
                                      : markdownWidget,
                                ),
                              ),
                            ),
                          ),
                          if (isOverflowing) ...[
                            // const SizedBox(height: 6),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _isExpanded ? 'See less' : 'Read more',
                                  style: GoogleFonts.roboto(
                                    color: Theme.of(context).colorScheme.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(
                                  _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  size: 14,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
          Container(
            margin: const EdgeInsets.only(left: 48, right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (timestampText.isNotEmpty) ...[
                  Tooltip(
                    message: EventMetadataFormatter.dateTooltip(
                      widget.event.timestamp,
                      context,
                    ),
                    child: Text(
                      timestampText,
                      style: GoogleFonts.roboto(
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (isPending) ...[
                  Text(
                    'Pending',
                    style: GoogleFonts.roboto(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (widget.isCancellingPendingSteer)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: AppProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Semantics(
                      label: 'Delete pending message',
                      child: IconButton(
                        tooltip: 'Delete pending message',
                        style: ConversationActionStyle.buttonStyle,
                        visualDensity: VisualDensity.compact,
                        constraints: ConversationActionStyle.constraints,
                        padding: EdgeInsets.zero,
                        onPressed: requestId == null || widget.onCancelPendingSteer == null
                            ? null
                            : () {
                                unawaited(
                                  widget.onCancelPendingSteer!(requestId),
                                );
                              },
                        icon: const Icon(Icons.delete_outline, size: 15),
                      ),
                    ),
                  const SizedBox(width: 4),
                ],
                if (widget.canReplay && !widget.isEditing && !isPending) ...[
                  Semantics(
                    label: 'Edit message',
                    child: IconButton(
                      key: const Key('edit_message_button'),
                      tooltip: 'Edit message',
                      style: ConversationActionStyle.buttonStyle,
                      visualDensity: VisualDensity.compact,
                      constraints: ConversationActionStyle.constraints,
                      padding: EdgeInsets.zero,
                      onPressed: widget.isReplayPending ? null : widget.onBeginEdit,
                      icon: Icon(
                        Icons.edit_outlined,
                        size: ConversationActionStyle.iconSize,
                        color: ConversationActionStyle.iconColor(context),
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'Retry message',
                    child: IconButton(
                      key: const Key('retry_message_button'),
                      tooltip: 'Retry message',
                      style: ConversationActionStyle.buttonStyle,
                      visualDensity: VisualDensity.compact,
                      constraints: ConversationActionStyle.constraints,
                      padding: EdgeInsets.zero,
                      onPressed: widget.isReplayPending || widget.onRetry == null
                          ? null
                          : () => unawaited(widget.onRetry!()),
                      icon: widget.isReplayPending
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: AppProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.refresh,
                              size: ConversationActionStyle.iconSize,
                              color: ConversationActionStyle.iconColor(context),
                            ),
                    ),
                  ),
                ],
                CopyButton(
                  text: widget.event.text,
                  successMessage: 'Message copied to clipboard',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineEditor(BuildContext context) {
    final controller = widget.editController;
    if (controller == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.editAttachments.isNotEmpty ||
            widget.editAttachmentError != null ||
            widget.onAddEditAttachment != null) ...[
          _buildEditAttachmentRail(context),
          const SizedBox(height: 8),
        ],
        MultilineSubmissionShortcuts(
          controller: controller,
          onSubmit: () {
            if (widget.isReplayPending || widget.onSubmitEdit == null) return;
            unawaited(widget.onSubmitEdit!());
          },
          child: TextField(
            key: const Key('inline_message_editor'),
            controller: controller,
            enabled: !widget.isReplayPending,
            autofocus: true,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 2,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'Edit message',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            FilledButton(
              key: const Key('send_edited_message_button'),
              onPressed: widget.isReplayPending || widget.onSubmitEdit == null
                  ? null
                  : () => unawaited(widget.onSubmitEdit!()),
              child: widget.isReplayPending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: AppProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send'),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('cancel_message_edit_button'),
              onPressed: widget.isReplayPending ? null : widget.onCancelEdit,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditAttachmentRail(BuildContext context) => Column(
    key: const Key('inline_edit_attachment_rail'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final attachment in widget.editAttachments)
            Semantics(
              label: '${attachment.isExisting ? 'Existing' : 'New'} attachment ${attachment.name}',
              child: Container(
                key: ValueKey('inline_edit_attachment_${attachment.id}'),
                constraints: const BoxConstraints(maxWidth: 190),
                padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 4, 6),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InlineEditAttachmentThumbnail(
                      key: ValueKey('inline_edit_attachment_thumbnail_${attachment.id}'),
                      attachment: attachment,
                      sessionId: _effectiveSessionId,
                      loader: widget.attachmentMediaLoader,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            attachment.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            attachment.status == InlineEditAttachmentStatus.failed
                                ? 'Failed'
                                : attachment.isExisting
                                ? 'Ready · existing'
                                : 'Ready · new',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    if (attachment.status == InlineEditAttachmentStatus.failed && widget.onRetryEditAttachment != null)
                      IconButton(
                        key: ValueKey(
                          'retry_inline_edit_attachment_${attachment.id}',
                        ),
                        tooltip: 'Retry attachment',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.isReplayPending
                            ? null
                            : () => widget.onRetryEditAttachment!(
                                attachment.id,
                              ),
                        icon: const Icon(Icons.refresh, size: 18),
                      ),
                    IconButton(
                      key: ValueKey(
                        'remove_inline_edit_attachment_${attachment.id}',
                      ),
                      tooltip: 'Remove attachment',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.isReplayPending || widget.onRemoveEditAttachment == null
                          ? null
                          : () => widget.onRemoveEditAttachment!(attachment.id),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          if (widget.onAddEditAttachment != null)
            OutlinedButton.icon(
              key: const Key('add_inline_edit_attachment'),
              onPressed: widget.isReplayPending ? null : () => unawaited(widget.onAddEditAttachment!()),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
        ],
      ),
      if (widget.editAttachmentError case final error?) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                error,
                key: const Key('inline_edit_attachment_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            if (widget.onDismissEditAttachmentError case final dismiss?)
              IconButton(
                key: const Key('inline_edit_attachment_error_dismiss'),
                tooltip: (AppLocalizations.of(context) ?? AppLocalizationsEn()).attachmentErrorDismiss,
                visualDensity: VisualDensity.compact,
                onPressed: dismiss,
                icon: Icon(Icons.close, size: 16, color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ],
    ],
  );
}
