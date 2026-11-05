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
    if (!Platform.isMacOS) return false;
    return Abi.current() == Abi.macosArm64;
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
    return const SttReadiness.ready();
  }

  /// Reloads `config.yaml` so an edited file takes effect without a restart.
  void reloadSettings() {
    try {
      _settings = SttSettings.load(sanadHome: sanadHome);
      _configError = null;
    } on SttException catch (error) {
      _configError = error;
    }
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
    return _readSelection() ?? defaultSttEntry.id;
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

  Map<String, dynamic> statusPayload() {
    final readiness = this.readiness();
    final installedOverrides = _settings.modelPath?.trim();
    return {
      'supported': readiness.isSupported,
      if (readiness.reason != null) 'reason': readiness.reason,
      'busy': isBusy,
      'selected': selectedModelId,
      'model_path': (installedOverrides?.isEmpty ?? true)
          ? null
          : installedOverrides,
      'models': [
        for (final entry in kSttCatalog)
          {
            'id': entry.id,
            'label': entry.label,
            'note': entry.note,
            'mode': entry.mode.name,
            'language': entry.language,
            'total_bytes': entry.totalBytes,
            'hosted': entry.hosted,
            'installed': _store.statusOf(entry).installed,
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
  bool _installing = false;
  bool _installCancelled = false;
  bool _closed = false;

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
    if (_closed || chunk.isEmpty) return;
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
    if (_session != null) return;
    service._applySettingsFromDisk();
    final readiness = service.readiness();
    if (!readiness.isSupported) {
      transport.send('dictation_error', {
        'code': 'unsupported',
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
    final engine = service.createEngineFor(files);
    try {
      await engine.start(
        files,
        modelId: files.modelId,
        threads: service.settings.threads,
      );
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
