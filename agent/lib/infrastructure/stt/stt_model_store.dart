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
  });

  final String modelId;
  final String encoder;
  final String decoder;
  final String tokens;
  final String vad;
  final String language;
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
    if (!File(vadPath).existsSync()) installed = false;
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
    if (!File(vadPath).existsSync()) {
      await _downloadFile(
        kSileroVadFile,
        vadPath,
        id: entry.id,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    for (final file in entry.files) {
      await _downloadFile(
        file,
        '${modelDir(entry.id)}/${file.name}',
        id: entry.id,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
  }

  Future<void> _downloadFile(
    SttModelFile file,
    String destination, {
    required String id,
    SttProgressCallback? onProgress,
    bool Function()? isCancelled,
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
        onProgress?.call(id, received, file.sizeBytes);
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
  SttModelFiles? resolve(SttSettings settings) {
    final overridePath = settings.modelPath?.trim();
    if (overridePath != null && overridePath.isNotEmpty) {
      return _resolveDirectory(
        Directory(overridePath),
        modelId: 'path-override',
        language: settings.language,
      );
    }
    final entry = sttEntryById(settings.effectiveModelId);
    if (entry == null) {
      throw SttException(
        'model_unknown',
        'model "${settings.effectiveModelId}" is not in the catalog',
      );
    }
    final dir = Directory(modelDir(entry.id));
    if (!statusOf(entry).installed) return null;
    return SttModelFiles(
      modelId: entry.id,
      encoder: '$dir/${_byKind(entry.files, 'encoder').name}',
      decoder: '$dir/${_byKind(entry.files, 'decoder').name}',
      tokens: '$dir/${_byKind(entry.files, 'tokens').name}',
      vad: vadPath,
      language: settings.language,
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
