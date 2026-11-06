/// Speech gate for the whisper.cpp path.
///
/// The sherpa/ONNX engines normalise features inside the model, so their
/// transcript never depended on how loud the microphone happened to be. The
/// whisper path has no such step: `whisper.cpp` decodes the samples it is given
/// as-is. An earlier gate here compared the *absolute* amplitude against a fixed
/// floor, which made a perfectly ordinary sentence fail whenever the input was a
/// few dB quieter — the "No Speech Detected" regression.
///
/// The decision below is deliberately scale-invariant:
///
/// * [minPeak] is the only absolute number, and it is small enough to mean
///   "the microphone delivered almost nothing", not "you spoke softly".
/// * [minCrest] compares peak to RMS, a ratio that stays the same whether the
///   signal arrives at 0.05 or 0.5: speech is peaky (measured 6.8–10.6 on real
///   Egyptian sessions), steady noise is not (≈2–3), and digital silence has no
///   peak at all.
library;

/// Amplitude under which the capture is treated as muted rather than quiet.
const double kSpeechMinPeak = 0.004;

/// Peak-to-RMS ratio a session needs before it is worth decoding.
const double kSpeechMinCrest = 3.5;

/// Peak the utterance is scaled to before decoding.
const double kDecodePeak = 0.85;

/// Upper bound on the normalisation gain, so a nearly silent buffer is not
/// amplified into noise that the decoder would hallucinate over.
const double kDecodeMaxGain = 30;

/// Outcome of the gate: whether to decode, plus the numbers that decided it so a
/// rejected session can log its own measurement.
class SpeechGate {
  const SpeechGate({
    required this.decode,
    required this.peak,
    required this.rms,
    required this.crest,
  });

  /// True when the buffer should be decoded.
  final bool decode;
  final double peak;
  final double rms;

  /// Peak divided by RMS; 0 when the buffer is silent.
  final double crest;

  /// Reason for a rejection, for logs only.
  String get reason {
    if (decode) return 'ok';
    if (peak < kSpeechMinPeak) return 'muted';
    if (crest < kSpeechMinCrest) return 'no_crest';
    return 'unknown';
  }
}

/// Decides whether a buffered utterance contains speech to decode.
SpeechGate evaluateSpeechGate({required double peak, required double rms}) {
  final crest = rms <= 1e-9 ? 0.0 : peak / rms;
  final decode = peak >= kSpeechMinPeak && crest >= kSpeechMinCrest;
  return SpeechGate(decode: decode, peak: peak, rms: rms, crest: crest);
}

/// Gain that brings [peak] to [kDecodePeak], capped at [kDecodeMaxGain].
double decodeGain(double peak) {
  if (peak <= 0) return 1;
  return peak >= kDecodePeak
      ? kDecodePeak / peak
      : (kDecodePeak / peak).clamp(1.0, kDecodeMaxGain);
}
