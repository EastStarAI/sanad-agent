/// Pinned local dictation model catalog.
///
/// This file is the only place a model is described. Adding a model, a family,
/// or a language is a data change here plus (at most) a new engine adapter —
/// never a transport or UI change.
library;

import 'stt_types.dart';

/// Silero VAD model shared by every batch entry. Downloaded once into
/// `Sanad Home/models/stt/_shared/`.
const SttModelFile kSileroVadFile = SttModelFile(
  name: 'silero_vad.onnx',
  url:
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
  sizeBytes: 643854,
  sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
);

/// The two v1 entries. Both are whisper-family batch models because no
/// streaming model supports Arabic yet; the contract already carries
/// [SttModelMode.streaming] for the day one does.
const List<SttCatalogEntry> kSttCatalog = [
  SttCatalogEntry(
    id: 'egy-whisper-turbo-int8',
    label: 'Egyptian Whisper Turbo (int8)',
    note: 'أعلى دقة للعربية والمصري — يحتاج جهازًا قادرًا',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: true,
    hosted: true,
    files: [
      SttModelFile(
        name: 'egy-whisper-turbo-encoder.int8.onnx',
        url:
            'https://huggingface.co/AhmedAttia3/sanad-egy-whisper-turbo-int8/resolve/main/egy-whisper-turbo-encoder.int8.onnx',
        sizeBytes: 674622359,
        sha256: 'c8b1106104ad7838ed6357187ecc1e95e6d1198645c9b398b246b345015951b1',
      ),
      SttModelFile(
        name: 'egy-whisper-turbo-decoder.int8.onnx',
        url:
            'https://huggingface.co/AhmedAttia3/sanad-egy-whisper-turbo-int8/resolve/main/egy-whisper-turbo-decoder.int8.onnx',
        sizeBytes: 361070805,
        sha256: 'e6c339082ff82180051032e8714eeeaa66e4e313f2ec3a2c3ffb2919d8810aa7',
      ),
      SttModelFile(
        name: 'egy-whisper-turbo-tokens.txt',
        url:
            'https://huggingface.co/AhmedAttia3/sanad-egy-whisper-turbo-int8/resolve/main/egy-whisper-turbo-tokens.txt',
        sizeBytes: 816730,
        sha256: 'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126',
      ),
    ],
  ),
  SttCatalogEntry(
    id: 'whisper-turbo-ggml-q5',
    label: 'Whisper Turbo (ggml q5_0)',
    note: 'نفس الجودة بذاكرة أقل — محرك whisper.cpp',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: false,
    engine: SttEngineKind.whisperCpp,
    files: [
      SttModelFile(
        name: 'ggml-large-v3-turbo-q5_0.bin',
        url:
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
        sizeBytes: 574122867,
        sha256:
            '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
      ),
    ],
  ),
  SttCatalogEntry(
    id: 'whisper-base-int8',
    label: 'Whisper Base (int8)',
    note: 'أسرع وأخف للأجهزة الضعيفة — دقة عربية أقل',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: false,
    files: [
      SttModelFile(
        name: 'base-encoder.int8.onnx',
        url:
            'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/main/base-encoder.int8.onnx',
        sizeBytes: 29120534,
        sha256:
            '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
      ),
      SttModelFile(
        name: 'base-decoder.int8.onnx',
        url:
            'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/main/base-decoder.int8.onnx',
        sizeBytes: 130672026,
        sha256:
            '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
      ),
      SttModelFile(
        name: 'base-tokens.txt',
        url:
            'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/main/base-tokens.txt',
        sizeBytes: 816730,
        sha256:
            'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126',
      ),
    ],
  ),
];

/// The default entry: the first `isDefault`, else the first entry.
SttCatalogEntry get defaultSttEntry => kSttCatalog.firstWhere(
  (entry) => entry.isDefault,
  orElse: () => kSttCatalog.first,
);

SttCatalogEntry? sttEntryById(String id) {
  for (final entry in kSttCatalog) {
    if (entry.id == id) return entry;
  }
  return null;
}
