import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/media/image_lightbox.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';

/// Attachment grid of one user message. Its image attachments form one
/// [LightboxGroup], so the lightbox navigates them in message order.
class UserAttachmentGrid extends StatefulWidget {
  const UserAttachmentGrid({
    required this.attachments,
    required this.sessionId,
    this.loader,
  });

  final List<UserMessageAttachment> attachments;
  final String sessionId;
  final UserAttachmentMediaLoader? loader;

  @override
  State<UserAttachmentGrid> createState() => _UserAttachmentGridState();
}

class _UserAttachmentGridState extends State<UserAttachmentGrid> {
  final LightboxGroup _lightboxGroup = LightboxGroup();

  void _syncOrder() => _lightboxGroup.setOrder([
    for (final attachment in widget.attachments)
      if (attachment.isImage) attachment.id,
  ]);

  @override
  void initState() {
    super.initState();
    _syncOrder();
  }

  @override
  void didUpdateWidget(covariant UserAttachmentGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncOrder();
  }

  List<UserMessageAttachment> get attachments => widget.attachments;

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
      itemBuilder: (context, index) => UserAttachmentCard(
        key: ValueKey('user_attachment_${attachments[index].id}'),
        attachment: attachments[index],
        sessionId: widget.sessionId,
        loader: widget.loader,
        lightboxGroup: _lightboxGroup,
      ),
    ),
  );
}

class UserAttachmentCard extends StatefulWidget {
  const UserAttachmentCard({
    super.key,
    required this.attachment,
    required this.sessionId,
    this.loader,
    this.lightboxGroup,
  });

  final UserMessageAttachment attachment;
  final String sessionId;
  final UserAttachmentMediaLoader? loader;
  final LightboxGroup? lightboxGroup;

  @override
  State<UserAttachmentCard> createState() => _UserAttachmentCardState();
}

class _UserAttachmentCardState extends State<UserAttachmentCard> {
  ViewImageMediaLoad? _load;
  LightboxImage? _lightboxImage;
  ViewImageMediaLoad? _fileLoad;
  bool _isOpeningFile = false;
  bool _fileUnavailable = false;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant UserAttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.mediaId != widget.attachment.mediaId ||
        oldWidget.attachment.isAvailable != widget.attachment.isAvailable ||
        oldWidget.sessionId != widget.sessionId) {
      _unregister(oldWidget.lightboxGroup, oldWidget.attachment.id);
      _load?.cancel();
      _fileLoad?.cancel();
      _isOpeningFile = false;
      _fileUnavailable = false;
      _startLoad();
    } else if (oldWidget.lightboxGroup != widget.lightboxGroup || oldWidget.attachment.id != widget.attachment.id) {
      _unregister(oldWidget.lightboxGroup, oldWidget.attachment.id);
      _register();
    }
  }

  void _startLoad() {
    _load = null;
    _lightboxImage = null;
    if (!widget.attachment.isImage || !widget.attachment.isAvailable || widget.sessionId.isEmpty) {
      return;
    }
    final loader = widget.loader ?? ViewImageMediaRepository.local();
    final load = loader.loadAttachment(
      attachment: widget.attachment,
      sessionId: widget.sessionId,
    );
    _load = load;
    _lightboxImage = _lightboxImageFor(load.bytes, load.cachedBytes);
    _register();
  }

  LightboxImage _lightboxImageFor(Future<Uint8List> bytes, Uint8List? cachedBytes) => LightboxImage(
    bytes: bytes,
    cachedBytes: cachedBytes,
    semanticLabel: 'Full-size attached image ${widget.attachment.safeName}',
    preferredFileName: widget.attachment.safeName,
  );

  void _register() {
    final image = _lightboxImage;
    if (image != null) widget.lightboxGroup?.register(widget.attachment.id, image);
  }

  void _unregister(LightboxGroup? group, String id) {
    final image = _lightboxImage;
    if (image != null) group?.unregister(id, image);
  }

  @override
  void dispose() {
    _unregister(widget.lightboxGroup, widget.attachment.id);
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
      initialData: load.cachedBytes,
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
                gaplessPlayback: true,
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
                  FileExtensionIcon(fileName: widget.attachment.safeName, size: 28),
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

  Future<void> _showImage(BuildContext context, Uint8List bytes) {
    final opening = openLightboxGroup(
      widget.lightboxGroup,
      widget.attachment.id,
      _lightboxImageFor(Future<Uint8List>.value(bytes), bytes),
    );
    return showImageLightbox(
      context,
      images: opening.images,
      initialIndex: opening.index,
      dialogKey: const Key('user_attachment_lightbox'),
      closeKey: const Key('user_attachment_lightbox_close'),
    );
  }
}
