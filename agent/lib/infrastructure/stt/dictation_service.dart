/// Dictation service: readiness, model catalog control, and channel sessions.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:sanad_release_contract/release_contract.dart';

import 'dictation_session.dart';
import 'stt_engine.dart';
import 'stt_catalog.dart';
import 'stt_model_store.dart';
import 'stt_native_platform.dart';
import 'stt_settings.dart';
import 'stt_types.dart';
import 'whispercpp_bindings.dart';

/// One event a control command asks the caller's channel to deliver.
///
/// The service never knows which transport carries it: the local channel writes
/// a text frame, the hosted adapter attaches an origin delivery envelope.
class DictationControlEvent {
  const DictationControlEvent(this.event, this.payload);

  final String event;
  final Map<String, dynamic> payload;
}

typedef DictationEmit = void Function(String event, Map<String, dynamic> payload);

/// Catalog, install, selection, and preparation commands — shared by both
/// channels so local and hosted behavior cannot diverge.
///
/// These commands are stateless: they create no per-`dictation_id` context, and
/// at most one install runs per device. Session commands (`start`, `stop`,
/// `cancel`) stay with [DictationSession] and one dictation lease.
class DictationControl {
  DictationControl(this._service);

  final DictationService _service;
  final Logger _logger = Logger('DictationControl');

  bool _installing = false;
  bool _installCancelled = false;
  Object? _installOwner;
  String? _installingModelId;

  bool get isInstalling => _installing;
  String? get installingModelId => _installingModelId;

  /// Abandons [owner]'s in-flight install; another channel's install is never
  /// cancelled by a peer's disconnect, deadline, or abort.
  void cancelInstall(Object owner) {
    if (!_installing) return;
    if (!identical(_installOwner, owner)) return;
    _installCancelled = true;
  }

  bool isInstallingFor(Object owner) =>
      _installing && identical(_installOwner, owner);

  /// Runs one stateless command, reporting every outcome through [emit].
  Future<void> handle(
    DictationMessage message, {
    required Object owner,
    required DictationEmit emit,
  }) async {
    try {
      switch (message.command) {
        case DictationCommand.status:
          emit('stt_status', _service.statusPayload());
        case DictationCommand.install:
          await _install(
            message.modelId ?? _service.selectedModelId,
            owner: owner,
            emit: emit,
          );
        case DictationCommand.select:
          final modelId = message.modelId;
          if (modelId == null) {
            emit('dictation_error', {
              'code': 'model_unknown',
              'message': 'stt_select needs model_id',
            });
            return;
          }
          await _service.selectModel(modelId);
          emit('stt_status', _service.statusPayload());
        case DictationCommand.prepareRuntime:
          final started = _service.prepareNativeRuntime();
          emit('stt_status', _service.statusPayload());
          if (!started) {
            emit('dictation_error', {
              'code': 'prepare_unavailable',
              'reason': 'prepare_unavailable',
              'message':
                  'Run `fvm dart run tool/ensure_native_stt.dart` in the agent folder.',
            });
          }
        default:
          // start/stop/cancel belong to the session that owns the lease.
          return;
      }
    } on SttException catch (error) {
      _logger.warning('dictation command failed: code=${error.code}');
      emit('dictation_error', {
        'code': error.code,
        'message': error.message,
      });
    } on Object catch (error) {
      emit('dictation_error', {
        'code': 'internal',
        'message': '$error',
      });
    }
  }

  Future<void> _install(
    String modelId, {
    required Object owner,
    required DictationEmit emit,
  }) async {
    if (_installing) {
      emit('dictation_error', {
        'code': 'install_in_progress',
        'message': 'another model install is running',
      });
      return;
    }
    _installing = true;
    _installCancelled = false;
    _installOwner = owner;
    _installingModelId = modelId;
    try {
      await _service.install(
        modelId,
        isCancelled: () => _installCancelled || !identical(_installOwner, owner),
        onProgress: (id, received, total) {
          emit('stt_download_progress', {
            'model_id': id,
            'received_bytes': received,
            'total_bytes': total,
          });
        },
      );
      emit('stt_status', _service.statusPayload());
    } finally {
      _installing = false;
      _installOwner = null;
      _installingModelId = null;
    }
  }
}

/// Readiness/installation/model-selection surface for local dictation.
///
/// `supports_dictation` is true when the device can run the runtime at all
/// (enabled in config, supported platform). Whether a model is installed is a
/// separate status flag, because the first mic press is what installs it.
class DictationService {
  DictationService({
    required this.sanadHome,
    SttEngine Function()? engineFactory,
    SttEngine Function(SttModelFiles files)? engineFor,
    HttpClient Function()? httpClient,
    bool? platformSupported,
    Future<void> Function()? runtimeInstaller,
    String? nativeRuntimeRoot,
    SttEngineAvailability availability = const SttEngineAvailability.build(),
  }) : _engineFactory = engineFactory ?? SherpaSttEngine.new,
       _engineFor = engineFor,
       _platformSupported = platformSupported ?? _nativeTargetSupported(),
       _runtimeInstaller = runtimeInstaller,
       _availability = availability,
       _nativeRoot = Directory(
         nativeRuntimeRoot ??
             '${File(Platform.resolvedExecutable).parent.path}/native',
       ) {
    _store = SttModelStore(httpClient: httpClient, sanadHome: sanadHome);
    _control = DictationControl(this);
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

  /// Overrides runtime selection for a resolved model. It exists so a channel
  /// test can exercise the real lease/start path without loading native code.
  final SttEngine Function(SttModelFiles files)? _engineFor;
  final bool _platformSupported;

  /// Which engines this build can run. Injected so both builds are testable.
  final SttEngineAvailability _availability;

  /// The engines this build can run.
  SttEngineAvailability get availability => _availability;

  /// Re-installs the packaged native runtime for a released Agent.
  ///
  /// The update layer owns the manifest and the executable path, so the retry is
  /// injected instead of duplicated here: a failed runtime install disables
  /// dictation only, and this is the path back. Null means the checkout has no
  /// packaged installer (a source run, which uses the developer tool instead).
  final Future<void> Function()? _runtimeInstaller;

  /// Directory the packaged installers write beside (`<exe dir>/native`).
  final Directory _nativeRoot;

  /// True while an injected runtime re-install is in flight, so readiness says
  /// "preparing" instead of repeating the failure it is retrying.
  bool _runtimeRetryInFlight = false;

  late final SttModelStore _store;
  late final DictationControl _control;
  late SttSettings _settings;
  SttException? _configError;

  SttModelStore get store => _store;
  SttSettings get settings => _settings;

  /// Shared catalog/install/selection/preparation surface for every channel.
  DictationControl get control => _control;

  /// Platform verdict from the single native target table.
  ///
  /// A second `Platform`/`Abi` catalog here is exactly the drift that made a
  /// buildable Intel runtime report `unsupported_platform`: the table owns which
  /// OS/architecture pairs can dictate, and this only consumes that answer. An
  /// unresolvable host is unsupported, never optimistically enabled.
  static bool _nativeTargetSupported() =>
      SttNativeTarget.tryCurrent()?.dictationSupported ?? false;

  SttReadiness readiness() {
    if (_configError != null) {
      // The parser message can carry YAML line context and English prose; the
      // event carries the stable code only.
      _logger.warning('dictation config invalid: ${_configError!.code}');
      return const SttReadiness.unavailable('config_invalid');
    }
    if (!_settings.enabled) {
      return const SttReadiness.unavailable('dictation_disabled');
    }
    if (!_platformSupported) {
      return const SttReadiness.unavailable('unsupported_platform');
    }
    // A build with no usable engine cannot dictate at all. It reports the same
    // stable code a device without dictation reports, because from the Client's
    // point of view there is nothing to start.
    if (defaultUsableSttEntry(_availability) == null) {
      return const SttReadiness.unavailable('dictation_unavailable');
    }
    // Whisper needs its native shim on disk. Report that as its own reason so a
    // fresh clone shows "run ensure_native_stt" instead of a generic failure.
    final entry = selectedEntry;
    if (entry != null &&
        entry.engine == SttEngineKind.whisperCpp &&
        !WhisperCppLibrary.isAvailable) {
      return SttReadiness.unavailable(
        _nativeRuntimeReason(),
        isSupported: true,
      );
    }
    return const SttReadiness.ready();
  }

  /// Why the native shim is not on disk, as a stable machine code.
  ///
  /// A recorded install failure is its own reason: "the packaged runtime could
  /// not be installed" is actionable (retry it), while "missing" reads like a
  /// fresh checkout that only needs the developer tool.
  String _nativeRuntimeReason() {
    if (_runtimeRetryInFlight || WhisperCppLibrary.isBeingPrepared) {
      return 'native_runtime_preparing';
    }
    final cause = NativeRuntimeInstall.read(_nativeRoot);
    if (cause != null) {
      _logger.warning('dictation runtime install failed: $cause');
      return NativeRuntimeInstall.readinessReason;
    }
    return 'native_runtime_missing';
  }

  /// Starts `tool/ensure_native_stt.dart` in the background.
  ///
  /// A source checkout builds the shim with the developer tool; a released Agent
  /// has no such tool and re-installs the verified release runtime instead. Both
  /// are non-blocking retries: the caller answers with status, and readiness
  /// reports `native_runtime_preparing` until the attempt settles.
  ///
  /// Returns false when this checkout can neither build nor re-install the
  /// runtime, so the caller reports the manual instruction instead of pretending
  /// a retry started.
  bool prepareNativeRuntime() {
    final workingDirectory = Directory.current.path;
    final tool = File('$workingDirectory/tool/ensure_native_stt.dart');
    if (tool.existsSync()) {
      final logFile = 'native/.stt-prepare.log';
      final command = 'fvm dart run tool/ensure_native_stt.dart >> $logFile 2>&1';
      try {
        unawaited(
          Process.start(
            Platform.isWindows ? 'cmd' : '/bin/sh',
            Platform.isWindows ? ['/c', command] : ['-c', command],
            workingDirectory: workingDirectory,
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
    final installer = _runtimeInstaller;
    if (installer == null) {
      _logger.warning('native dictation prepare unavailable: no installer');
      return false;
    }
    if (_runtimeRetryInFlight) {
      _logger.info('native dictation runtime re-install already running');
      return true;
    }
    _runtimeRetryInFlight = true;
    unawaited(_retryPackagedRuntime(installer));
    _logger.info('native dictation runtime re-install requested');
    return true;
  }

  Future<void> _retryPackagedRuntime(Future<void> Function() installer) async {
    try {
      await installer();
      final cause = NativeRuntimeInstall.read(_nativeRoot);
      if (cause == null) {
        _logger.info('native dictation runtime re-install succeeded');
      } else {
        _logger.warning('native dictation runtime re-install failed: $cause');
      }
    } on Object catch (error) {
      _logger.warning(
        'native dictation runtime re-install failed: ${error.runtimeType}',
      );
    } finally {
      _runtimeRetryInFlight = false;
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

  Future<void> _writeSelection(String modelId) async {
    final entry = sttEntryById(modelId);
    if (entry == null) {
      throw SttException('model_unknown', 'model "$modelId" is not in the catalog');
    }
    if (!_availability.supports(entry.engine)) {
      // The model sheet never offers such a row, so this only answers a stale
      // client or a hand-written command: say why instead of writing a selection
      // that the next session cannot load.
      throw SttException(
        'model_unavailable',
        'model "$modelId" needs the ${entry.engine.name} engine, which this '
            'build does not include',
      );
    }
    await _store.writeSelectionId(modelId);
  }

  /// Persists the selected model — the same owner the `select` command uses, so
  /// the model sheet and the Device settings page can never disagree.
  Future<void> selectModel(String modelId) async {
    await _writeSelection(modelId);
    await unloadWarmEngine();
  }

  /// Persists the Device settings dictation toggle.
  ///
  /// `config.yaml` owns the key when it names it explicitly; refusing is the
  /// truthful outcome, because the next reload would silently discard the
  /// write.
  Future<void> applyEnabled(bool enabled) async {
    if (_settings.enabledManagedByConfig) {
      throw SttException(
        'managed_externally',
        'stt.enabled is set in config.yaml',
      );
    }
    await SttRuntimePreferences.writeEnabled(
      sanadHome: sanadHome,
      enabled: enabled,
    );
    reloadSettings();
    if (!enabled) await unloadWarmEngine();
  }

  /// Explicit config beats a per-device selection, which beats the default.
  ///
  /// Every answer is filtered through this build's engine availability: a
  /// selection that names a model whose engine was not compiled in falls back to
  /// the default usable entry instead of failing at load time.
  String get selectedModelId {
    if (_settings.modelPath?.trim().isNotEmpty ?? false) return 'path-override';
    if (_settings.modelId.isNotEmpty) return _usableIdOrFallback(_settings.modelId);
    final selection = _store.readSelectionId();
    if (selection != null) {
      // A retired entry stays in the catalog so an old install still resolves
      // its files, but it must never remain the active choice: the 20M streaming
      // build is hidden precisely because it cannot transcribe a first word.
      final entry = sttEntryById(selection);
      if (entry != null && !entry.hidden && _availability.supports(entry.engine)) {
        return selection;
      }
    }
    return defaultUsableSttEntry(_availability)?.id ?? defaultSttEntry.id;
  }

  /// [id] when this build can run it, else the default usable entry.
  String _usableIdOrFallback(String id) {
    final entry = sttEntryById(id);
    if (entry != null && _availability.supports(entry.engine)) return id;
    return defaultUsableSttEntry(_availability)?.id ?? id;
  }

  SttCatalogEntry? get selectedEntry => sttEntryById(selectedModelId);

  /// True while a dictation session holds the engine. A second session is
  /// refused instead of loading a second copy of the model.
  bool get isBusy => _sessionOwner != null;

  /// The connection that currently owns the lease.
  ///
  /// Ownership is a token, not a counter: a status-only, refused, or busy
  /// channel closing must never free another channel's live session.
  Object? _sessionOwner;

  /// Takes the daemon-wide dictation lease for [owner].
  bool acquireSession(Object owner) {
    if (_sessionOwner != null) return false;
    _sessionOwner = owner;
    return true;
  }

  /// Releases the lease only when [owner] still holds it.
  void releaseSession(Object owner) {
    if (identical(_sessionOwner, owner)) _sessionOwner = null;
  }

  bool ownsSession(Object owner) => identical(_sessionOwner, owner);

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

  /// Directory the packaged sherpa libraries were installed into, or null.
  ///
  /// A released Agent ships them in `native/<tag>/sherpa/` beside the executable
  /// (see [SttNativeTarget.sherpaLibraries]); a source checkout has no such
  /// directory, so the engine resolves the library from the pub cache itself.
  /// The answer is computed, never cached: the runtime can be installed while
  /// the daemon is running.
  String? get sherpaNativeDirectory {
    if (!_availability.sherpa) return null;
    final target = SttNativeTarget.tryCurrent();
    if (target == null) return null;
    final directory = '${_nativeRoot.path}/${target.nativeDirectory}'
        '/${target.sherpaNativeSubdirectory}';
    final probe = target.sherpaLibraries.first;
    return File('$directory/$probe').existsSync() ? directory : null;
  }

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
        sherpaNativeDir: sherpaNativeDirectory,
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

  /// Catalog rows as the Client renders them.
  ///
  /// `label_code` carries a translatable identity for rows the daemon owns; the
  /// catalog `label` is a product name and is used verbatim. The daemon never
  /// ships user-facing sentences or non-English copy.
  List<Map<String, dynamic>> _modelRows({
    required String? installedOverrides,
    required bool overrideReady,
  }) {
    return [
      // An explicit `stt.model_path` is a ready model even though it is not a
      // catalog entry; without this row the UI offers the setup sheet.
      if (installedOverrides != null)
        {
          'id': 'path-override',
          'label_code': 'path_override',
          // The absolute override path never leaves this machine: the row's
          // identity is enough for every surface to describe it.
          'mode': SttModelMode.batchVad.name,
          'language': _settings.language,
          'total_bytes': 0,
          'hosted': false,
          'installed': overrideReady,
          'engine': SttEngineKind.whisperCpp.name,
        },
      for (final entry in usableSttEntries(_availability))
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
    ];
  }

  String? get _installedOverridePath {
    final overridePath = _settings.modelPath?.trim();
    return overridePath == null || overridePath.isEmpty ? null : overridePath;
  }

  Map<String, dynamic> statusPayload() {
    final readiness = this.readiness();
    final installedOverrides = _installedOverridePath;
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
      // Host filesystem layout is never part of a status payload. A local or
      // hosted reader only needs to know that an override exists.
      'has_model_path': installedOverrides != null,
      'models': _modelRows(
        installedOverrides: installedOverrides,
        overrideReady: overrideReady,
      ),
    };
  }

  /// Device settings projection of the dictation runtime.
  ///
  /// It reuses the same catalog rows and readiness as `stt_status` so the
  /// settings page can never describe a different state than the mic.
  Map<String, dynamic> settingsSnapshot() {
    final readiness = this.readiness();
    final installedOverrides = _installedOverridePath;
    return {
      'enabled': _settings.enabled,
      'managed_externally': _settings.enabledManagedByConfig,
      'selected_model_id': selectedModelId,
      'supported': readiness.isSupported,
      'ready': readiness.isReady,
      if (readiness.reason != null) 'reason': readiness.reason,
      'busy': isBusy,
      'has_model_path': installedOverrides != null,
      'models': _modelRows(
        installedOverrides: installedOverrides,
        overrideReady:
            installedOverrides != null && _resolveOverrideExists(),
      ),
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

  /// Handles one local dictation WebSocket for its whole lifetime.
  Future<void> handleSocket(WebSocket socket) =>
      handleChannel(WebSocketDictationChannel(socket));

  /// Handles one transport-neutral dictation channel.
  ///
  /// The local socket and the hosted relay differ only in framing; the session,
  /// lease, engine, and event vocabulary are this one implementation.
  Future<void> handleChannel(DictationChannel channel) {
    final connection = _DictationConnection(service: this, transport: channel);
    return connection.run();
  }

  SttEngine createEngine() => _engineFactory();

  /// Picks the runtime the resolved model asks for. A path override that points
  /// at a ggml file is treated as whisper.cpp, so a local trial needs no config.
  SttEngine createEngineFor(SttModelFiles files) {
    final override = _engineFor;
    if (override != null) return override(files);
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
  Future<void>? _startAttempt;
  bool _sessionReady = false;
  bool _starting = false;
  bool _closed = false;

  /// Bumped whenever this connection abandons the start it is waiting on, so a
  /// model load that finishes afterwards frees its recognizer instead of
  /// publishing a session nobody owns.
  int _startGeneration = 0;

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
    _sessionReady = false;
    // A publish or a model load in flight must observe the abandonment before
    // the lease is released; teardown waits for it so the engine is disposed
    // first and a new session never overlaps the old one.
    _startGeneration++;
    service.control.cancelInstall(this);
    await _commands?.cancel();
    _commands = null;
    await _audio?.cancel();
    _audio = null;
    final controller = _audioIn;
    _audioIn = null;
    final starting = _startAttempt;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // A failed start reports itself to its own channel.
      }
    }
    final session = _session;
    _session = null;
    if (session != null) await session.close();
    if (controller != null && !controller.isClosed) await controller.close();
    // Only the token this connection acquired is released: a status-only,
    // refused, or busy channel closing must never free a live session.
    service.releaseSession(this);
    await transport.close();
  }

  Future<void> _handleCommand(DictationMessage message) async {
    switch (message.command) {
      case DictationCommand.start:
        await _startSession();
      case DictationCommand.stop:
      case DictationCommand.cancel:
        // Owned by the active session; a cancel during a model load abandons
        // that load instead of letting it publish a session afterwards.
        if (message.command == DictationCommand.cancel) _startGeneration++;
        if (_session == null) {
          transport.send('stt_status', service.statusPayload());
        }
      case DictationCommand.status:
      case DictationCommand.install:
      case DictationCommand.select:
      case DictationCommand.prepareRuntime:
        await service.control.handle(
          message,
          owner: this,
          emit: transport.send,
        );
    }
  }

  Future<void> _startSession() async {
    // A client may repeat `start` (a double press, or a reconnect) while the
    // recognizer is still loading. The second command must be ignored, not
    // answered with `dictation_busy`, which would look like a stuck session.
    if (_session != null || _starting || _closed) return;
    _starting = true;
    final attempt = _startSessionOnce();
    _startAttempt = attempt;
    try {
      await attempt;
    } finally {
      _starting = false;
      if (identical(_startAttempt, attempt)) _startAttempt = null;
    }
  }

  Future<void> _startSessionOnce() async {
    if (_session != null || _closed) return;
    final generation = _startGeneration;
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
    if (!service.acquireSession(this)) {
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
      service.releaseSession(this);
      rethrow;
    }
    if (_closed || generation != _startGeneration) {
      // The channel closed (or cancelled) while the model was loading. Free the
      // recognizer instead of publishing an orphan session, and keep the lease
      // until it is gone.
      _logger.info('dictation start abandoned during load: model=${files.modelId}');
      await engine.dispose();
      service.releaseSession(this);
      return;
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
  int get droppedFrames => _inner.droppedFrames;

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
