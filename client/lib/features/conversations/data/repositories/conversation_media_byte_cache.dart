import 'dart:collection';
import 'dart:typed_data';

import 'package:sanad_client/core/config/app_config.dart';

/// Process-wide, byte-bounded LRU of conversation media bytes.
///
/// Thumbnails, galleries, the lightbox, and image download share this cache
/// so revisiting an image reuses the same bytes (and the same `Uint8List`
/// instance, which keeps the decoded `MemoryImage` hot) instead of fetching
/// again. Keys are built only through [keyFor], which always carries the
/// transport and device identity, so media from two devices never mix. The
/// cache is in memory only; a Client process is bound to one Sanad Home.
final class ConversationMediaByteCache {
  ConversationMediaByteCache({required this.maximumBytes});

  static final ConversationMediaByteCache shared = ConversationMediaByteCache(
    maximumBytes: AppConfig.conversationMediaCacheMegabytes * 1024 * 1024,
  );

  final int maximumBytes;
  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  int _bytes = 0;

  int get length => _entries.length;
  int get bytes => _bytes;

  /// Builds a cache key scoped by transport (`local`/`hosted`), device,
  /// session, media kind, and opaque media id. [sha256] further pins
  /// content-addressed attachments.
  static String keyFor({
    required String transport,
    required String deviceId,
    required String sessionId,
    required String kind,
    required String mediaId,
    String? sha256,
  }) => [transport, deviceId, sessionId, kind, mediaId, sha256 ?? ''].join('\u0000');

  /// Returns the cached bytes for [key] and marks them most recently used.
  Uint8List? get(String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(String key, Uint8List value) {
    if (value.length > maximumBytes) return;
    final replaced = _entries.remove(key);
    if (replaced != null) _bytes -= replaced.length;
    _entries[key] = value;
    _bytes += value.length;
    while (_bytes > maximumBytes && _entries.isNotEmpty) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
