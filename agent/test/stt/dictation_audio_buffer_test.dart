import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:test/test.dart';

Uint8List frame(int bytes, [int fill = 1]) =>
    Uint8List.fromList(List<int>.filled(bytes, fill));

void main() {
  group('dictation pre-session audio buffer', () {
    test('keeps frames in arrival order and drains once', () {
      final buffer = DictationAudioBuffer(maxBytes: 64);
      expect(buffer.add(frame(16, 1)), isTrue);
      expect(buffer.add(frame(16, 2)), isTrue);
      expect(buffer.bufferedChunks, 2);
      expect(buffer.bufferedBytes, 32);

      final drained = buffer.drain();
      expect(drained, hasLength(2));
      expect(drained.first.first, 1);
      expect(drained.last.first, 2);
      expect(buffer.bufferedChunks, 0);
      expect(buffer.bufferedBytes, 0);
      expect(buffer.drain(), isEmpty);
    });

    test('drops frames beyond the cap and counts dropped bytes', () {
      final buffer = DictationAudioBuffer(maxBytes: 32);
      expect(buffer.add(frame(16)), isTrue);
      expect(buffer.add(frame(32)), isFalse);
      expect(buffer.droppedBytes, 32);
      expect(buffer.bufferedBytes, 16);
    });

    test('ignores empty frames without recording a drop', () {
      final buffer = DictationAudioBuffer(maxBytes: 32);
      expect(buffer.add(frame(0)), isTrue);
      expect(buffer.bufferedChunks, 0);
      expect(buffer.droppedBytes, 0);
    });
  });
}
