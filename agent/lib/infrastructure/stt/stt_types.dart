/// Local dictation (STT) types shared by the daemon's dictation runtime.
///
/// Ownership: `agent/lib/infrastructure/stt/`. Nothing here may import Flutter;
/// the recognizer is an in-process native binding, never a sidecar.
library;

import 'package:sanad_stt_sherpa/sanad_stt_sherpa.dart' show sherpaEngineAvailable;

/// How a catalog model turns audio into text.
enum SttModelMode {
  /// Batch recognizer driven by a VAD: one final transcript per speech segment.
  batchVad,

  /// Native streaming recognizer: partial transcripts while the user speaks.
  streaming,
}

/// One downloadable artifact of a catalog model.
class SttModelFile {
  const SttModelFile({
    required this.name,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });

  final String name;
  final String url;
  final int sizeBytes;
  final String sha256;
}

/// A pinned, data-only model entry. Adding a model never requires new code.
/// Which in-process runtime decodes a catalog entry.
///
/// Both run inside the daemon (no sidecar, no CLI, no local HTTP): the sherpa
/// path copies ONNX weights into RAM and keeps one arena per thread, while the
/// whisper.cpp path mmaps ggml weights and peaks far lower — the difference
/// matters on low-resource machines.
enum SttEngineKind {
  /// sherpa-onnx: ONNX encoder/decoder pair plus the silero VAD.
  sherpa,

  /// whisper.cpp through dart:ffi: one ggml file, mmap'd.
  whisperCpp,
}

/// Which in-process engines **this build** can actually run.
///
/// The sherpa engine is a swappable package: lanes that cannot resolve
/// `sherpa_onnx` (it requires the Flutter SDK) link a stand-in instead, and the
/// resulting Agent is a complete build with less capability, not a broken one.
/// Model selection, the model rows, and readiness all ask this object, so no
/// other file tests the platform or the build mode.
///
/// Streaming and VAD are sherpa-only today: the whisper.cpp path has no online
/// recognizer and no silero VAD, so a build without sherpa is batch-only.
class SttEngineAvailability {
  const SttEngineAvailability({bool? sherpa, bool? whisperCpp})
    : sherpa = sherpa ?? sherpaEngineAvailable,
      whisperCpp = whisperCpp ?? true;

  /// The engines this build was compiled with.
  const SttEngineAvailability.build()
    : sherpa = sherpaEngineAvailable,
      whisperCpp = true;

  final bool sherpa;
  final bool whisperCpp;

  /// True when a catalog entry's engine exists in this build.
  bool supports(SttEngineKind kind) => switch (kind) {
    SttEngineKind.sherpa => sherpa,
    SttEngineKind.whisperCpp => whisperCpp,
  };

  /// True when partial transcripts and VAD-driven segmentation exist.
  ///
  /// Both are sherpa features, so this is exactly [sherpa]: a build without it
  /// publishes finals only, and the Client already renders that.
  bool get streaming => sherpa;

  @override
  String toString() =>
      'SttEngineAvailability(sherpa=$sherpa, whisperCpp=$whisperCpp)';
}

class SttCatalogEntry {
  const SttCatalogEntry({
    required this.id,
    required this.label,
    required this.note,
    required this.mode,
    required this.files,
    this.language = 'ar',
    this.isDefault = false,
    this.hosted = true,
    this.engine = SttEngineKind.sherpa,
    this.hidden = false,
    this.streamingModelType = 'zipformer2',
  });

  final String id;
  final String label;
  final String note;
  final SttModelMode mode;
  final List<SttModelFile> files;
  final String language;
  final bool isDefault;

  /// False while the artifacts have no pinned public URL yet; such an entry is
  /// usable only through the `stt.model_path` override.
  final bool hosted;

  /// Which in-process runtime decodes this entry.
  ///
  /// The daemon keeps both behind one [SttEngine] contract, so switching an
  /// entry between engines is a catalog change, never a transport or UI one.
  final SttEngineKind engine;

  /// sherpa's `modelType` for a streaming entry.
  ///
  /// It is part of the model, not of our code: exports from 2023-06-26 onward
  /// are `zipformer2` and carry different metadata keys, and asking sherpa to
  /// parse them as `zipformer` fails with "'attention_dims' does not exist in
  /// the metadata" — the exact error that made G5 fall back to a weak model.
  final String streamingModelType;

  /// Hidden entries stay usable through `stt.model_id` but never appear in the
  /// model sheet, so the user only sees the models we actually recommend.
  final bool hidden;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.sizeBytes);
}

/// Why dictation is or is not usable on this device.
class SttReadiness {
  const SttReadiness.ready()
    : isSupported = true,
      isReady = true,
      reason = null;

  /// [isSupported] answers "may this device dictate at all?" (platform, config,
  /// settings). [isReady] answers "can it start right now?". They differ while
  /// the native runtime is still being downloaded or built: the mic must stay
  /// visible so the user sees progress instead of losing the button.
  const SttReadiness.unavailable(this.reason, {this.isSupported = false})
    : isReady = false;

  final bool isSupported;
  final bool isReady;
  final String? reason;
}

/// Typed dictation failures. Codes are stable; messages never contain audio or
/// transcript text.
class SttException implements Exception {
  const SttException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'SttException($code): $message';
}

/// Events published by an engine session.
sealed class SttEvent {
  const SttEvent();
}

/// Recognizer is loaded and able to accept audio.
class SttReadyEvent extends SttEvent {
  const SttReadyEvent({required this.loadMs, required this.modelId});
  final int loadMs;
  final String modelId;
}

/// Mutable transcript of the still-open segment. Batch engines never emit this.
class SttPartialEvent extends SttEvent {
  const SttPartialEvent({required this.seq, required this.text});
  final int seq;
  final String text;
}

/// Terminal transcript of one segment. Published once per [seq].
class SttFinalEvent extends SttEvent {
  const SttFinalEvent({
    required this.seq,
    required this.text,
    required this.audioMs,
    required this.decodeMs,
  });

  final int seq;
  final String text;
  final int audioMs;
  final int decodeMs;
}

/// The session drained to completion; no further transcript events follow.
class SttDoneEvent extends SttEvent {
  const SttDoneEvent({required this.droppedChunks});
  final int droppedChunks;
}

/// Typed failure; the session is unusable afterwards.
class SttErrorEvent extends SttEvent {
  const SttErrorEvent(this.error);
  final SttException error;
}
