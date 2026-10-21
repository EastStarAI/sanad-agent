import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/media/image_lightbox.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/view_image_tool_card.dart';

/// Responsive gallery that lays out consecutive runs of media-bearing tool
/// events (e.g. `view_image` and `system_screenshot` with media) using Wrap + LayoutBuilder.
///
/// Uses the pinned responsive formula:
/// columns = ((availableWidth + spacing) / (minItem + spacing)).floor().clamp(1, 4)
/// itemWidth = (availableWidth - spacing * (columns - 1)) / columns
/// where minItem = 160 and spacing = 8.
///
/// The gallery owns one [LightboxGroup] so opening any card's lightbox
/// navigates the whole run in display order.
class ResponsiveMediaGallery extends StatefulWidget {
  const ResponsiveMediaGallery({
    super.key,
    required this.events,
    this.viewImageMediaLoader,
    this.padding = const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
  });

  final List<CanonicalEvent> events;
  final ViewImageMediaLoader? viewImageMediaLoader;
  final EdgeInsetsGeometry padding;

  static const double minItem = 160.0;
  static const double spacing = 8.0;

  /// Whether [event] joins a gallery run: a tool row that renders through the
  /// shared image media card (see [ViewImageMediaEvent.rendersAsMediaCard]).
  static bool isMediaToolEvent(CanonicalEvent event) => event.kind == EventKind.toolCall && event.rendersAsMediaCard;

  /// Calculates column count based on available width.
  static int calculateColumns(double availableWidth) {
    if (availableWidth <= 0) return 1;
    return ((availableWidth + spacing) / (minItem + spacing)).floor().clamp(1, 4);
  }

  /// Calculates width of each item based on available width and column count.
  static double calculateItemWidth(double availableWidth, int columns) {
    if (availableWidth <= 0 || columns <= 0) return 0;
    final width = (availableWidth - spacing * (columns - 1)) / columns;
    return width > 0 ? width : 0;
  }

  @override
  State<ResponsiveMediaGallery> createState() => _ResponsiveMediaGalleryState();
}

class _ResponsiveMediaGalleryState extends State<ResponsiveMediaGallery> {
  final LightboxGroup _lightboxGroup = LightboxGroup();

  @override
  void initState() {
    super.initState();
    _lightboxGroup.setOrder([for (final event in widget.events) event.id]);
  }

  @override
  void didUpdateWidget(covariant ResponsiveMediaGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lightboxGroup.setOrder([for (final event in widget.events) event.id]);
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    if (events.isEmpty) return const SizedBox.shrink();
    const spacing = ResponsiveMediaGallery.spacing;

    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
          final columns = ResponsiveMediaGallery.calculateColumns(availableWidth);
          final itemWidth = ResponsiveMediaGallery.calculateItemWidth(availableWidth, columns);
          // Guard against floating point epsilon causing premature wrap
          final childWidth = columns > 1 ? (itemWidth - 0.001).clamp(0.0, availableWidth) : itemWidth;

          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final event in events)
                SizedBox(
                  key: ValueKey('tool-group-child:${event.id}'),
                  width: childWidth,
                  child: ViewImageToolCard(
                    event: event,
                    loader: widget.viewImageMediaLoader,
                    minWidth: 0,
                    lightboxGroup: _lightboxGroup,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
