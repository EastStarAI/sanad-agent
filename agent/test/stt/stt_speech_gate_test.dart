import 'package:sanad_agent/infrastructure/stt/stt_speech_gate.dart';
import 'package:test/test.dart';

/// The numbers below are the measurements from real Egyptian sessions on the
/// owner's microphone, including the two that used to fail with "No Speech
/// Detected". They are the regression this gate exists for.
void main() {
  group('speech gate', () {
    test('quiet speech that used to fail is decoded', () {
      // peak 0.047 / rms 0.0069 was rejected by the old absolute threshold.
      final gate = evaluateSpeechGate(peak: 0.0471, rms: 0.0069);
      expect(gate.decode, isTrue, reason: 'crest=${gate.crest}');
      expect(gate.crest, closeTo(6.83, 0.05));
    });

    test('a quieter but peaky take is still decoded', () {
      final gate = evaluateSpeechGate(peak: 0.012, rms: 0.0017);
      expect(gate.decode, isTrue);
    });

    test('digital silence is rejected', () {
      final gate = evaluateSpeechGate(peak: 0, rms: 0);
      expect(gate.decode, isFalse);
      expect(gate.reason, 'muted');
    });

    test('a muted microphone is rejected even with room noise shape', () {
      final gate = evaluateSpeechGate(peak: 0.001, rms: 0.0002);
      expect(gate.decode, isFalse);
      expect(gate.reason, 'muted');
    });

    test('steady fan or hum noise is rejected despite healthy level', () {
      // Loud enough to pass an absolute floor, but not peaky: no speech.
      final gate = evaluateSpeechGate(peak: 0.05, rms: 0.025);
      expect(gate.decode, isFalse);
      expect(gate.reason, 'no_crest');
    });

    test('the decision does not change when the input scales', () {
      final quiet = evaluateSpeechGate(peak: 0.0471, rms: 0.0069);
      final loud = evaluateSpeechGate(peak: 0.471, rms: 0.069);
      expect(quiet.decode, loud.decode);
      expect(quiet.crest, closeTo(loud.crest, 0.01));
    });
  });

  group('decode gain', () {
    test('a quiet take is lifted to the decode peak', () {
      expect(decodeGain(0.0904), closeTo(9.4, 0.1));
    });

    test('a very quiet take is capped so noise is not amplified without end', () {
      expect(decodeGain(0.001), kDecodeMaxGain);
    });

    test('an already loud take is attenuated, not clipped', () {
      expect(decodeGain(0.95), closeTo(0.89, 0.01));
    });

    test('silence has no gain at all', () {
      expect(decodeGain(0), 1);
    });
  });
}
