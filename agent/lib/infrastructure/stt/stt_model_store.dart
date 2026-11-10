/// Local dictation model installation and resolution.
///
/// Everything lives under `Sanad Home/models/stt/<model-id>/`; the Silero VAD
/// asset is shared in `_shared/`. Downloads are one-writer, resumable,
/// memory-bounded, checksum-verified, and activated by an atomic rename, so a
/// partially downloaded model can never be reported as ready.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'stt_catalog.dart';
import 'stt_digest.dart';
import 'stt_download_pipeline.dart';
import 'stt_free_space.dart';
import 'stt_settings.dart';
import 'stt_types.dart';

// The write side lives in its own library now; re-exported because callers that
// used to reach for the sink seam through the store still should.
export 'stt_download_pipeline.dart';

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
  SttModelStore({
    required this.sanadHome,
    HttpClient Function()? httpClient,
    SttModelFile sharedVadAsset = kSileroVadFile,
    SttFreeSpaceProbe freeSpaceProbe = defaultSttFreeSpace,
    SttWritePipelineFactory createPipeline = IsolateWritePipeline.open,
    SttDigestFactory createDigest = createSttDigest,
  }) : _httpClient = httpClient ?? HttpClient.new,
       _sharedVadAsset = sharedVadAsset,
       _freeSpaceProbe = freeSpaceProbe,
       _createPipeline = createPipeline,
       _createDigest = createDigest;

  final String sanadHome;
  final HttpClient Function() _httpClient;

  /// Free space of the volume an install writes to.
  ///
  /// Injected because it is the one fact `dart:io` cannot answer: a test proves
  /// the refusal deterministically instead of depending on how full the machine
  /// running it happens to be.
  final SttFreeSpaceProbe _freeSpaceProbe;

  /// How one artifact's bytes reach the disk.
  ///
  /// Production writes in a separate isolate ([IsolateWritePipeline]) so the
  /// socket read loop never pays for the write; a test injects
  /// `inProcessPipeline(opener)` to keep its sink in the picture.
  final SttWritePipelineFactory _createPipeline;

  /// The factory above, exposed so a test can prove the shipped default is the
  /// isolate pipeline instead of inferring it from behaviour a fast disk masks.
  @visibleForTesting
  SttWritePipelineFactory get pipelineFactory => _createPipeline;

  /// How the artifact's SHA-256 is computed.
  ///
  /// Production is OS crypto through `dart:ffi` with a pure-Dart fallback; the
  /// seam is what lets a test pin both.
  final SttDigestFactory _createDigest;

  final Logger _logger = Logger('SttModelStore');

  /// The shared VAD descriptor an install downloads.
  ///
  /// Production is always [kSileroVadFile], whose URL is a third-party release
  /// host. The descriptor is injectable because it is the one artifact a
  /// catalog entry does not carry: without this seam a unit test of [install]
  /// would fetch a live remote file. Nothing else about the asset is
  /// configurable — the path stays `<sharedDir>/<name>`.
  final SttModelFile _sharedVadAsset;

  static const String _partialSuffix = '.partial';

  /// How many times one artifact may be requested again after a transient
  /// failure. Three retries cover a dropped connection on a 4.5-minute download
  /// without turning a dead host into a busy loop.
  static const int _maxDownloadAttempts = 4;

  /// Backoff before retry `n`; it grows linearly, so the whole retry budget for
  /// one artifact stays inside ten seconds.
  static const Duration _retryBackoff = Duration(seconds: 1);

  String get modelsRoot => '$sanadHome/models/stt';
  String get sharedDir => '$modelsRoot/_shared';
  String modelDir(String id) => '$modelsRoot/$id';
  String get vadPath => '$sharedDir/${_sharedVadAsset.name}';

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
  /// `storage_full` when the volume cannot hold the artifacts plus
  /// [kSttInstallFreeSpaceMarginBytes], `download_failed` on transport errors
  /// that outlast the retry budget, `checksum_mismatch` when bytes do not match
  /// the pinned digest or size, and `not_hosted` when the entry has no URL.
  ///
  /// A resumable partial is never deleted by a transient failure, so a retry —
  /// or a later press — continues from the bytes already on disk.
  Future<void> install(
    SttCatalogEntry entry, {
    SttProgressCallback? onProgress,
    void Function(SttInstallPhase phase)? onPhase,
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
    // A file already on disk at its pinned size is not downloaded again: the
    // install is then resumable at artifact granularity, and the free-space
    // check below asks only for what this run will really write.
    final plan = _installPlan(entry);
    final pending = plan.pending;
    // Progress is cumulative across every artifact of the **model**, including
    // the ones an earlier run already finished. Counting only the pending ones
    // made a resumed encoder/decoder model open at the pending file's share of
    // the pending total — 24 % on disk reported as 7 % — so the bar stepped
    // backwards on its own resume, against this method's own contract.
    final needsVad =
        entry.engine == SttEngineKind.sherpa && !File(vadPath).existsSync();
    if (pending.isEmpty && !needsVad) {
      _logger.info('dictation model already installed: ${entry.id}');
      return;
    }
    final pendingBytes = pending.fold<int>(
      0,
      (sum, file) => sum + file.sizeBytes,
    );
    final fetchBytes = needsVad
        ? pendingBytes + _sharedVadAsset.sizeBytes
        : pendingBytes;
    final total = plan.completeBytes + fetchBytes;
    // Only what this run writes is charged against the volume: the artifacts it
    // already holds are not requested again.
    await _guardFreeSpace(fetchBytes, modelId: entry.id);
    var offset = plan.completeBytes;
    if (needsVad) {
      await _downloadFile(
        _sharedVadAsset,
        vadPath,
        id: entry.id,
        onProgress: onProgress,
        onPhase: onPhase,
        isCancelled: isCancelled,
        offsetBase: offset,
        grandTotal: total,
      );
      offset += _sharedVadAsset.sizeBytes;
    }
    for (final file in pending) {
      await _downloadFile(
        file,
        '${modelDir(entry.id)}/${file.name}',
        id: entry.id,
        onProgress: onProgress,
        onPhase: onPhase,
        isCancelled: isCancelled,
        offsetBase: offset,
        grandTotal: total,
      );
      offset += file.sizeBytes;
    }
  }

  /// Splits [entry] into the artifacts this run still fetches and the bytes it
  /// already holds, in one pass and in catalog order.
  ({List<SttModelFile> pending, int completeBytes}) _installPlan(
    SttCatalogEntry entry,
  ) {
    final pending = <SttModelFile>[];
    var completeBytes = 0;
    for (final file in entry.files) {
      if (_isCompleteFile(file, '${modelDir(entry.id)}/${file.name}')) {
        completeBytes += file.sizeBytes;
      } else {
        pending.add(file);
      }
    }
    return (pending: pending, completeBytes: completeBytes);
  }

  /// Whether [path] already holds [file] at its pinned size.
  bool _isCompleteFile(SttModelFile file, String path) {
    final handle = File(path);
    return handle.existsSync() && handle.lengthSync() == file.sizeBytes;
  }

  /// Refuses an install the volume cannot hold, before a byte is written.
  ///
  /// A download that starts and then stalls on a full disk is the worst of both
  /// outcomes: the user waits minutes to learn what one probe knew immediately,
  /// and the daemon has already queued writes it cannot complete.
  Future<void> _guardFreeSpace(int neededBytes, {required String modelId}) async {
    final free = await _freeSpaceProbe(modelsRoot);
    if (free == null) return;
    final required = neededBytes + kSttInstallFreeSpaceMarginBytes;
    if (free >= required) return;
    _logger.warning(
      'dictation model install refused: storage_full model=$modelId '
      'need=$required free=$free',
    );
    throw SttException(
      'storage_full',
      'not enough free disk space to install "$modelId": '
          '$neededBytes bytes plus a '
          '${kSttInstallFreeSpaceMarginBytes ~/ (1024 * 1024)} MB margin is '
          'required, $free bytes are available',
    );
  }

  Future<void> _downloadFile(
    SttModelFile file,
    String destination, {
    required String id,
    SttProgressCallback? onProgress,
    void Function(SttInstallPhase phase)? onPhase,
    bool Function()? isCancelled,
    int offsetBase = 0,
    int? grandTotal,
  }) async {
    final partial = File('$destination$_partialSuffix');
    final total = grandTotal ?? file.sizeBytes;
    var resumeFrom = _resumableBytes(partial, file.sizeBytes);
    if (resumeFrom > 0) {
      _logger.info(
        'dictation model download resuming: model=$id file=${file.name} '
        'bytes=$resumeFrom',
      );
    }
    _TransferResult? transferred;
    SttException? failure;
    for (var attempt = 1; attempt <= _maxDownloadAttempts; attempt++) {
      if (isCancelled?.call() ?? false) {
        throw const SttException('cancelled', 'download cancelled');
      }
      try {
        transferred = await _transfer(
          file,
          partial,
          resumeFrom: resumeFrom,
          id: id,
          onProgress: onProgress,
          onPhase: onPhase,
          isCancelled: isCancelled,
          offsetBase: offsetBase,
          grandTotal: total,
        );
        if (transferred.bytesOnDisk == file.sizeBytes) break;
        // A body that ends early is a truncation, not a wrong file: the bytes it
        // did deliver are resumable, so they stay and the next attempt continues
        // from them.
        resumeFrom = transferred.bytesOnDisk;
        failure = SttException(
          'download_failed',
          '${file.name}: short body '
              '(${transferred.bytesOnDisk} of ${file.sizeBytes})',
        );
        transferred = null;
      } on _DownloadRejected catch (rejected) {
        // A refusal the server will repeat verbatim (404, 403, a range it cannot
        // satisfy) is not worth a retry budget.
        throw rejected.error;
      } on SttException catch (error) {
        if (!_isRetryable(error)) rethrow;
        failure = error;
        transferred = null;
        resumeFrom = _resumableBytes(partial, file.sizeBytes);
      }
      if (attempt == _maxDownloadAttempts) break;
      _logger.info(
        'dictation model download retry: model=$id file=${file.name} '
        'attempt=${attempt + 1} bytes=$resumeFrom',
      );
      await Future<void>.delayed(_retryBackoff * attempt);
    }
    final result = transferred;
    if (result == null) {
      throw failure ??
          const SttException('download_failed', 'download failed');
    }
    onPhase?.call(SttInstallPhase.verifying);
    final digest = result.digest;
    if (digest == null || digest != file.sha256) {
      // A digest that does not match can never resume into a valid file, so this
      // is the one failure that discards the bytes.
      await _deleteQuietly(partial);
      throw SttException(
        'checksum_mismatch',
        '${file.name} checksum mismatch',
      );
    }
    onPhase?.call(SttInstallPhase.activating);
    // Atomic activation: a reader either sees the verified file or nothing.
    await partial.rename(destination);
    onPhase?.call(SttInstallPhase.downloading);
  }

  /// What `install` will continue from and report as its total.
  ///
  /// The projection published at install start (`stt_status.install`) is built
  /// before the first HTTP response, so without this the daemon stated
  /// `received_bytes: 0` for a partial it already held, and a resumed download
  /// visibly restarted its bar at 0 % for the first second or so. [received]
  /// counts only resumable bytes of the artifacts this run will actually fetch,
  /// and [total] is the same cumulative total `install` reports, so the two never
  /// disagree.
  ({int received, int total})? installSeed(SttCatalogEntry entry) {
    if (!entry.hosted || entry.files.any((file) => file.url.isEmpty)) return null;
    final plan = _installPlan(entry);
    final needsVad =
        entry.engine == SttEngineKind.sherpa && !File(vadPath).existsSync();
    if (plan.pending.isEmpty && !needsVad) {
      // Nothing is fetched, so there is no install to project: the run settles
      // as already-installed. A 100 % row here would be a flash, not progress.
      return (received: 0, total: 0);
    }
    final pendingBytes = plan.pending.fold<int>(
      0,
      (sum, file) => sum + file.sizeBytes,
    );
    var received = plan.completeBytes;
    var total = plan.completeBytes + pendingBytes;
    if (needsVad) {
      received += _resumableLength(
        File('$vadPath$_partialSuffix'),
        _sharedVadAsset.sizeBytes,
      );
      total += _sharedVadAsset.sizeBytes;
    }
    for (final file in plan.pending) {
      received += _resumableLength(
        File('${modelDir(entry.id)}/${file.name}$_partialSuffix'),
        file.sizeBytes,
      );
    }
    return (received: received, total: total);
  }

  /// Bytes of [partial] that may be resumed from.
  ///
  /// A zero-length, oversized, or already-complete partial is not resumable and
  /// is replaced by the next attempt.
  int _resumableBytes(File partial, int sizeBytes) {
    final resumable = _resumableLength(partial, sizeBytes);
    if (resumable > 0) return resumable;
    if (!partial.existsSync()) return 0;
    try {
      partial.deleteSync();
    } on FileSystemException {
      // A partial that cannot be removed is overwritten from zero anyway.
    }
    return 0;
  }

  /// Resumable prefix of [partial], without touching the file.
  int _resumableLength(File partial, int sizeBytes) {
    if (!partial.existsSync()) return 0;
    final length = partial.lengthSync();
    return length > 0 && length < sizeBytes ? length : 0;
  }

  static bool _isRetryable(SttException error) => switch (error.code) {
    'cancelled' || 'checksum_mismatch' || 'storage_full' || 'not_hosted' =>
      false,
    _ => true,
  };

  /// One artifact transfer, resuming at [resumeFrom] when the server allows it.
  ///
  /// The digest is computed while the bytes are written, so no separate
  /// verification pass over the artifact is needed; a resumed prefix is re-read
  /// into the same hasher first, which is what keeps the final comparison
  /// meaningful.
  Future<_TransferResult> _transfer(
    SttModelFile file,
    File partial, {
    required int resumeFrom,
    required String id,
    SttProgressCallback? onProgress,
    void Function(SttInstallPhase phase)? onPhase,
    bool Function()? isCancelled,
    required int offsetBase,
    required int grandTotal,
  }) async {
    final client = _httpClient();
    SttWritePipeline? pipeline;
    SttDigest? hashInput;
    try {
      final request = await client.getUrl(Uri.parse(file.url));
      request.followRedirects = true;
      if (resumeFrom > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final response = await request.close();
      var start = resumeFrom;
      if (response.statusCode == HttpStatus.partialContent) {
        // The requested range is what the body carries.
      } else if (response.statusCode == HttpStatus.ok) {
        // The server ignored `Range`, or there was nothing to resume: the body
        // is the whole artifact and the partial is rewritten from zero.
        start = 0;
      } else {
        final error = SttException(
          'download_failed',
          'HTTP ${response.statusCode} for ${file.name}',
        );
        final transient =
            response.statusCode >= 500 ||
            response.statusCode == HttpStatus.requestTimeout ||
            response.statusCode == HttpStatus.tooManyRequests;
        if (!transient) throw _DownloadRejected(error);
        throw error;
      }
      pipeline = await _createPipeline(
        partial,
        start > 0 ? FileMode.append : FileMode.write,
      );
      hashInput = _createDigest();
      if (start > 0) {
        // Report the resumed truth before the re-read, so a client that joins
        // here sees the real percentage instead of zero for a whole second.
        onPhase?.call(SttInstallPhase.verifying);
        onProgress?.call(id, offsetBase + start, grandTotal);
        await for (final chunk in partial.openRead(0, start)) {
          if (isCancelled?.call() ?? false) {
            throw const SttException('cancelled', 'download cancelled');
          }
          hashInput.add(chunk);
        }
        onPhase?.call(SttInstallPhase.downloading);
      }
      var onDisk = start;
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          throw const SttException('cancelled', 'download cancelled');
        }
        // Backpressure, at the pipeline rather than at the chunk: the write
        // happens in another isolate, so this returns as soon as the byte
        // window has room and the socket keeps streaming while the disk
        // drains. The window (`kSttWriteWindowBytes`) is what bounds the
        // heap — the reason PR391 replaced an `IOSink.add` with an awaited
        // write in the first place, and the bound this seam keeps.
        await pipeline.add(chunk);
        onDisk += chunk.length;
        hashInput.add(chunk);
        onProgress?.call(id, offsetBase + onDisk, grandTotal);
      }
      await pipeline.drain();
      await pipeline.close();
      pipeline = null;
      return _TransferResult(
        bytesOnDisk: onDisk,
        digest: hashInput.finish(),
      );
    } on _DownloadRejected {
      rethrow;
    } on SttException {
      rethrow;
    } on SttWriteFailure catch (failure) {
      // The writer isolate reported a refused write: map it to the same typed
      // codes an in-process failure always produced.
      throw mapWriteFailure(failure.toFileSystemException(path: partial.path), file.name);
    } on FileSystemException catch (error) {
      throw mapWriteFailure(error, file.name);
    } on Object catch (error) {
      // A dropped connection, a DNS failure, a timeout: transient by nature, so
      // the bytes already on disk stay and the next attempt resumes from them.
      throw SttException('download_failed', '${file.name}: $error');
    } finally {
      // A cancel, a refused write, or a dropped connection never reaches
      // `finish()`, and the digest holds native memory that no Dart finalizer
      // releases: closing it here is what keeps a failed attempt from leaking a
      // context and a staging buffer per retry. It is a no-op after a finish.
      hashInput?.close();
      try {
        await pipeline?.close();
      } on Object {
        // The transfer's own failure is the one worth reporting; a close that
        // also failed changes nothing about it.
      }
      client.close(force: true);
    }
  }

  /// Maps a write failure onto the daemon's typed codes.
  ///
  /// A full volume is `storage_full` — the daemon's existing typed local failure
  /// — not a generic download error, because the remedy is different and the
  /// retry budget must not be spent on it. Exposed so the mapping can be tested
  /// without filling a disk, and so the same mapping can be asserted against a
  /// failure that crossed the writer isolate.
  @visibleForTesting
  static SttException mapWriteFailure(FileSystemException error, String name) {
    final code = error.osError?.errorCode;
    final message = (error.osError?.message ?? error.message).toString();
    final full =
        code == 28 || // ENOSPC on macOS and Linux
        code == 112 || // ERROR_DISK_FULL on Windows
        message.toLowerCase().contains('no space left') ||
        message.toLowerCase().contains('not enough space');
    if (full) {
      return SttException('storage_full', '$name: not enough free disk space');
    }
    return SttException('download_failed', '$name: ${error.message}');
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
        // A catalog row decodes the language it declares. `stt.language`
        // describes a `stt.model_path` override, which carries no catalog
        // metadata: handing it to a catalog row mistranslated every non-Arabic
        // entry, and `auto` on an English-only checkpoint reads outside
        // whisper's logits.
        language: entry.language,
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

/// Outcome of one artifact transfer.
class _TransferResult {
  const _TransferResult({required this.bytesOnDisk, required this.digest});

  /// Bytes the artifact occupies once the transfer returned.
  final int bytesOnDisk;

  /// SHA-256 of the whole artifact, including a resumed prefix.
  final String? digest;
}

/// A server refusal that must not consume the retry budget.
class _DownloadRejected implements Exception {
  const _DownloadRejected(this.error);

  final SttException error;
}

/// Reads a catalog entry's manifest as JSON, used by tests and diagnostics.
String describeCatalogEntry(SttCatalogEntry entry) => jsonEncode({
  'id': entry.id,
  'name': entry.name,
  'mode': entry.mode.name,
  'badge': entry.badge.code,
  'speed_tier': entry.speedTier,
  'location': entry.location.name,
  'language': entry.language,
  'total_bytes': entry.totalBytes,
  'hosted': entry.hosted,
  'files': [
    for (final file in entry.files)
      {'name': file.name, 'size': file.sizeBytes, 'sha256': file.sha256},
  ],
});
