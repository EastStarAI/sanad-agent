/// Dictation service: readiness, model catalog control, and socket sessions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'dictation_session.dart';
import 'stt_engine.dart';
import 'stt_catalog.dart';
import 'stt_model_store.dart';
import 'stt_settings.dart';
import 'stt_types.dart';
import 'whispercpp_bindings.dart';

/// Readiness/installation/model-selection surface for local dictation.
///
/// `supports_dictation` is true when the device can run the runtime at all
/// (enabled in config, supported platform). Whether a model is installed is a
/// separate status flag, because the first mic press is what installs it.
class DictationService {
  DictationService({
    required this.sanadHome,
    SttEngine Function()? engineFactory,
    HttpClient Function()? httpClient,
    bool? platformSupported,
  }) : _engineFactory = engineFactory ?? SherpaSttEngine.new,
       _platformSupported = platformSupported ?? _isSupportedPlatform() {
    _store = SttModelStore(httpClient: httpClient, sanadHome: sanadHome);
    try {
      _settings = SttSettings.load(sanadHome: sanadHome);
      _configError = null;
    } on SttException catch (error) {
      _settings = const SttSettings();
      _configError = error;
    }
  }

  final Logger _logger = Logger('DictationService');
  final String sanadHome;
  final SttEngine Function() _engineFactory;
  final bool _platformSupported;

  late final SttModelStore _store;
  late SttSettings _settings;
  SttException? _configError;

  SttModelStore get store => _store;
  SttSettings get settings => _settings;

  static bool _isSupportedPlatform() {
    final abi = Abi.current();
    if (Platform.isMacOS) return abi == Abi.macosArm64;
    if (Platform.isWindows) {
      return abi == Abi.windowsX64 || abi == Abi.windowsArm64;
    }
    if (Platform.isLinux) return abi == Abi.linuxX64 || abi == Abi.linuxArm64;
    return false;
  }

  SttReadiness readiness() {
    if (_configError != null) {
      return SttReadiness.unavailable(_configError!.message);
    }
    if (!_settings.enabled) {
      return const SttReadiness.unavailable('dictation_disabled');
    }
    if (!_platformSupported) {
      return const SttReadiness.unavailable('unsupported_platform');
    }
    // Whisper needs its native shim on disk. Report that as its own reason so a
    // fresh clone shows "run ensure_native_stt" instead of a generic failure.
    final entry = selectedEntry;
    if (entry != null &&
        entry.engine == SttEngineKind.whisperCpp &&
        !WhisperCppLibrary.isAvailable) {
      return SttReadiness.unavailable(
        WhisperCppLibrary.isBeingPrepared
            ? 'native_runtime_preparing'
            : 'native_runtime_missing',
        isSupported: true,
      );
    }
    return const SttReadiness.ready();
  }

  /// Starts `tool/ensure_native_stt.dart` in the background.
  ///
  /// Only meaningful in a dev checkout: packaged builds ship the shim beside the
  /// executable. Returns false when the tool or shell is unavailable so the
  /// caller can show the manual instruction instead of pretending it retried.
  bool prepareNativeRuntime() {
    final logFile = 'native/.stt-prepare.log';
    final command = 'fvm dart run tool/ensure_native_stt.dart >> $logFile 2>&1';
    try {
      unawaited(
        Process.start(
          Platform.isWindows ? 'cmd' : '/bin/sh',
          Platform.isWindows ? ['/c', command] : ['-c', command],
          workingDirectory: Directory.current.path,
          mode: ProcessStartMode.detached,
        ),
      );
      _logger.info('native dictation prepare requested');
      return true;
    } on Object catch (error) {
      _logger.warning('native dictation prepare unavailable: $error');
      return false;
    }
  }

  /// Reloads `config.yaml` so an edited file takes effect without a restart.
  void reloadSettings() {
    try {
      _settings = SttSettings.load(sanadHome: sanadHome);
      _configError = null;
    } on SttException catch (error) {
      _configError = error;
    }
    // A config that no longer keeps models warm must not leave one resident.
    if (!_settings.keepsModelWarm) unawaited(unloadWarmEngine());
  }

  String get _selectionPath => '${_store.modelsRoot}/selection.json';

  String? _readSelection() {
    final file = File(_selectionPath);
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

  Future<void> _writeSelection(String modelId) async {
    if (sttEntryById(modelId) == null) {
      throw SttException('model_unknown', 'model "$modelId" is not in the catalog');
    }
    await Directory(_store.modelsRoot).create(recursive: true);
    await File(
      _selectionPath,
    ).writeAsString(jsonEncode({'model_id': modelId}));
  }

  /// Explicit config beats a per-device selection, which beats the default.
  String get selectedModelId {
    if (_settings.modelPath?.trim().isNotEmpty ?? false) return 'path-override';
    if (_settings.modelId.isNotEmpty) return _settings.modelId;
    final selection = _readSelection();
    if (selection != null) {
      // A retired entry stays in the catalog so an old install still resolves
      // its files, but it must never remain the active choice: the 20M streaming
      // build is hidden precisely because it cannot transcribe a first word.
      final entry = sttEntryById(selection);
      if (entry != null && !entry.hidden) return selection;
    }
    return defaultSttEntry.id;
  }

  SttCatalogEntry? get selectedEntry => sttEntryById(selectedModelId);

  /// True while a dictation session holds the engine. A second session is
  /// refused instead of loading a second copy of the model.
  bool get isBusy => _activeSessions > 0;

  int _activeSessions = 0;

  /// One dictation lease per daemon: returns false when another session holds it.
  bool acquireSession() {
    if (_activeSessions > 0) return false;
    _activeSessions = 1;
    return true;
  }

  void releaseSession() => _activeSessions = 0;

  // --- Warm recogniser -------------------------------------------------------
  //
  // Reloading the model for every session dominated the latency the owner
  // measured (3.5 s decode, plus a load that hidden the first word). A warm
  // engine keeps the same model for `settings.modelIdleMinutes` after a session
  // ends, so a burst of dictation pays the load once; an idle timer frees it so
  // the daemon does not hold a model the user stopped using.

  SttEngine? _warmEngine;
  String? _warmModelId;
  Timer? _warmTimer;

  /// True while a recogniser is kept loaded but idle.
  bool get hasWarmEngine => _warmEngine != null;

  /// Starts (or reuses) the engine for [files].
  Future<SttEngine> acquireEngine(SttModelFiles files) async {
    final warm = _warmEngine;
    if (warm != null) {
      _warmTimer?.cancel();
      _warmTimer = null;
      _warmEngine = null;
      final sameModel = _warmModelId == files.modelId;
      _warmModelId = null;
      if (sameModel) {
        await warm.reset();
        _logger.info('dictation reusing warm model=${files.modelId}');
        return warm;
      }
      await warm.dispose();
    }
    final engine = createEngineFor(files);
    try {
      await engine.start(
        files,
        modelId: files.modelId,
        threads: _settings.threads,
        useGpu: _settings.useGpu,
      );
    } on Object {
      await engine.dispose();
      rethrow;
    }
    return engine;
  }

  /// Takes an engine back from a finished session.
  Future<void> releaseEngine(SttEngine engine, String modelId) async {
    if (!_settings.keepsModelWarm) {
      await engine.dispose();
      return;
    }
    await _dropWarmEngine();
    _warmEngine = engine;
    _warmModelId = modelId;
    final minutes = _settings.modelIdleMinutes;
    if (minutes > 0) {
      _warmTimer = Timer(
        Duration(minutes: minutes),
        () => unawaited(_dropWarmEngine()),
      );
      _logger.info(
        'dictation keeping model warm for ${minutes}m model=$modelId',
      );
    }
  }

  /// Frees the warm recogniser now (config change, model switch, shutdown).
  Future<void> unloadWarmEngine() => _dropWarmEngine();

  Future<void> _dropWarmEngine() async {
    _warmTimer?.cancel();
    _warmTimer = null;
    final engine = _warmEngine;
    _warmEngine = null;
    final modelId = _warmModelId;
    _warmModelId = null;
    if (engine == null) return;
    _logger.info('dictation unloaded warm model=$modelId');
    await engine.dispose();
  }

  /// True when `stt.model_path` points at files the engine can actually load.
  bool _resolveOverrideExists() {
    try {
      return _store.resolve(_settings) != null;
    } on Object {
      return false;
    }
  }

  Map<String, dynamic> statusPayload() {
    final readiness = this.readiness();
    final overridePath = _settings.modelPath?.trim();
    final installedOverrides = overridePath != null && overridePath.isNotEmpty
        ? overridePath
        : null;
    // A path that does not resolve is not an installed model: reporting it as
    // ready would start a session that fails at load time.
    final overrideReady =
        installedOverrides != null && _resolveOverrideExists();
    return {
      'supported': readiness.isSupported,
      'ready': readiness.isReady,
      if (readiness.reason != null) 'reason': readiness.reason,
      'busy': isBusy,
      'selected': selectedModelId,
      'model_path': (installedOverrides?.isEmpty ?? true)
          ? null
          : installedOverrides,
      'models': [
        // An explicit `stt.model_path` is a ready model even though it is not a
        // catalog entry; without this row the UI offers the setup sheet.
        if (installedOverrides != null)
          {
            'id': 'path-override',
            'label': 'نموذج محلي (stt.model_path)',
            'note': installedOverrides,
            'mode': SttModelMode.batchVad.name,
            'language': _settings.language,
            'total_bytes': 0,
            'hosted': false,
            'installed': overrideReady,
            'engine': SttEngineKind.whisperCpp.name,
          },
        for (final entry in kSttCatalog)
          if (!entry.hidden)
            {
              'id': entry.id,
              'label': entry.label,
              'note': entry.note,
              'mode': entry.mode.name,
              'language': entry.language,
              'total_bytes': entry.totalBytes,
              'hosted': entry.hosted,
              'installed': _store.statusOf(entry).installed,
              'engine': entry.engine.name,
            },
      ],
    };
  }

  Future<void> install(
    String modelId, {
    SttProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final entry = sttEntryById(modelId);
    if (entry == null) {
      throw SttException('model_unknown', 'model "$modelId" is not in the catalog');
    }
    await _store.install(
      entry,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    _logger.info('dictation model installed: $modelId');
  }

  /// Handles one dictation WebSocket for its whole lifetime.
  Future<void> handleSocket(WebSocket socket) async {
    final connection = _DictationConnection(
      service: this,
      transport: WebSocketDictationChannel(socket),
    );
    await connection.run();
  }

  SttEngine createEngine() => _engineFactory();

  /// Picks the runtime the resolved model asks for. A path override that points
  /// at a ggml file is treated as whisper.cpp, so a local trial needs no config.
  SttEngine createEngineFor(SttModelFiles files) {
    if (files.engine == SttEngineKind.whisperCpp) return WhisperCppSttEngine();
    return _engineFactory();
  }

  void _applySettingsFromDisk() => reloadSettings();
}

class _DictationConnection {
  _DictationConnection({required this.service, required this.transport});

  final DictationService service;
  final DictationChannel transport;
  final Logger _logger = Logger('DictationConnection');

  /// Microphone frames can arrive before the engine finished loading its
  /// model. Dropping them loses the first words, so they are buffered here
  /// (bounded) and flushed once the session is running.
  final DictationAudioBuffer _preSession = DictationAudioBuffer();

  DictationSession? _session;
  StreamSubscription<DictationMessage>? _commands;
  StreamSubscription<Uint8List>? _audio;
  StreamController<Uint8List>? _audioIn;
  bool _sessionReady = false;
  bool _starting = false;
  bool _installing = false;
  bool _installCancelled = false;
  bool _closed = false;

  /// Metadata counters only — never audio content — so a session that decodes
  /// nothing can be traced to the side that dropped the frames.
  int _inChunks = 0;

  Future<void> run() async {
    transport.send('stt_status', service.statusPayload());
    _commands = transport.commands.listen((message) {
      unawaited(_handleCommand(message));
    });
    _audio = transport.audio.listen(
      _onAudio,
      onError: (Object _) {},
      onDone: () {},
      cancelOnError: false,
    );
    // The socket stays open until the peer closes it; the audio stream done
    // event triggers teardown through the session.
    await transport.audio.drain<void>().catchError((Object _) {});
    await _teardown();
  }

  void _onAudio(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _inChunks++;
    if (_inChunks == 1) {
      _logger.info(
        'dictation audio in: first chunk bytes=${chunk.length} '
        'ready=$_sessionReady closed=$_closed',
      );
    }
    if (_closed) return;
    final controller = _audioIn;
    if (_sessionReady && controller != null && !controller.isClosed) {
      controller.add(chunk);
      return;
    }
    _preSession.add(chunk);
  }

  Future<void> _teardown() async {
    if (_closed) return;
    _closed = true;
    _installCancelled = true;
    _sessionReady = false;
    service.releaseSession();
    await _commands?.cancel();
    _commands = null;
    await _audio?.cancel();
    _audio = null;
    await _session?.close();
    _session = null;
    final controller = _audioIn;
    _audioIn = null;
    if (controller != null && !controller.isClosed) await controller.close();
    await transport.close();
  }

  Future<void> _handleCommand(DictationMessage message) async {
    try {
      switch (message.command) {
        case DictationCommand.status:
          transport.send('stt_status', service.statusPayload());
        case DictationCommand.install:
          final modelId = message.modelId ?? service.selectedModelId;
          await _install(modelId);
        case DictationCommand.select:
          final modelId = message.modelId;
          if (modelId == null) {
            transport.send('dictation_error', {
              'code': 'model_unknown',
              'message': 'stt_select needs model_id',
            });
            return;
          }
          await service._writeSelection(modelId);
          transport.send('stt_status', service.statusPayload());
        case DictationCommand.start:
          await _startSession();
        case DictationCommand.prepareRuntime:
          final started = service.prepareNativeRuntime();
          transport.send('stt_status', service.statusPayload());
          if (!started) {
            transport.send('dictation_error', {
              'code': 'prepare_unavailable',
              'reason': 'prepare_unavailable',
              'message':
                  'Run `fvm dart run tool/ensure_native_stt.dart` in the agent folder.',
            });
          }
        case DictationCommand.stop:
        case DictationCommand.cancel:
          // Owned by the active session; harmless when none is running.
          if (_session == null) {
            transport.send('stt_status', service.statusPayload());
          }
      }
    } on SttException catch (error) {
      _logger.warning(
        'dictation command failed: code=${error.code} message=${error.message}',
      );
      transport.send('dictation_error', {
        'code': error.code,
        'message': error.message,
      });
    } on Object catch (error) {
      transport.send('dictation_error', {
        'code': 'internal',
        'message': '$error',
      });
    }
  }

  Future<void> _install(String modelId) async {
    if (_installing) {
      transport.send('dictation_error', {
        'code': 'install_in_progress',
        'message': 'another model install is running',
      });
      return;
    }
    _installing = true;
    _installCancelled = false;
    try {
      await service.install(
        modelId,
        isCancelled: () => _installCancelled || _closed,
        onProgress: (id, received, total) {
          transport.send('stt_download_progress', {
            'model_id': id,
            'received_bytes': received,
            'total_bytes': total,
          });
        },
      );
      transport.send('stt_status', service.statusPayload());
    } finally {
      _installing = false;
    }
  }

  Future<void> _startSession() async {
    // A client may repeat `start` (a double press, or a reconnect) while the
    // recognizer is still loading. The second command must be ignored, not
    // answered with `dictation_busy`, which would look like a stuck session.
    if (_session != null || _starting) return;
    _starting = true;
    try {
      await _startSessionOnce();
    } finally {
      _starting = false;
    }
  }

  Future<void> _startSessionOnce() async {
    if (_session != null) return;
    service._applySettingsFromDisk();
    final readiness = service.readiness();
    if (!readiness.isReady) {
      transport.send('dictation_error', {
        'code': 'unavailable',
        'reason': readiness.reason ?? 'dictation unavailable',
        'message': readiness.reason ?? 'dictation unavailable',
      });
      return;
    }
    final files = service.store.resolve(
      service.settings,
      selectedModelId: service.selectedModelId,
    );
    if (files == null) {
      transport.send('dictation_error', {
        'code': 'model_not_installed',
        'message': 'install a dictation model first',
      });
      return;
    }
    if (!service.acquireSession()) {
      _logger.info('dictation refused: another session holds the engine');
      transport.send('dictation_error', {
        'code': 'dictation_busy',
        'message': 'another dictation session is running',
      });
      return;
    }
    final SttEngine engine;
    try {
      engine = await service.acquireEngine(files);
    } on Object {
      service.releaseSession();
      rethrow;
    }
    final audioIn = StreamController<Uint8List>();
    _audioIn = audioIn;
    final session = DictationSession(
      transport: _SessionChannel(transport, audioIn.stream),
      engine: engine,
      modelId: files.modelId,
      // The service owns the recogniser's lifetime now: it parks it warm or
      // frees it according to `stt.model_idle_minutes`.
      onRelease: (finished) => service.releaseEngine(finished, files.modelId),
    );
    _session = session;
    await session.start();
    _sessionReady = true;
    final pending = _preSession.drain();
    for (final chunk in pending) {
      audioIn.add(chunk);
    }
    if (pending.isNotEmpty) {
      _logger.info(
        'dictation pre-session audio flushed: chunks=${pending.length} '
        'dropped_bytes=${_preSession.droppedBytes}',
      );
    }
    _logger.info('dictation session started: model=${files.modelId}');
  }
}

/// Wraps the socket channel so a session consumes the connection's audio
/// controller instead of the raw socket stream.
class _SessionChannel implements DictationChannel {
  _SessionChannel(this._inner, this._audio);

  final DictationChannel _inner;
  final Stream<Uint8List> _audio;

  @override
  Stream<Uint8List> get audio => _audio;

  @override
  Stream<DictationMessage> get commands => _inner.commands;

  @override
  void send(String event, [Map<String, dynamic> payload = const {}]) =>
      _inner.send(event, payload);

  @override
  Future<void> close() => _inner.close();
}

/// Bounded FIFO for microphone frames captured before a session exists.
class DictationAudioBuffer {
  DictationAudioBuffer({this.maxBytes = 4 * 1024 * 1024});

  /// 4 MiB is ≈2 minutes of 16 kHz mono PCM16; beyond that the buffer would
  /// cost more than the words it protects.
  final int maxBytes;

  final List<Uint8List> _chunks = [];
  int _bytes = 0;
  int _droppedBytes = 0;

  int get bufferedBytes => _bytes;
  int get bufferedChunks => _chunks.length;
  int get droppedBytes => _droppedBytes;

  /// Returns false when the frame did not fit and was dropped instead.
  bool add(Uint8List chunk) {
    if (chunk.isEmpty) return true;
    if (_bytes + chunk.length > maxBytes) {
      _droppedBytes += chunk.length;
      return false;
    }
    _chunks.add(chunk);
    _bytes += chunk.length;
    return true;
  }

  /// Removes and returns everything buffered, in arrival order.
  List<Uint8List> drain() {
    final drained = List<Uint8List>.of(_chunks);
    _chunks.clear();
    _bytes = 0;
    return drained;
  }
}
