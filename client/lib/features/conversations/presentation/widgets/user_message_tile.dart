import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:sanad_client/utils/format_utils.dart';
import 'package:sanad_client/utils/link_utils.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';

class UserMessageTile extends StatefulWidget {
  final CanonicalEvent event;
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

  const UserMessageTile({
    super.key,
    required this.event,
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
  });

  @override
  State<UserMessageTile> createState() => _UserMessageTileState();
}

class _UserMessageTileState extends State<UserMessageTile> with SingleTickerProviderStateMixin {
  bool _isExpanded = false;

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final timestampText = EventMetadataFormatter.timestampText(widget.event.timestamp, context);
    final pendingState = widget.event.metadata?['pending_steer_state']?.toString();
    final requestId = widget.event.requestId;
    final isPending = pendingState == 'pending';

    final textDirection = TextUtils.getTextDirection(widget.event.text);
    final textStyle = GoogleFonts.roboto(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: 14,
      height: 1.5,
    );

    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = (screenWidth - 88).clamp(100.0, double.infinity);

    final span = TextSpan(text: widget.event.text, style: textStyle);
    final tp = TextPainter(
      text: span,
      textDirection: textDirection,
    );
    tp.layout(maxWidth: maxBubbleWidth);

    final lines = tp.computeLineMetrics();
    final isOverflowing = lines.length > 5;
    final maxCollapsedHeight = isOverflowing
        ? (lines.take(5).fold(0.0, (sum, line) => sum + line.height) + 6.0)
        : tp.size.height;

    final markdownWidget = MarkdownBody(
      data: widget.event.text,
      styleSheet: MarkdownStyleHelper.getStyleSheet(context).copyWith(
        p: textStyle,
      ),
      onTapLink: (text, href, title) => unawaited(openExternalUrl(href)),
      builders: {
        'code': AppInlineCodeBuilder(context),
      },
    );

    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            margin: const EdgeInsets.only(left: 48, right: 16, top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16).copyWith(topRight: Radius.zero),
              border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
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
                          SelectionArea(
                            child: Directionality(
                              textDirection: textDirection,
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
                  Text(
                    timestampText,
                    style: GoogleFonts.roboto(
                      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                      fontSize: 11,
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
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Semantics(
                      label: 'Delete pending message',
                      child: IconButton(
                        tooltip: 'Delete pending message',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                        padding: EdgeInsets.zero,
                        onPressed: requestId == null || widget.onCancelPendingSteer == null
                            ? null
                            : () {
                                unawaited(widget.onCancelPendingSteer!(requestId));
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.refresh,
                              size: ConversationActionStyle.iconSize,
                              color: ConversationActionStyle.iconColor(context),
                            ),
                    ),
                  ),
                ],
                CopyButton(text: widget.event.text, successMessage: 'Message copied to clipboard'),
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
                      child: CircularProgressIndicator(strokeWidth: 2),
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
}
