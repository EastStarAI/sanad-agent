import 'package:sanad_agent/infrastructure/stt/stt_decode_params.dart';
import 'package:test/test.dart';

/// The encoder window is a measured parameter, not a formula to tidy: a bare
/// proportional window produced deterministic phrase loops on short Arabic
/// clips, so the floor and the ceiling are part of the contract.
void main() {
  /// A group length including the daemon's half-second tail pad, which is what
  /// `_transcribeAll` passes.
  int padded(double seconds) => (seconds * 16000).round() + 8000;

  group('audioCtxForSamples', () {
    test('short utterances get the measured floor', () {
      // The clips that looped with the bare formula: 1.81 s … 3.87 s, plus the
      // 4.87 s product fixture and an 8 s sentence that lands on the floor by
      // arithmetic.
      for (final seconds in [0.4, 1.81, 2.5, 3.01, 3.47, 4.87, 5.37, 8.0]) {
        expect(
          audioCtxForSamples(padded(seconds)),
          kWhisperAudioCtxFloor,
          reason: '$seconds s must not use a window below the floor',
        );
      }
    });

    test('the floor is 448 frames of a 9 s window', () {
      expect(kWhisperAudioCtxFloor, 448);
      // One frame is 10 ms of audio, so the smallest window still spans ~8.96 s.
      expect(kWhisperAudioCtxFloor * kWhisperSamplesPerFrame, 143360);
    });

    test('a 26.8 s group is proportional and 32-frame aligned', () {
      expect(audioCtxForSamples(padded(26.8)), 1376);
    });

    test('a group above the model window is capped', () {
      expect(audioCtxForSamples(5 * 60 * 16000), kWhisperAudioCtxCeiling);
      expect(
        audioCtxForSamples(5 * 60 * 16000, modelAudioCtx: 800),
        800,
        reason: 'the loaded model is the real ceiling',
      );
    });

    test('a model smaller than the floor is respected, not overflowed', () {
      expect(audioCtxForSamples(padded(3), modelAudioCtx: 256), 256);
      expect(audioCtxForSamples(padded(30), modelAudioCtx: 256), 256);
    });

    test('an unknown model window falls back to the checkpoint default', () {
      expect(
        audioCtxForSamples(padded(30), modelAudioCtx: 0),
        kWhisperAudioCtxCeiling,
      );
    });

    test('no input ever yields 0 or more than the model window', () {
      // 0 is whisper's own default window and is reserved for the guard retry.
      for (var samples = 0; samples <= 5 * 60 * 16000; samples += 5003) {
        final window = audioCtxForSamples(samples);
        expect(window, greaterThan(0), reason: '$samples samples');
        expect(
          window,
          lessThanOrEqualTo(kWhisperAudioCtxCeiling),
          reason: '$samples samples',
        );
        if (window != kWhisperAudioCtxCeiling) {
          // The ceiling is the model's own value, not a computed one, so it is
          // the one window that does not have to be aligned.
          expect(
            window % kWhisperAudioCtxStep,
            0,
            reason: '$samples samples produced an unaligned window',
          );
        }
      }
    });

    test('the window never shrinks as the utterance grows', () {
      var previous = 0;
      for (var samples = 1; samples <= 5 * 60 * 16000; samples += 997) {
        final window = audioCtxForSamples(samples);
        expect(
          window,
          greaterThanOrEqualTo(previous),
          reason: '$samples samples shrank the window',
        );
        previous = window;
      }
    });
  });
}
