import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

/// Reusable card widget for presenting image media results (view_image and
/// media-bearing system_screenshot).
///
/// Encapsulates independent hydration, thumbnail aspect-ratio presentation,
/// max-height constraint, tap-to-lightbox, loading progress, and unavailable/error states.
class ViewImageToolCard extends StatefulWidget {
  const ViewImageToolCard({
    super.key,
    required this.event,
    this.loader,
    this.minWidth = 160,
  });

  final CanonicalEvent event;
  final ViewImageMediaLoader? loader;
  final double? minWidth;

  @override
  State<ViewImageToolCard> createState() => _ViewImageToolCardState();
}

class _ViewImageToolCardState extends State<ViewImageToolCard> {
  ViewImageMediaLoad? _load;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant ViewImageToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.viewImageMedia?.mediaId != widget.event.viewImageMedia?.mediaId ||
        oldWidget.event.viewImageMedia?.isAvailable != widget.event.viewImageMedia?.isAvailable ||
        oldWidget.event.sessionId != widget.event.sessionId ||
        oldWidget.event.status != widget.event.status ||
        oldWidget.event.isError != widget.event.isError) {
      _load?.cancel();
      _startLoad();
    }
  }

  void _startLoad() {
    _load = null;
    final media = widget.event.viewImageMedia;
    final sessionId = widget.event.sessionId ?? '';
    if (media == null || !media.isAvailable || sessionId.isEmpty) return;
    final loader = widget.loader ?? ViewImageMediaRepository.local();
    _load = loader.load(media: media, sessionId: sessionId);
  }

  @override
  void dispose() {
    _load?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.event.status == EventStatus.running) {
      return _buildRunning(context);
    }
    if (widget.event.isError) {
      return _buildError(context);
    }

    final media = widget.event.viewImageMedia;
    if (media != null) {
      return _buildMediaContent(context, media);
    }

    return const UnavailableViewImage();
  }

  Widget _buildRunning(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: AppProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            'Executing tool...',
            style: GoogleFonts.roboto(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    final message = _safeErrorMessage(widget.event);

    return Container(
      key: const Key('view_image_error'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: errorColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 16, color: errorColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Image Inspection Failed',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: errorColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            key: const Key('view_image_error_message'),
            style: GoogleFonts.firaCode(
              fontSize: 11,
              color: errorColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaContent(BuildContext context, ViewImageMedia media) {
    final load = _load;
    if (load == null) return const UnavailableViewImage();

    return FutureBuilder<Uint8List>(
      future: load.bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const UnavailableViewImage();
        final bytes = snapshot.data;
        if (bytes == null) {
          return const SizedBox(
            key: Key('view_image_loading'),
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Semantics(
          button: true,
          label: 'Open View Image preview',
          child: InkWell(
            key: const Key('view_image_thumbnail'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _showLightbox(context, bytes),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: widget.minWidth ?? 0,
                minHeight: 120,
                maxHeight: 280,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: media.width / media.height,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    semanticLabel: 'View Image thumbnail',
                    errorBuilder: (_, _, _) => const UnavailableViewImage(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showLightbox(BuildContext context, Uint8List bytes) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        key: const Key('view_image_lightbox'),
        insetPadding: const EdgeInsets.all(24),
        child: Stack(
          children: [
            Semantics(
              label: 'View Image full-size preview',
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    semanticLabel: 'View Image full-size preview',
                  ),
                ),
              ),
            ),
            PositionedDirectional(
              top: 8,
              end: 8,
              child: IconButton(
                key: const Key('view_image_lightbox_close'),
                tooltip: 'Close image preview',
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _safeErrorMessage(CanonicalEvent event) {
    if (event.text.trim().isNotEmpty) {
      final trimmed = event.text.trim();
      if (!_looksLikePayload(trimmed)) {
        return trimmed;
      }
    }
    final toolResult = event.tool?['toolResult'];
    if (toolResult is Map && toolResult['blocks'] is List) {
      final blocks = toolResult['blocks'] as List;
      final textParts = <String>[];
      for (final b in blocks) {
        if (b is Map && b['type'] == 'text' && b['text'] != null) {
          final t = b['text'].toString().trim();
          if (t.isNotEmpty && !_looksLikePayload(t)) textParts.add(t);
        }
      }
      if (textParts.isNotEmpty) return textParts.join('\n');
    }
    final output = event.toolOutput;
    if (output is String && output.trim().isNotEmpty) {
      final trimmed = output.trim();
      if (!_looksLikePayload(trimmed)) {
        return trimmed;
      }
    }
    return 'Image inspection failed.';
  }

  static bool _looksLikePayload(String text) {
    return text.startsWith('{') || text.startsWith('[') || text.startsWith('data:image') || text.startsWith('base64');
  }
}

class UnavailableViewImage extends StatelessWidget {
  const UnavailableViewImage({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('view_image_unavailable'),
    constraints: const BoxConstraints(minHeight: 96),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Semantics(
      label: 'View Image unavailable',
      child: const Text('Image unavailable'),
    ),
  );
}
