/// Pre-session microphone buffering for one dictation connection.
///
/// It lives in its own file because it is a pure data structure: the dictation
/// connection owns the session, the lease, and the engine, and this only keeps
/// the frames that arrived while the recognizer was still loading.
library;

import 'dart:typed_data';

/// Bounded FIFO for microphone frames captured before a session exists.
class DictationAudioBuffer {
  DictationAudioBuffer({this.maxBytes = 4 * 1024 * 1024});

  /// 4 MiB is ≈2 minutes of 16 kHz mono PCM16; beyond that the buffer would
  /// cost more than the words it protects.
  final int maxBytes;

  final List<Uint8List> _chunks = [];
  int _bytes = 0;
  int _droppedBytes = 0;

  int get bufferedBytes => _bytes;
  int get bufferedChunks => _chunks.length;
  int get droppedBytes => _droppedBytes;

  /// Returns false when the frame did not fit and was dropped instead.
  bool add(Uint8List chunk) {
    if (chunk.isEmpty) return true;
    if (_bytes + chunk.length > maxBytes) {
      _droppedBytes += chunk.length;
      return false;
    }
    _chunks.add(chunk);
    _bytes += chunk.length;
    return true;
  }

  /// Removes and returns everything buffered, in arrival order.
  List<Uint8List> drain() {
    final drained = List<Uint8List>.of(_chunks);
    _chunks.clear();
    _bytes = 0;
    return drained;
  }
}
