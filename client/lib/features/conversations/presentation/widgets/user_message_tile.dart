import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:sanad_client/utils/format_utils.dart';
import 'package:sanad_client/utils/link_utils.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';

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
  );

  final String id;
  final String name;
  final int sizeBytes;
  final bool isImage;
  final bool isExisting;
  final Uint8List? bytes;
  final InlineEditAttachmentStatus status;
  final String? error;
}

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
  final UserAttachmentMediaLoader? attachmentMediaLoader;
  final List<InlineEditAttachment> editAttachments;
  final String? editAttachmentError;
  final Future<void> Function()? onAddEditAttachment;
  final ValueChanged<String>? onRemoveEditAttachment;
  final ValueChanged<String>? onRetryEditAttachment;

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
    this.attachmentMediaLoader,
    this.editAttachments = const [],
    this.editAttachmentError,
    this.onAddEditAttachment,
    this.onRemoveEditAttachment,
    this.onRetryEditAttachment,
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
    final attachments = widget.event.userAttachments;

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
                          if (attachments.isNotEmpty) ...[
                            _UserAttachmentGrid(
                              attachments: attachments,
                              sessionId: widget.event.sessionId ?? '',
                              loader: widget.attachmentMediaLoader,
                            ),
                            if (widget.event.text.isNotEmpty) const SizedBox(height: 10),
                          ],
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
                    if (attachment.isImage && attachment.bytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.memory(
                          attachment.bytes!,
                          width: 28,
                          height: 28,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.image_outlined,
                            size: 22,
                          ),
                        ),
                      )
                    else
                      Icon(
                        attachment.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
                        size: 22,
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
        Text(
          error,
          key: const Key('inline_edit_attachment_error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ],
  );
}

class _UserAttachmentGrid extends StatelessWidget {
  const _UserAttachmentGrid({
    required this.attachments,
    required this.sessionId,
    this.loader,
  });

  final List<UserMessageAttachment> attachments;
  final String sessionId;
  final UserAttachmentMediaLoader? loader;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GridView.builder(
      key: const Key('user_attachment_grid'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: constraints.maxWidth < 360 ? 2 : 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.15,
      ),
      itemCount: attachments.length,
      itemBuilder: (context, index) => _UserAttachmentCard(
        key: ValueKey('user_attachment_${attachments[index].id}'),
        attachment: attachments[index],
        sessionId: sessionId,
        loader: loader,
      ),
    ),
  );
}

class _UserAttachmentCard extends StatefulWidget {
  const _UserAttachmentCard({
    super.key,
    required this.attachment,
    required this.sessionId,
    this.loader,
  });

  final UserMessageAttachment attachment;
  final String sessionId;
  final UserAttachmentMediaLoader? loader;

  @override
  State<_UserAttachmentCard> createState() => _UserAttachmentCardState();
}

class _UserAttachmentCardState extends State<_UserAttachmentCard> {
  ViewImageMediaLoad? _load;
  ViewImageMediaLoad? _fileLoad;
  bool _isOpeningFile = false;
  bool _fileUnavailable = false;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant _UserAttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.mediaId != widget.attachment.mediaId ||
        oldWidget.attachment.isAvailable != widget.attachment.isAvailable ||
        oldWidget.sessionId != widget.sessionId) {
      _load?.cancel();
      _fileLoad?.cancel();
      _isOpeningFile = false;
      _fileUnavailable = false;
      _startLoad();
    }
  }

  void _startLoad() {
    _load = null;
    if (!widget.attachment.isImage || !widget.attachment.isAvailable || widget.sessionId.isEmpty) {
      return;
    }
    final loader = widget.loader ?? ViewImageMediaRepository.local();
    _load = loader.loadAttachment(
      attachment: widget.attachment,
      sessionId: widget.sessionId,
    );
  }

  @override
  void dispose() {
    _load?.cancel();
    _fileLoad?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.attachment.isImage) return _fileCard(context);
    final load = _load;
    if (load == null) return _unavailableCard(context);
    return FutureBuilder<Uint8List>(
      future: load.bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _unavailableCard(context);
        final bytes = snapshot.data;
        if (bytes == null) {
          return const Card(
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Semantics(
          button: true,
          label: 'Open attached image ${widget.attachment.safeName}',
          child: InkWell(
            key: ValueKey('open_user_attachment_${widget.attachment.id}'),
            onTap: () => _showImage(context, bytes),
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                semanticLabel: 'Attached image ${widget.attachment.safeName}',
                errorBuilder: (_, _, _) => _unavailableCard(context),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _fileCard(BuildContext context) {
    final available = widget.attachment.isAvailable && !_fileUnavailable;
    return Semantics(
      button: available,
      label: available ? 'Open attached file ${widget.attachment.safeName}' : 'Attached file unavailable',
      child: Card(
        key: ValueKey('user_file_attachment_${widget.attachment.id}'),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: available && !_isOpeningFile ? () => unawaited(_openFile(context)) : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isOpeningFile)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.insert_drive_file_outlined, size: 28),
                const SizedBox(height: 6),
                Text(
                  widget.attachment.safeName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                if (!available) const Text('Unavailable', style: TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFile(BuildContext context) async {
    final loader = widget.loader ?? ViewImageMediaRepository.local();
    final load = loader.loadAttachment(
      attachment: widget.attachment,
      sessionId: widget.sessionId,
    );
    _fileLoad?.cancel();
    _fileLoad = load;
    setState(() => _isOpeningFile = true);
    try {
      final bytes = await load.bytes;
      if (!mounted || !identical(_fileLoad, load)) return;
      if (widget.attachment.mimeType.startsWith('text/') && bytes.length <= 256 * 1024) {
        await _showTextPreview(context, utf8.decode(bytes, allowMalformed: true));
      } else {
        final location = await getSaveLocation(
          suggestedName: widget.attachment.safeName,
        );
        if (location != null) {
          await XFile.fromData(
            bytes,
            mimeType: widget.attachment.mimeType,
            name: widget.attachment.safeName,
          ).saveTo(location.path);
        }
      }
    } catch (_) {
      if (mounted && identical(_fileLoad, load)) {
        setState(() => _fileUnavailable = true);
      }
    } finally {
      if (mounted && identical(_fileLoad, load)) {
        setState(() => _isOpeningFile = false);
      }
    }
  }

  Future<void> _showTextPreview(BuildContext context, String text) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('user_attachment_text_preview'),
      title: Text(widget.attachment.safeName),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(child: SelectableText(text)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Widget _unavailableCard(BuildContext context) => Card(
    key: ValueKey('user_attachment_unavailable_${widget.attachment.id}'),
    child: Semantics(
      label: 'Attachment unavailable',
      child: const Center(child: Text('Unavailable')),
    ),
  );

  Future<void> _showImage(BuildContext context, Uint8List bytes) => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      key: const Key('user_attachment_lightbox'),
      child: Stack(
        children: [
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                semanticLabel: 'Full-size attached image ${widget.attachment.safeName}',
              ),
            ),
          ),
          PositionedDirectional(
            top: 8,
            end: 8,
            child: IconButton(
              key: const Key('user_attachment_lightbox_close'),
              tooltip: 'Close attachment preview',
              onPressed: () => Navigator.of(dialogContext).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}
