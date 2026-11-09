import 'package:flutter/rendering.dart';

/// Global logical bounds of [renderObject] for the inspection projection.
///
/// Returns null when the render object has no size, has been detached, or
/// cannot be transformed into the root coordinate space, so an inspected row
/// never carries fabricated geometry. Snapshot, reveal, and obstruction
/// reporting share this shape so bounds mean the same thing everywhere.
Map<String, dynamic>? globalBoundsOf(RenderObject? renderObject) {
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  try {
    final translation = renderObject.getTransformTo(null).getTranslation();
    final size = renderObject.size;
    return {
      'x': translation.x.round(),
      'y': translation.y.round(),
      'width': size.width.round(),
      'height': size.height.round(),
    };
  } catch (_) {
    return null;
  }
}
