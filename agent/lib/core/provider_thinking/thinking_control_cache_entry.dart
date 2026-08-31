/// Cached thinking-control entry with model-cache evidence metadata.
library;

import 'thinking_control_models.dart';

class ThinkingControlCacheEntry {
  final ThinkingControlDescriptor descriptor;
  final DateTime? fetchedAt;
  final String cacheSource;

  const ThinkingControlCacheEntry({
    required this.descriptor,
    this.fetchedAt,
    this.cacheSource = 'live',
  });
}
