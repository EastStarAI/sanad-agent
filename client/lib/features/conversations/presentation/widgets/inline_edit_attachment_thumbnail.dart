import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';

class InlineEditAttachmentThumbnail extends StatefulWidget {
  const InlineEditAttachmentThumbnail({
    super.key,
    required this.attachment,
    required this.sessionId,
    this.loader,
  });

  final InlineEditAttachment attachment;
  final String sessionId;
  final UserAttachmentMediaLoader? loader;

  @override
  State<InlineEditAttachmentThumbnail> createState() => _InlineEditAttachmentThumbnailState();
}

class _InlineEditAttachmentThumbnailState extends State<InlineEditAttachmentThumbnail> {
  ViewImageMediaLoad? _load;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant InlineEditAttachmentThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload only for a different logical resource; a rebuilt parent that
    // passes a new loader instance must not issue another Agent request.
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.attachment?.mediaId != widget.attachment.attachment?.mediaId ||
        oldWidget.attachment.bytes != widget.attachment.bytes ||
        oldWidget.sessionId != widget.sessionId) {
      _load?.cancel();
      _load = null;
      _startLoad();
    }
  }

  void _startLoad() {
    _load?.cancel();
    _load = null;
    if (!widget.attachment.isImage || widget.attachment.bytes != null) {
      return;
    }
    // Only a canonical, available reference is ever requested; identity is
    // never synthesized for a reference the client does not hold.
    final userAttachment = widget.attachment.attachment;
    if (userAttachment == null || !userAttachment.isAvailable || widget.sessionId.isEmpty) {
      return;
    }
    // Same loader resolution as the message bubble's attachment card.
    final loader = widget.loader ?? ViewImageMediaRepository.local();
    try {
      _load = loader.loadAttachment(
        attachment: userAttachment,
        sessionId: widget.sessionId,
      );
    } catch (_) {
      _load = null;
    }
  }

  void _retry() {
    setState(() {
      _startLoad();
    });
  }

  @override
  void dispose() {
    _load?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.attachment.isImage) {
      return FileExtensionIcon(fileName: widget.attachment.name, size: 22);
    }

    if (widget.attachment.bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          widget.attachment.bytes!,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(
            Icons.image_outlined,
            size: 22,
          ),
        ),
      );
    }

    final load = _load;
    if (load == null) {
      return GestureDetector(
        onTap: _retry,
        child: const Icon(
          Icons.image_outlined,
          size: 22,
        ),
      );
    }

    return FutureBuilder<Uint8List>(
      future: load.bytes,
      initialData: load.cachedBytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return GestureDetector(
            onTap: _retry,
            child: const Icon(
              Icons.image_outlined,
              size: 22,
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const SizedBox(
            width: 28,
            height: 28,
            child: Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: AppProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            bytes,
            width: 28,
            height: 28,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => GestureDetector(
              onTap: _retry,
              child: const Icon(
                Icons.image_outlined,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }
}
