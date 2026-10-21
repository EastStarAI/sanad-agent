import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sanad_client/features/conversations/data/media/image_download_saver.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';

/// One image shown by [ImageLightbox]. [bytes] is the owning card's existing
/// load (local repository, media relay, or cloud device), never a new fetch.
final class LightboxImage {
  const LightboxImage({
    required this.bytes,
    required this.semanticLabel,
    this.cachedBytes,
    this.preferredFileName,
  });

  final Future<Uint8List> bytes;

  /// Bytes already available synchronously (a cache hit or a resolved load).
  final Uint8List? cachedBytes;
  final String semanticLabel;

  /// Download name hint (an attachment's safe name); `null` uses
  /// `image-<timestamp>`.
  final String? preferredFileName;
}

/// Ordered registry of the images of one gallery or attachment grid.
///
/// The owning group widget sets the display order; each card registers the
/// load it already owns and unregisters it when the load is replaced or the
/// card is disposed. Opening the lightbox snapshots the registered images.
final class LightboxGroup {
  List<String> _order = const [];
  final Map<String, LightboxImage> _images = {};

  void setOrder(List<String> ids) => _order = List.unmodifiable(ids);

  void register(String id, LightboxImage image) => _images[id] = image;

  bool contains(String id) => _images.containsKey(id);

  /// Removes [id] only while it still maps to [image], so a newer
  /// registration for the same id survives a late unregister.
  void unregister(String id, LightboxImage image) {
    if (identical(_images[id], image)) _images.remove(id);
  }

  /// The registered images in display order and the index of [id].
  ({List<LightboxImage> images, int index}) snapshot(String id) {
    final images = <LightboxImage>[];
    var index = 0;
    for (final candidate in _order) {
      final image = _images[candidate];
      if (image == null) continue;
      if (candidate == id) index = images.length;
      images.add(image);
    }
    return (images: images, index: index);
  }
}

/// The images to open from the card [id] whose resolved image is [self]:
/// the whole [group] in order (with [self] in its own slot, so the first
/// frame needs no wait), or just [self] outside a group.
({List<LightboxImage> images, int index}) openLightboxGroup(LightboxGroup? group, String id, LightboxImage self) {
  final snapshot = group?.snapshot(id);
  if (snapshot == null || snapshot.images.isEmpty || !group!.contains(id)) return (images: [self], index: 0);
  final images = [...snapshot.images]..[snapshot.index] = self;
  return (images: images, index: snapshot.index);
}

/// Lets tests and hosts replace the platform [ImageDownloadSaver]. Read from
/// the card's context before the dialog opens.
class ImageDownloadSaverScope extends InheritedWidget {
  const ImageDownloadSaverScope({super.key, required this.saver, required super.child});

  /// `null` hides the Download control.
  final ImageDownloadSaver? saver;

  static ImageDownloadSaver? resolve(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ImageDownloadSaverScope>();
    return scope == null ? ImageDownloadSaver.forPlatform() : scope.saver;
  }

  @override
  bool updateShouldNotify(ImageDownloadSaverScope oldWidget) => saver != oldWidget.saver;
}

/// Opens [ImageLightbox] for [images] starting at [initialIndex].
Future<void> showImageLightbox(
  BuildContext context, {
  required List<LightboxImage> images,
  required int initialIndex,
  required Key dialogKey,
  required Key closeKey,
}) {
  final saver = ImageDownloadSaverScope.resolve(context);
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => Dialog(
      key: dialogKey,
      insetPadding: const EdgeInsets.all(24),
      child: ImageLightbox(
        images: images,
        initialIndex: initialIndex,
        saver: saver,
        closeKey: closeKey,
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    ),
  );
}

/// Full-size image viewer with group navigation and download.
///
/// Navigation stops at the ends (no wrap). Previous/next follow reading
/// direction: in LTR previous is on the left and next on the right; in RTL
/// next is on the left. Arrow keys map to the arrow on the same physical side.
class ImageLightbox extends StatefulWidget {
  const ImageLightbox({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.onClose,
    required this.closeKey,
    this.saver,
  });

  static const previousKey = Key('lightbox_prev');
  static const nextKey = Key('lightbox_next');
  static const downloadKey = Key('lightbox_download');
  static const counterKey = Key('lightbox_counter');
  static const messageKey = Key('lightbox_download_message');
  static const unavailableKey = Key('lightbox_image_unavailable');

  final List<LightboxImage> images;
  final int initialIndex;
  final VoidCallback onClose;
  final Key closeKey;
  final ImageDownloadSaver? saver;

  @override
  State<ImageLightbox> createState() => _ImageLightboxState();
}

class _ImageLightboxState extends State<ImageLightbox> {
  late int _index = widget.initialIndex.clamp(0, widget.images.length - 1);
  final Map<int, Uint8List> _resolved = {};
  final Set<int> _failed = {};
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.images.length; i++) {
      final image = widget.images[i];
      final cached = image.cachedBytes;
      if (cached != null) {
        _resolved[i] = cached;
        continue;
      }
      unawaited(image.bytes.then(
        (bytes) {
          if (mounted) setState(() => _resolved[i] = bytes);
        },
        onError: (Object _) {
          if (mounted) setState(() => _failed.add(i));
        },
      ));
    }
  }

  bool get _hasGroup => widget.images.length > 1;
  bool get _canGoPrevious => _index > 0;
  bool get _canGoNext => _index < widget.images.length - 1;

  void _goTo(int index) {
    if (index < 0 || index >= widget.images.length || index == _index) return;
    setState(() {
      _index = index;
      _message = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goTo(rtl ? _index + 1 : _index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goTo(rtl ? _index - 1 : _index + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _download(AppLocalizations l10n) async {
    final saver = widget.saver;
    final bytes = _resolved[_index];
    if (saver == null || bytes == null || _saving) return;
    final index = _index;
    setState(() {
      _saving = true;
      _message = null;
    });
    String message;
    try {
      final result = await saver.save(bytes: bytes, preferredName: widget.images[index].preferredFileName);
      message = result.outcome == ImageDownloadOutcome.saved
          ? l10n.lightboxDownloadSaved(result.fileName)
          : l10n.lightboxDownloadStarted(result.fileName);
    } catch (_) {
      message = l10n.lightboxDownloadFailed;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (_index == index) _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final image = widget.images[_index];
    final bytes = _resolved[_index];

    final Widget content;
    if (bytes != null) {
      content = InteractiveViewer(
        key: ValueKey('lightbox_viewer_$_index'),
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: image.semanticLabel,
          ),
        ),
      );
    } else if (_failed.contains(_index)) {
      content = Center(key: ImageLightbox.unavailableKey, child: Text(l10n.lightboxImageUnavailable));
    } else {
      content = const Center(child: CircularProgressIndicator());
    }

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          Positioned.fill(child: Semantics(label: image.semanticLabel, child: content)),
          if (_hasGroup) ...[
            PositionedDirectional(
              start: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filledTonal(
                  key: ImageLightbox.previousKey,
                  tooltip: l10n.lightboxPreviousImage,
                  onPressed: _canGoPrevious ? () => _goTo(_index - 1) : null,
                  icon: Icon(rtl ? Icons.chevron_right : Icons.chevron_left),
                ),
              ),
            ),
            PositionedDirectional(
              end: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filledTonal(
                  key: ImageLightbox.nextKey,
                  tooltip: l10n.lightboxNextImage,
                  onPressed: _canGoNext ? () => _goTo(_index + 1) : null,
                  icon: Icon(rtl ? Icons.chevron_left : Icons.chevron_right),
                ),
              ),
            ),
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: _Pill(
                  child: Text(
                    l10n.lightboxCounter(_index + 1, widget.images.length),
                    key: ImageLightbox.counterKey,
                  ),
                ),
              ),
            ),
          ],
          PositionedDirectional(
            top: 8,
            end: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.saver != null)
                  IconButton(
                    key: ImageLightbox.downloadKey,
                    tooltip: l10n.lightboxDownload,
                    onPressed: bytes != null && !_saving ? () => unawaited(_download(l10n)) : null,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download_rounded),
                  ),
                IconButton(
                  key: widget.closeKey,
                  tooltip: l10n.lightboxClose,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (_message != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Center(
                child: _Pill(
                  child: Text(
                    _message!,
                    key: ImageLightbox.messageKey,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: scheme.onSurface, fontSize: 13),
          child: child,
        ),
      ),
    );
  }
}
