import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The committed dictation fixtures are driver acceptance inputs, not code.
///
/// Every leg used to synthesise its own PCM, so no two runs used the same audio
/// and none could be compared. These two files are the shared inputs; this test
/// keeps them honest about the shape the seam accepts: raw PCM16LE, 16 kHz mono,
/// even length, and small enough to commit.
void main() {
  const fixtureDir = 'test/fixtures/dictation';
  const maxBytes = 200 * 1024;

  final fixtures = <String, int>{
    // English phrase for a streaming leg (text while speaking).
    'en_streaming_quick_brown_fox.pcm': 1500,
    // Arabic phrase for a batch leg (text on stop).
    'ar_batch_dictation_check.pcm': 3000,
  };

  for (final entry in fixtures.entries) {
    test('${entry.key} is a bounded 16 kHz mono PCM16LE clip', () {
      final file = File('$fixtureDir/${entry.key}');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'the seam documents this fixture; it must be committed',
      );

      final bytes = file.readAsBytesSync();
      expect(
        bytes.length,
        lessThan(maxBytes),
        reason: 'fixtures stay small enough to live in the repository',
      );
      expect(bytes.length.isEven, isTrue, reason: 'PCM16LE is two bytes a frame');
      // 16 kHz mono PCM16LE is 32 000 bytes per second.
      final seconds = bytes.length / 32000;
      expect(seconds, greaterThan(entry.value / 1000));
      expect(seconds, lessThan(6.25), reason: 'a leg is a short utterance');

      // Not digital silence: a fixture of zeros proves nothing about decoding.
      final samples = Int16List.sublistView(bytes);
      final peak = samples.fold<int>(0, (max, s) => s.abs() > max ? s.abs() : max);
      expect(peak, greaterThan(1000));
    });
  }
}
