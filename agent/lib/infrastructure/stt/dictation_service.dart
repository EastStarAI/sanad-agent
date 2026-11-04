/// Dictation service: readiness, model catalog control, and socket sessions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

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

  Map<String, dynamic> statusPayload() {
    final readiness = this.readiness();
    final installedOverrides = _settings.modelPath?.trim();
    return {
      'supported': readiness.isSupported,
      if (readiness.reason != null) 'reason': readiness.reason,
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

  void _applySettingsFromDisk() => reloadSettings();
}

class _DictationConnection {
  _DictationConnection({required this.service, required this.transport});

  final DictationService service;
  final DictationChannel transport;
  final Logger _logger = Logger('DictationConnection');

  DictationSession? _session;
  StreamSubscription<DictationMessage>? _commands;
  bool _installing = false;
  bool _installCancelled = false;
  bool _closed = false;

  Future<void> run() async {
    transport.send('stt_status', service.statusPayload());
    _commands = transport.commands.listen((message) {
      unawaited(_handleCommand(message));
    });
    // The socket stays open until the peer closes it; the audio stream done
    // event triggers teardown through the session.
    await transport.audio.drain<void>().catchError((Object _) {});
    await _teardown();
  }

  Future<void> _teardown() async {
    if (_closed) return;
    _closed = true;
    _installCancelled = true;
    await _commands?.cancel();
    _commands = null;
    await _session?.close();
    _session = null;
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
    final files = service.store.resolve(service.settings);
    if (files == null) {
      transport.send('dictation_error', {
        'code': 'model_not_installed',
        'message': 'install a dictation model first',
      });
      return;
    }
    final engine = service.createEngine();
    await engine.start(
      files,
      modelId: files.modelId,
      threads: service.settings.threads,
    );
    final session = DictationSession(
      transport: transport,
      engine: engine,
      modelId: files.modelId,
    );
    _session = session;
    await session.start();
    _logger.info('dictation session started: model=${files.modelId}');
  }
}
