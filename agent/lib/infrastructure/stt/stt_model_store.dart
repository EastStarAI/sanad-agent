/// Local dictation model installation and resolution.
///
/// Everything lives under `Sanad Home/models/stt/<model-id>/`; the Silero VAD
/// asset is shared in `_shared/`. Downloads are one-writer, cancellable,
/// checksum-verified, and activated by an atomic rename, so a partially
/// downloaded model can never be reported as ready.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'stt_catalog.dart';
import 'stt_settings.dart';
import 'stt_types.dart';

/// Explicit artifact paths the engine needs.
class SttModelFiles {
  const SttModelFiles({
    required this.modelId,
    required this.encoder,
    required this.decoder,
    required this.tokens,
    required this.vad,
    required this.language,
    this.engine = SttEngineKind.sherpa,
    this.model = '',
    this.joiner = '',
    this.mode = SttModelMode.batchVad,
    this.streamingModelType = 'zipformer2',
  });

  final String modelId;
  final String encoder;
  final String decoder;
  final String tokens;
  final String vad;
  final String language;

  /// Which runtime decodes this model.
  final SttEngineKind engine;

  /// The single ggml file, used only by [SttEngineKind.whisperCpp].
  final String model;

  /// Transducer joiner, used only by a streaming sherpa entry.
  final String joiner;

  /// Batch VAD or native streaming; decides which sherpa recognizer is built.
  final SttModelMode mode;

  /// sherpa `modelType` for a streaming entry (exports differ per generation).
  final String streamingModelType;
}

/// Installation state of one catalog entry.
class SttModelStatus {
  const SttModelStatus({
    required this.entry,
    required this.installed,
    required this.bytesOnDisk,
  });

  final SttCatalogEntry entry;
  final bool installed;
  final int bytesOnDisk;
}

/// Progress callback: model id, bytes received, total bytes.
typedef SttProgressCallback = void Function(String id, int received, int total);

class SttModelStore {
  SttModelStore({required this.sanadHome, HttpClient Function()? httpClient})
    : _httpClient = httpClient ?? HttpClient.new;

  final String sanadHome;
  final HttpClient Function() _httpClient;

  static const String _partialSuffix = '.partial';

  String get modelsRoot => '$sanadHome/models/stt';
  String get sharedDir => '$modelsRoot/_shared';
  String modelDir(String id) => '$modelsRoot/$id';
  String get vadPath => '$sharedDir/${kSileroVadFile.name}';

  /// The persisted per-device model choice, beside the models it names.
  String get selectionPath => '$modelsRoot/selection.json';

  /// The stored model id, or null when the file is absent or names nothing the
  /// catalog still has.
  ///
  /// Reading is deliberately tolerant: a corrupt or retired selection must fall
  /// back to the caller's default, never fail a status request. Whether the
  /// entry is *usable on this build* is the caller's question, not this store's.
  String? readSelectionId() {
    final file = File(selectionPath);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map && decoded['model_id'] is String) {
        final id = decoded['model_id'] as String;
        return sttEntryById(id) == null ? null : id;
      }
    } on Object {
      // A corrupt selection falls back to the catalog default.
    }
    return null;
  }

  /// Persists [modelId] as this device's choice.
  Future<void> writeSelectionId(String modelId) async {
    await Directory(modelsRoot).create(recursive: true);
    await File(
      selectionPath,
    ).writeAsString(jsonEncode({'model_id': modelId}));
  }

  /// Whether every catalog file plus the shared VAD asset already exists with
  /// the declared byte size. Checksums are verified at install time only.
  SttModelStatus statusOf(SttCatalogEntry entry) {
    var installed = true;
    var bytes = 0;
    for (final file in entry.files) {
      final handle = File('${modelDir(entry.id)}/${file.name}');
      if (!handle.existsSync() || handle.lengthSync() != file.sizeBytes) {
        installed = false;
        continue;
      }
      bytes += file.sizeBytes;
    }
    // Only the sherpa runtime needs the shared silero VAD asset.
    if (entry.engine == SttEngineKind.sherpa && !File(vadPath).existsSync()) {
      installed = false;
    }
    return SttModelStatus(entry: entry, installed: installed, bytesOnDisk: bytes);
  }

  /// Downloads the entry (and the shared VAD once) then activates it.
  ///
  /// Throws [SttException] with code `cancelled` when [isCancelled] turns true,
  /// `download_failed` on transport errors, `checksum_mismatch` when bytes do
  /// not match the pinned digest, and `not_hosted` when the entry has no URL.
  Future<void> install(
    SttCatalogEntry entry, {
    SttProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!entry.hosted ||
        entry.files.any((file) => file.url.isEmpty)) {
      throw SttException(
        'not_hosted',
        'model "${entry.id}" has no pinned download URL yet; '
            'install it manually and set stt.model_path',
      );
    }
    await Directory(modelDir(entry.id)).create(recursive: true);
    await Directory(sharedDir).create(recursive: true);
    // Progress is cumulative across every artifact of the install, so the
    // client bar never drops back to zero between encoder/decoder/tokens.
    final needsVad =
        entry.engine == SttEngineKind.sherpa && !File(vadPath).existsSync();
    var total = entry.files.fold<int>(0, (sum, file) => sum + file.sizeBytes);
    if (needsVad) total += kSileroVadFile.sizeBytes;
    var offset = 0;
    if (needsVad) {
      await _downloadFile(
        kSileroVadFile,
        vadPath,
        id: entry.id,
        onProgress: onProgress,
        isCancelled: isCancelled,
        offsetBase: offset,
        grandTotal: total,
      );
      offset += kSileroVadFile.sizeBytes;
    }
    for (final file in entry.files) {
      await _downloadFile(
        file,
        '${modelDir(entry.id)}/${file.name}',
        id: entry.id,
        onProgress: onProgress,
        isCancelled: isCancelled,
        offsetBase: offset,
        grandTotal: total,
      );
      offset += file.sizeBytes;
    }
  }

  Future<void> _downloadFile(
    SttModelFile file,
    String destination, {
    required String id,
    SttProgressCallback? onProgress,
    bool Function()? isCancelled,
    int offsetBase = 0,
    int? grandTotal,
  }) async {
    final partial = File('$destination$_partialSuffix');
    if (partial.existsSync()) {
      await partial.delete();
    }

    final client = _httpClient();
    final digestCollector = _DigestCollector();
    IOSink? sink;
    var received = 0;
    try {
      final request = await client.getUrl(Uri.parse(file.url));
      request.followRedirects = true;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw SttException(
          'download_failed',
          'HTTP ${response.statusCode} for ${file.name}',
        );
      }
      final hashInput = sha256.startChunkedConversion(digestCollector);
      sink = partial.openWrite();
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          throw const SttException('cancelled', 'download cancelled');
        }
        received += chunk.length;
        hashInput.add(chunk);
        sink.add(chunk);
        onProgress?.call(
          id,
          offsetBase + received,
          grandTotal ?? file.sizeBytes,
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      hashInput.close();
      final digest = digestCollector.value?.toString();
      if (digest == null || digest != file.sha256) {
        await _deleteQuietly(partial);
        throw SttException(
          'checksum_mismatch',
          '${file.name} checksum mismatch',
        );
      }
      if (received != file.sizeBytes) {
        await _deleteQuietly(partial);
        throw SttException(
          'checksum_mismatch',
          '${file.name} size mismatch ($received != ${file.sizeBytes})',
        );
      }
      // Atomic activation: a reader either sees the verified file or nothing.
      await partial.rename(destination);
    } on SttException {
      await _deleteQuietly(partial);
      rethrow;
    } on Object catch (error) {
      await _deleteQuietly(partial);
      throw SttException('download_failed', '${file.name}: $error');
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Best effort: a stale partial is retried on the next install.
    }
  }

  /// Resolves the engine inputs for [settings].
  ///
  /// A `model_path` override wins over the catalog: its required files are
  /// discovered by name and no checksum is enforced, because the user supplied
  /// the directory. Anything missing yields a typed error naming the gap.
  /// Precedence for which catalog entry a session loads: an explicit
  /// `stt.model_id` in config wins, then the user's selection from the model
  /// sheet, then the catalog default.
  String resolveModelId(SttSettings settings, {String? selectedModelId}) {
    if (settings.modelId.isNotEmpty) return settings.modelId;
    return selectedModelId ?? settings.effectiveModelId;
  }

  SttModelFiles? resolve(SttSettings settings, {String? selectedModelId}) {
    final overridePath = settings.modelPath?.trim();
    if (overridePath != null && overridePath.isNotEmpty) {
      return _resolveDirectory(
        Directory(overridePath),
        modelId: 'path-override',
        language: settings.language,
      );
    }
    // Precedence: an explicit `stt.model_id` in config wins, then the user's
    // selection from the model sheet, then the catalog default.
    final modelId = resolveModelId(settings, selectedModelId: selectedModelId);
    final entry = sttEntryById(modelId);
    if (entry == null) {
      throw SttException(
        'model_unknown',
        'model "$modelId" is not in the catalog',
      );
    }
    final dir = modelDir(entry.id);
    if (!statusOf(entry).installed) return null;
    if (entry.engine == SttEngineKind.whisperCpp) {
      final ggml = entry.files.first;
      return SttModelFiles(
        modelId: entry.id,
        encoder: '',
        decoder: '',
        tokens: '',
        vad: '',
        language: settings.language,
        engine: SttEngineKind.whisperCpp,
        model: '$dir/${ggml.name}',
      );
    }
    return SttModelFiles(
      modelId: entry.id,
      encoder: '$dir/${_byKind(entry.files, 'encoder').name}',
      decoder: '$dir/${_byKind(entry.files, 'decoder').name}',
      tokens: '$dir/${_byKind(entry.files, 'tokens').name}',
      vad: vadPath,
      language: entry.language,
      mode: entry.mode,
      joiner: entry.mode == SttModelMode.streaming
          ? '$dir/${_byKind(entry.files, 'joiner').name}'
          : '',
      streamingModelType: entry.streamingModelType,
    );
  }

  SttModelFiles? _resolveDirectory(
    Directory dir, {
    required String modelId,
    required String language,
  }) {
    if (!dir.existsSync()) return null;
    final files = dir
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList();
    String? find(String needle, String extension) {
      for (final name in files) {
        if (name.endsWith(extension) && name.contains(needle)) return name;
      }
      return null;
    }

    final encoder = find('encoder', '.onnx');
    final decoder = find('decoder', '.onnx');
    final tokens = find('tokens', '.txt');
    if (encoder == null || decoder == null || tokens == null) {
      // A directory holding one ggml file is a whisper.cpp trial, not an
      // incomplete sherpa model: `stt.model_path` then needs no extra config.
      for (final name in files) {
        if (name.endsWith('.bin')) {
          return SttModelFiles(
            modelId: modelId,
            encoder: '',
            decoder: '',
            tokens: '',
            vad: '',
            language: language,
            engine: SttEngineKind.whisperCpp,
            model: '${dir.path}/$name',
          );
        }
      }
      throw const SttException(
        'model_incomplete',
        'stt.model_path must contain *encoder*.onnx, *decoder*.onnx and *tokens*.txt',
      );
    }
    if (!File(vadPath).existsSync()) {
      throw const SttException(
        'vad_missing',
        'the shared Silero VAD asset is not installed',
      );
    }
    return SttModelFiles(
      modelId: modelId,
      encoder: '${dir.path}/$encoder',
      decoder: '${dir.path}/$decoder',
      tokens: '${dir.path}/$tokens',
      vad: vadPath,
      language: language,
    );
  }

  SttModelFile _byKind(List<SttModelFile> files, String needle) {
    for (final file in files) {
      if (file.name.contains(needle)) return file;
    }
    throw SttException('model_incomplete', 'catalog entry lacks a $needle file');
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Reads a catalog entry's manifest as JSON, used by tests and diagnostics.
String describeCatalogEntry(SttCatalogEntry entry) => jsonEncode({
  'id': entry.id,
  'label': entry.label,
  'mode': entry.mode.name,
  'language': entry.language,
  'total_bytes': entry.totalBytes,
  'hosted': entry.hosted,
  'files': [
    for (final file in entry.files)
      {'name': file.name, 'size': file.sizeBytes, 'sha256': file.sha256},
  ],
});
