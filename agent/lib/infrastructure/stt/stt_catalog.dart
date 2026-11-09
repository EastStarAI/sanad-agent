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
    name: 'Egyptian Whisper Turbo Int8',
    description: {
      'en':
          'Sherpa build with a lighter memory footprint; the whole model is '
          'loaded into RAM.',
      'ar': 'نسخة sherpa بذاكرة أخف — تُحمَّل في الذاكرة كاملة.',
    },
    speedTier: 3,
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
    name: 'Egyptian Whisper Turbo Q8',
    description: {
      'en': 'Recommended for Arabic: 0.9 GB download, about 1.2 GB of memory.',
      'ar': 'الموصى به للعربية: تنزيل ٠.٩ جيجابايت وذاكرة ≈١.٢ جيجابايت.',
    },
    badge: SttModelBadge.recommended,
    speedTier: 3,
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
    name: 'Egyptian Whisper Turbo F16',
    description: {
      'en': 'The unquantized original: largest download and about 1.9 GB of memory.',
      'ar': 'الأصل بلا تكميم: أكبر تنزيل وذاكرة ≈١.٩ جيجابايت.',
    },
    badge: SttModelBadge.moreAccurate,
    speedTier: 2,
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
    name: 'Egyptian Whisper Turbo Q5',
    description: {
      'en': 'Smaller and faster download with about 0.95 GB of memory.',
      'ar': 'تنزيل أصغر وأسرع بذاكرة ≈٠.٩٥ جيجابايت.',
    },
    badge: SttModelBadge.faster,
    speedTier: 4,
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
    name: 'Whisper Large v3 Turbo Q5',
    description: {
      'en': 'Multilingual Whisper build kept for testing.',
      'ar': 'نسخة Whisper متعددة اللغات — للاختبار.',
    },
    speedTier: 3,
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
    name: 'Whisper Base Int8',
    description: {
      'en': 'Small model for very weak devices: about 0.76 GB of memory.',
      'ar': 'نموذج صغير للأجهزة الضعيفة جدًا: ذاكرة ≈٠.٧٦ جيجابايت.',
    },
    badge: SttModelBadge.faster,
    speedTier: 4,
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
  // Streaming entries (English and Arabic) — see the entries below.
  kEnglishStreamingEntry,
  kMultilingualStreamingEntry,
  // Retired streaming builds stay resolvable for existing installs.
  _enStreaming20230626,
  _enStreamingZipformer20m,
];

/// English streaming entry, superseded but kept resolvable for old installs.
///
/// Measured on the owner's machine: fast but inaccurate on his speech, and the
/// kroko export below is the same size with a much newer model.
const SttCatalogEntry _enStreaming20230626 = SttCatalogEntry(
  id: 'en-streaming-zipformer-2023-06-26',
  name: 'Zipformer EN 2023-06-26',
  description: {
    'en': 'Superseded English streaming build, kept so existing installs resolve.',
    'ar': 'نسخة بث إنجليزي قديمة، محفوظة للتنصيبات القائمة.',
  },
  speedTier: 4,
  mode: SttModelMode.streaming,
  language: 'en',
  hidden: true,
  files: [
    SttModelFile(
      name: 'encoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main/encoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx',
      sizeBytes: 71082637,
      sha256:
          '0d072fd4ef956294ba9db9e9a71a541ac70659095ec4934c8453d8b2fe740187',
    ),
    SttModelFile(
      name: 'decoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main/decoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx',
      sizeBytes: 1307236,
      sha256:
          '98da299f471e38bb4e1a8df579b8cc9122d6039576a77e357b3c60f17dd83b02',
    ),
    SttModelFile(
      name: 'joiner-epoch-99-avg-1-chunk-16-left-64.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main/joiner-epoch-99-avg-1-chunk-16-left-64.int8.onnx',
      sizeBytes: 259335,
      sha256:
          'd944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297',
    ),
    SttModelFile(
      name: 'tokens.txt',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main/tokens.txt',
      sizeBytes: 5048,
      sha256:
          '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb',
    ),
  ],
);

/// The 20M build that G5 shipped. Kept hidden: measured on the owner's machine
/// it produced its first character only after 3–5 s and rendered "Hello world"
/// as `T`, because the runtime it was pinned to could not load the model above.
/// It stays in the catalog so an existing install still resolves its files.
const SttCatalogEntry _enStreamingZipformer20m = SttCatalogEntry(
  id: 'en-streaming-zipformer-20m',
  name: 'Zipformer EN 20M',
  description: {
    'en': 'First-generation English streaming build, kept for compatibility only.',
    'ar': 'أول نسخة بث إنجليزي — للتوافق فقط.',
  },
  speedTier: 3,
  mode: SttModelMode.streaming,
  language: 'en',
  hidden: true,
  // The 20M build is a first-generation zipformer export, unlike every later
  // one, so it keeps the older metadata dialect.
  streamingModelType: 'zipformer',
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

/// English streaming entry: `sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06`.
///
/// Same download size as the 2023 build (≈71 MB) and far newer. Probed with a
/// 6.6 s WAV: loads with `modelType: zipformer2` and transcribes correctly from
/// the first word.
const SttCatalogEntry kEnglishStreamingEntry = SttCatalogEntry(
  id: 'en-streaming-zipformer-kroko-2025-08-06',
  name: 'Zipformer EN Kroko 2025-08-06',
  description: {
    'en': 'English streaming: text appears while you speak, about 0.07 GB.',
    'ar': 'بث إنجليزي: يظهر النص أثناء الكلام، ≈٠.٠٧ جيجابايت.',
  },
  badge: SttModelBadge.faster,
  speedTier: 4,
  mode: SttModelMode.streaming,
  language: 'en',
  files: [
    SttModelFile(
      name: 'encoder.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/encoder.onnx',
      sizeBytes: 70092599,
      sha256:
          'd4881c57449d581e0770fd53fa66c2fdc6cd167d92ece7c715e603defc96d9d4',
    ),
    SttModelFile(
      name: 'decoder.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/decoder.onnx',
      sizeBytes: 617488,
      sha256:
          '455ba38466fce8d5a57e7db68a323b684079ca4d9e1dd93a740d9b2429aae3b1',
    ),
    SttModelFile(
      name: 'joiner.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/joiner.onnx',
      sizeBytes: 336817,
      sha256:
          'd406f616736350e2a7df3e39398b78eb2fc1a2ca6973a19d3853fa3227e25b52',
    ),
    SttModelFile(
      name: 'tokens.txt',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/tokens.txt',
      sizeBytes: 6310,
      sha256:
          '396dbeb5f4858875690716084f54e90d339679d0ba3e6b5b584f3d7589254d2d',
    ),
  ],
);

/// The first genuinely Arabic-capable streaming entry:
/// `sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10`.
///
/// Left-128 int8, ≈339 MB. Probed with an Arabic 16 kHz WAV and `modelType:
/// zipformer2`: it produces Arabic text as the audio arrives, so Arabic
/// dictation no longer has to be batch-only.
const SttCatalogEntry kMultilingualStreamingEntry = SttCatalogEntry(
  id: 'multilingual-streaming-zipformer-2025-02-10',
  name: 'Zipformer Multilingual 2025-02-10',
  description: {
    'en':
        'Arabic and English streaming: text appears while you speak, about '
        '0.34 GB.',
    'ar': 'بث عربي وإنجليزي: يظهر النص أثناء الكلام، ≈٠.٣٤ جيجابايت.',
  },
  speedTier: 3,
  mode: SttModelMode.streaming,
  language: 'ar',
  files: [
    SttModelFile(
      name: 'encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10/resolve/main/encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      sizeBytes: 296583597,
      sha256:
          'f9001ed7a9e46d0294438c1a30cd7c72d1cc4bdd4e7880edbcda36f67081e32e',
    ),
    SttModelFile(
      name: 'decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10/resolve/main/decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
      sizeBytes: 33837085,
      sha256:
          '7ebc63f34b21c8efb4a41a5a2eee7fe1448829ce0230ecc5369e67fc14d90d48',
    ),
    SttModelFile(
      name: 'joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10/resolve/main/joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      sizeBytes: 8257421,
      sha256:
          'db88e3172323551abaa99b91b18fb422a27ea4a834fd0db10389f9478816f917',
    ),
    SttModelFile(
      name: 'tokens.txt',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10/resolve/main/tokens.txt',
      sizeBytes: 195244,
      sha256:
          '784f24950f6bcce1b0021035632dd60fd4617ecd8ca0581ab57d7b39d77ba5ab',
    ),
  ],
);

/// The default entry: the first `isDefault`, else the first entry.
SttCatalogEntry get defaultSttEntry => kSttCatalog.firstWhere(
  (entry) => entry.isDefault,
  orElse: () => kSttCatalog.first,
);

/// Every catalog entry this build can actually run, in catalog order.
///
/// A build without the sherpa engine keeps the whisper.cpp entries and drops
/// the rest: offering a model whose engine was not compiled in would fail at
/// load time instead of explaining itself. Hidden entries are kept — the caller
/// filters those — so this is about capability, not presentation.
List<SttCatalogEntry> usableSttEntries(SttEngineAvailability availability) => [
  for (final entry in kSttCatalog)
    if (availability.supports(entry.engine)) entry,
];

/// The entry a fresh install should use on this build.
///
/// The catalog default is the recommended model; when its engine is not part of
/// this build, the first usable entry takes its place so a device never starts
/// with an impossible selection.
SttCatalogEntry? defaultUsableSttEntry(SttEngineAvailability availability) {
  final usable = usableSttEntries(availability);
  if (usable.isEmpty) return null;
  final preferred = defaultSttEntry;
  for (final entry in usable) {
    if (entry.id == preferred.id) return entry;
  }
  return usable.first;
}

SttCatalogEntry? sttEntryById(String id) {
  for (final entry in kSttCatalog) {
    if (entry.id == id) return entry;
  }
  return null;
}
