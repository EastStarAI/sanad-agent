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
    note: 'احتياطي sherpa — يستهلك ٢.٤–٣ جيجابايت من الذاكرة',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: false,
    hosted: true,
    hidden: true,
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
    id: 'egy-whisper-turbo-ggml-q8',
    label: 'المصري — دقة عالية',
    note: 'يستهلك ≈١.٢ جيجابايت من الذاكرة — التوصية الافتراضية',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: true,
    engine: SttEngineKind.whisperCpp,
    files: [
      SttModelFile(
        name: 'ggml-egy-turbo-q8_0.bin',
        url:
            'https://huggingface.co/AhmedAttia3/sanad-egy-whisper-turbo-ggml/resolve/main/ggml-egy-turbo-q8_0.bin',
        sizeBytes: 874208239,
        sha256:
            'a79de98911bbbbb933d5553824cf4507a8ead299f02cdffbf9fe05a80915299a',
      ),
    ],
  ),
  SttCatalogEntry(
    id: 'egy-whisper-turbo-ggml-f16',
    label: 'المصري — أقصى دقة',
    note: 'يستهلك ≈١.٩ جيجابايت من الذاكرة — الأصل بلا تكميم',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: false,
    // Uploaded and verified against the hosted LFS digest (1.62 GB, f16).
    hidden: false,
    engine: SttEngineKind.whisperCpp,
    files: [
      SttModelFile(
        name: 'ggml-egy-turbo-f16.bin',
        url:
            'https://huggingface.co/AhmedAttia3/sanad-egy-whisper-turbo-ggml/resolve/main/ggml-egy-turbo-f16.bin',
        sizeBytes: 1624555275,
        sha256:
            '917a13f15b240a1948f2cddc226e2a197b28efdca67b3b1c53cd1f9a960690a8',
      ),
    ],
  ),
  SttCatalogEntry(
    id: 'egy-whisper-turbo-ggml-q5',
    label: 'المصري — خفيف',
    note: 'يستهلك ≈٠.٩٥ جيجابايت من الذاكرة — فروق طفيفة في التشكيل',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: false,
    engine: SttEngineKind.whisperCpp,
    files: [
      SttModelFile(
        name: 'ggml-egy-turbo-q5_0.bin',
        url:
            'https://huggingface.co/AhmedAttia3/sanad-egy-whisper-turbo-ggml/resolve/main/ggml-egy-turbo-q5_0.bin',
        sizeBytes: 574061359,
        sha256:
            '6da4b0e2542f758c96b0594afd1b805839bb7600d38e8fa0a4c415ef953fbbc2',
      ),
    ],
  ),
  SttCatalogEntry(
    id: 'whisper-turbo-ggml-q5',
    label: 'Whisper Turbo (ggml q5_0)',
    note: 'النسخة العالمية متعددة اللغات — للاختبار',
    mode: SttModelMode.batchVad,
    language: 'ar',
    isDefault: false,
    hidden: true,
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
    label: 'سريع جدًا — دقة أقل',
    note: 'يستهلك ≈٠.٧٦ جيجابايت من الذاكرة — للأجهزة الضعيفة جدًا',
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
  // Streaming proof entry (English only) — see [kEnglishStreamingEntry].
  kEnglishStreamingEntry,
];

/// English streaming entry used to prove the streaming path end to end (G5).
///
/// English-only is a documented limitation, not an oversight: no
/// sherpa-packaged Arabic streaming model exists yet (see G0b). The entry is
/// visible because the proof requires the user to pick it, and it is labelled as
/// experimental so it is never mistaken for the Arabic default.
const SttCatalogEntry kEnglishStreamingEntry = SttCatalogEntry(
  id: 'en-streaming-zipformer-20m',
  label: 'إنجليزي — بث مباشر (تجريبي)',
  note: 'يستهلك ≈٠.٢ جيجابايت — نص فوري أثناء الكلام (إنجليزي فقط)',
  mode: SttModelMode.streaming,
  language: 'en',
  files: [
    SttModelFile(
      name: 'encoder-epoch-99-avg-1.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main/encoder-epoch-99-avg-1.int8.onnx',
      sizeBytes: 42845182,
      sha256:
          '3810755ce7c3ab26b42a8bcf39d191308fa27fb0f53358823ba46141d03b7eb3',
    ),
    SttModelFile(
      name: 'decoder-epoch-99-avg-1.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main/decoder-epoch-99-avg-1.onnx',
      sizeBytes: 2092272,
      sha256:
          '45a7f940ecfb53d89fa270ad11b88b961e53a317203eb24b1c8e95ed208b0f30',
    ),
    SttModelFile(
      name: 'joiner-epoch-99-avg-1.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main/joiner-epoch-99-avg-1.int8.onnx',
      sizeBytes: 259572,
      sha256:
          'e085d73b593cf9b0707f370dbd656d58327d3fe36d80d849202ef81df02cb01e',
    ),
    SttModelFile(
      name: 'tokens.txt',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main/tokens.txt',
      sizeBytes: 5048,
      sha256:
          '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb',
    ),
  ],
);

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
