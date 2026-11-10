/// Decode-window geometry for the local `whisper.cpp` engine.
///
/// whisper's encoder used to run with the full default window for every
/// utterance, so a 5 s dictation paid the same encoder pass on the reference
/// aarch64 host as a 30 s one (12.4 s of a 12.5 s decode). The window is now
/// proportional to the buffered audio, with a measured floor and the model's own
/// ceiling.
library;

import 'dart:math' as math;

/// Samples per mel frame: whisper's 16 kHz hop is 10 ms.
const int kWhisperSamplesPerFrame = 320;

/// Smallest encoder window, in mel frames (448 frames = 8.96 s of audio).
///
/// Measured, not derived. With a bare proportional window, whisper decoded 5 of
/// 8 short Arabic clips (1.8–3.9 s) into deterministic phrase loops — the 3 s
/// clip came back as 42 words of `تماما خلاص كدا` instead of 3. The mechanism is
/// trailing silence: the audio path guarantees only 0.5 s after the last
/// phoneme, and a window that ends within ~1 s of it leaves the decoder no room
/// to close a segment. In a 60-run sweep (6 clips × windows 320–768) every loop
/// sat at 2.5–4.5 s of window and every run at or above 448 frames was clean.
/// 448 is also where the proportional value lands for an 8 s utterance, so the
/// floor introduces no discontinuity.
///
/// Do not lower it without repeating that sweep, and do not delete it: the bare
/// formula is ~0.5 s faster on the reference host and wrong on most short
/// dictations.
const int kWhisperAudioCtxFloor = 448;

/// Alignment of a computed window, in mel frames.
///
/// The measured sweep grid used 32-frame steps, and an aligned window keeps the
/// encoder's 2× downsampling on an even token count.
const int kWhisperAudioCtxStep = 32;

/// Full 30 s window of the shipped checkpoints.
///
/// Used as the ceiling when the loaded model does not report its own
/// (`whisper_n_audio_ctx`), and the value whisper itself defaults to.
const int kWhisperAudioCtxCeiling = 1500;

/// Encoder window, in mel frames, for one group of [samples] samples.
///
/// [samples] includes the trailing silence pad, because the window is meant to
/// extend past the last speech sample. The result is always between
/// [kWhisperAudioCtxFloor] and [modelAudioCtx], so this function never returns
/// 0: 0 means whisper's own default window and is reserved for the repetition
/// guard's retry.
int audioCtxForSamples(
  int samples, {
  int modelAudioCtx = kWhisperAudioCtxCeiling,
}) {
  final ceiling = modelAudioCtx > 0 ? modelAudioCtx : kWhisperAudioCtxCeiling;
  final floor = math.min(kWhisperAudioCtxFloor, ceiling);
  if (samples <= 0) return floor;
  final frames =
      (samples + kWhisperSamplesPerFrame - 1) ~/ kWhisperSamplesPerFrame;
  final aligned =
      ((frames + kWhisperAudioCtxStep - 1) ~/ kWhisperAudioCtxStep) *
      kWhisperAudioCtxStep;
  if (aligned < floor) return floor;
  if (aligned > ceiling) return ceiling;
  return aligned;
}
