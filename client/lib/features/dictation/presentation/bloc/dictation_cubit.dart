import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import 'dictation_state.dart';

/// Drives one dictation session against the daemon.
///
/// Ownership: capture + transport plumbing only. Transcription happens in the
/// daemon; this cubit never fabricates or edits transcript text, and it logs
/// counts and codes, never audio or transcript content.
class DictationCubit extends Cubit<DictationState> {
  DictationCubit({
    required DictationResolver resolver,
    required DictationCapture capture,
    DictationPreviewPolicy previewPolicy = DictationPreviewPolicy.live,
    String Function()? sessionIdFactory,
  })  : _resolver = resolver,
        _capture = capture,
        _sessionIdFactory = sessionIdFactory ?? _timestampSessionId,
        super(DictationState(previewPolicy: previewPolicy));

  static final _logger = Logger('DictationCubit');

  static const Duration _stopTimeout = Duration(seconds: 240);

  final DictationResolver _resolver;
  final DictationCapture _capture;
  final String Function() _sessionIdFactory;

  DictationTransport? _transport;
  DeviceConfig? _device;
  String? _sessionId;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  DictationTransport? _eventTransport;
  StreamSubscription<List<int>>? _audioSubscription;
  Timer? _stopTimer;
  final Stopwatch _clock = Stopwatch();
  bool _closing = false;
  bool _limitReached = false;
  bool _capturing = false;
  int _lastLevelMs = 0;
  double _lastLevel = 0;

  /// Metadata counters for the audio path: the level bars prove frames are
  /// captured, these prove whether the same frames left the client.
  int _sentChunks = 0;

  /// Completes when the recorder's own stream is done, so stop() can wait for
  /// the last frames to reach the daemon before asking it to decode.
  Completer<void>? _captureDrained;

  Completer<void>? _statusCompleter;
  Completer<void>? _idle;

  /// Ceiling for one utterance: five minutes of audio is held in the daemon
  /// until the user stops, so the cap is a real memory bound, not a UX hint.
  static const Duration sessionLimit = Duration(minutes: 5);

  static String _timestampSessionId() =>
      'dict-${DateTime.now().millisecondsSinceEpoch}';

  void setPreviewPolicy(DictationPreviewPolicy policy) {
    if (state.previewPolicy == policy) return;
    emit(state.copyWith(previewPolicy: policy));
  }

  Future<void> start(DeviceConfig device) async {
    if (state.isActive || _device != null) return;
    _device = device;
    _sessionId = _sessionIdFactory();
    _closing = false;
    emit(
      state.copyWith(
        status: DictationStatus.preparing,
        clearError: true,
        committedText: '',
        partialText: '',
        discardText: false,
      ),
    );

    try {
      final transport = await _resolver.resolve(
        device: device,
        sessionId: _sessionId!,
      );
      _transport = transport;
      _attachEvents(transport);
      _capturing = false;
      transport.sendCommand('start');
      // Capture waits for `dictation_ready`: the daemon drops audio that
      // arrives before the recognizer exists, so speaking during the load
      // would silently lose the first words.
      _clock..reset()..start();
    } on DictationTransportUnavailable catch (error) {
      _logger.info('dictation transport unavailable: ${error.reason}');
      await _reset(clearText: true, errorCode: error.reason);
    } on DictationMicrophoneDenied {
      await _reset(clearText: true, errorCode: 'microphone_denied');
    } on Object catch (error) {
      _logger.warning('dictation start failed: ${error.runtimeType}');
      await _reset(clearText: true, errorCode: 'start_failed');
    }
  }

  Future<void> _startCapture(DictationTransport transport) async {
    if (_capturing) return;
    _capturing = true;
    _captureDrained = Completer<void>();
    _sentChunks = 0;
    final stream = await _capture.start();
    _audioSubscription = stream.listen(
      (chunk) {
        // The cap is measured on the audio path, so it needs no timer: a
        // session that sends no audio can grow nothing.
        if (_clock.elapsed > sessionLimit) {
          unawaited(stopForLimit());
          return;
        }
        _sentChunks++;
        if (_sentChunks == 1) {
          _logger.info(
            'dictation audio out: first chunk bytes=${chunk.length} '
            'open=${transport.isOpen}',
          );
        }
        transport.sendAudio(chunk);
        _publishLevel(chunk);
      },
      onError: (Object _) => _fail('microphone_error'),
      // The recorder closes this stream when it stops, which is the signal that
      // the last frames have been handed over.
      onDone: () {
        final drained = _captureDrained;
        if (drained != null && !drained.isCompleted) drained.complete();
      },
      cancelOnError: true,
    );
  }

  /// Publishes loudness for the visualization, at most sixteen times a second.
  void _publishLevel(List<int> chunk) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLevelMs < 60) return;
    _lastLevelMs = now;
    if (chunk.length < 2) return;
    var sum = 0.0;
    final count = chunk.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final sample = (chunk[i * 2] | (chunk[i * 2 + 1] << 8)).toSigned(16);
      final value = sample / 32768.0;
      sum += value * value;
    }
    final meanSquare = count == 0 ? 0.0 : (sum / count).abs();
    final rms = math.sqrt(meanSquare);
    // A room's noise floor sits around -55 dBFS on this microphone and speech
    // starts around -50, so everything below -50 is gated out and the meter
    // spans -50..-25 dB: idle silence stays flat, speech fills it.
    final db = 20 * (math.log(rms <= 1e-8 ? 1e-8 : rms) / math.ln10);
    final instant = ((db + 50) / 25).clamp(0.0, 1.0);
    // Fast attack, slow release: the bars jump with a syllable and settle
    // instead of flickering on every noise sample.
    final level = instant >= _lastLevel
        ? instant
        : (_lastLevel * 0.55) + (instant * 0.45);
    _lastLevel = level;
    if (!isClosed) emit(state.copyWith(level: level.toDouble()));
  }

  /// Stops capture, asks the daemon to drain, and keeps the finalized text.
  ///
  /// Order matters: the recorder is stopped *first* and its stream is allowed
  /// to close, so the frames the user just spoke still reach the daemon before
  /// the stop command tells it to decode.
  Future<void> stop() async {
    if (!state.isActive) return;
    _lastLevel = 0;
    emit(state.copyWith(status: DictationStatus.finalizing, level: 0));
    _capturing = false;
    await _capture.stop();
    final drained = _captureDrained;
    if (drained != null) {
      await drained.future.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {},
      );
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    _transport?.sendCommand('stop');
    _stopTimer = Timer(_stopTimeout, () {
      _logger.warning('dictation stop timed out');
      unawaited(_reset(clearText: false));
    });
  }

  /// Stops the session and completes once the transcript has landed.
  ///
  /// The send path uses this: dispatching while the daemon is still decoding
  /// would post the text that existed *before* the user spoke.
  Future<void> stopAndWait({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!state.isActive) return;
    final idle = _idle ??= Completer<void>();
    await stop();
    await idle.future.timeout(timeout, onTimeout: () {});
  }

  /// Stops the session because the client-side cap was reached.
  Future<void> stopForLimit() async {
    if (!state.isActive) return;
    _limitReached = true;
    await stop();
  }

  /// Abandons the session and drops everything it produced.
  Future<void> cancel() async {
    if (!state.isActive) return;
    _transport?.sendCommand('cancel');
    await _reset(clearText: true);
  }

  /// Starts (or retries) the model download and reports progress.
  Future<void> installModel(String modelId, {required DeviceConfig device}) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    emit(
      state.copyWith(
        model: state.model.copyWith(
          installingModelId: modelId,
          downloadProgress: 0,
        ),
        clearError: true,
      ),
    );
    transport.sendCommand('install', {'model_id': modelId});
  }

  /// Asks the daemon for the current status/catalog and waits for the reply.
  ///
  /// The reply is what tells the caller whether a model is installed, so the
  /// button decides "start recording vs open the sheet" from fresh data rather
  /// than from an empty state; the wait is bounded.
  Future<void> refreshStatus(
    DeviceConfig device, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    final completer = Completer<void>();
    _statusCompleter = completer;
    transport.sendCommand('status');
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _logger.info('dictation status reply timed out');
    } finally {
      if (identical(_statusCompleter, completer)) _statusCompleter = null;
    }
  }

  Future<void> selectModel(String modelId, {required DeviceConfig device}) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    transport.sendCommand('select', {'model_id': modelId});
  }

  Future<DictationTransport?> _ensureTransport(DeviceConfig device) async {
    final existing = _transport;
    if (existing != null && existing.isOpen) return existing;
    _sessionId = _sessionIdFactory();
    try {
      final transport = await _resolver.resolve(
        device: device,
        sessionId: _sessionId!,
      );
      _transport = transport;
      _attachEvents(transport);
      return transport;
    } on DictationTransportUnavailable catch (error) {
      emit(state.copyWith(errorCode: error.reason));
      return null;
    } on Object catch (error) {
      _logger.warning('dictation connect failed: ${error.runtimeType}');
      emit(state.copyWith(errorCode: 'connect_failed'));
      return null;
    }
  }

  /// Listens to the transport exactly once: status refreshes and a later
  /// session share one connection, so re-listening would double every event
  /// (and duplicate transcript text).
  void _attachEvents(DictationTransport transport) {
    if (identical(_eventTransport, transport) && _eventSubscription != null) {
      return;
    }
    unawaited(_eventSubscription?.cancel());
    _eventTransport = transport;
    _eventSubscription = transport.events.listen(
      _handleEvent,
      onError: (Object error) => _fail('transport_error'),
      onDone: _onTransportClosed,
    );
  }

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['event']) {
      case 'stt_status':
        _statusCompleter?.complete();
        final status = _modelFromStatus(event);
        final installing = state.model.installingModelId;
        final finished = installing != null &&
            status.models.any((m) => m.id == installing && m.installed);
        emit(
          state.copyWith(
            model: status.copyWith(
              clearInstallingModel: finished,
              clearDownloadProgress: finished,
            ),
          ),
        );
      case 'stt_download_progress':
        final received = (event['received_bytes'] as num?)?.toInt() ?? 0;
        final total = (event['total_bytes'] as num?)?.toInt() ?? 0;
        emit(
          state.copyWith(
            model: state.model.copyWith(
              installingModelId: event['model_id'] as String?,
              downloadProgress: total <= 0 ? null : (received / total).clamp(0, 1),
            ),
          ),
        );
      case 'dictation_ready':
        emit(
          state.copyWith(
            model: state.model.copyWith(isReady: true),
            // The recognizer exists now, so the user can speak. Until this
            // event the mic shows a loading affordance.
            status: state.status == DictationStatus.preparing
                ? DictationStatus.listening
                : state.status,
          ),
        );
        final transport = _transport;
        if (transport != null && state.status == DictationStatus.listening) {
          unawaited(_startCapture(transport));
        }
      case 'dictation_partial':
        final text = (event['text'] as String?) ?? '';
        emit(
          state.copyWith(
            partialText:
                state.previewPolicy == DictationPreviewPolicy.live ? text : '',
          ),
        );
      case 'dictation_final':
        // A batch model sends one final for the whole utterance, while a
        // streaming model sends one per silence-closed segment. Appending covers
        // both: later segments extend the transcript instead of wiping it.
        final text = ((event['text'] as String?) ?? '').trim();
        final committed = state.committedText.trim();
        final merged = text.isEmpty
            ? committed
            : committed.isEmpty
            ? text
            : '$committed $text';
        emit(state.copyWith(committedText: merged, partialText: ''));
      case 'dictation_done':
        final segments = (event['segments'] as num?)?.toInt() ?? 0;
        _logger.info('dictation drained: segments=$segments');
        final noSpeech = segments == 0 && state.committedText.isEmpty;
        unawaited(
          _reset(
            clearText: false,
            errorCode: noSpeech ? 'no_speech' : null,
          ),
        );
      case 'dictation_error':
        final code = (event['code'] as String?) ?? 'dictation_error';
        if (state.model.installingModelId != null) {
          emit(
            state.copyWith(
              model: state.model.copyWith(clearInstallingModel: true),
            ),
          );
        }
        _fail(code);
      default:
        break;
    }
  }

  static DictationModelStatus _modelFromStatus(Map<String, dynamic> event) {
    final selected = event['selected'] as String?;
    final supported = event['supported'] != false;
    final rawModels = event['models'];
    final candidates = rawModels is List ? rawModels : const [];
    final models = <DictationModelOption>[];
    for (final entry in candidates) {
      if (entry is! Map) continue;
      models.add(
        DictationModelOption(
          id: (entry['id'] as String?) ?? '',
          label: (entry['label'] as String?) ?? '',
          note: entry['note'] as String?,
          totalBytes: (entry['total_bytes'] as num?)?.toInt(),
          hosted: entry['hosted'] == true,
          installed: entry['installed'] == true,
          mode: entry['mode'] == 'streaming'
              ? DictationModelMode.streaming
              : DictationModelMode.batch,
        ),
      );
    }
    final selectedEntry = models.where((m) => m.id == selected).firstOrNull;
    return DictationModelStatus(
      selectedModelId: selected,
      isReady: selectedEntry?.installed ?? false,
      installedBytes: selectedEntry?.totalBytes,
      unavailableReason: supported ? null : (event['reason'] as String?),
      models: models,
    );
  }

  void _fail(String code) {
    _logger.info('dictation error code=$code');
    unawaited(_reset(clearText: code == 'model_not_installed', errorCode: code));
  }

  void _onTransportClosed() {
    if (_closing) return;
    unawaited(_reset(clearText: false));
  }

  Future<void> _reset({required bool clearText, String? errorCode}) async {
    if (_closing) return;
    _closing = true;
    _clock.stop();
    _lastLevel = 0;
    _capturing = false;
    final limitReached = _limitReached;
    _limitReached = false;
    _stopTimer?.cancel();
    _stopTimer = null;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _capture.stop();
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _transport?.close();
    _transport = null;
    final device = _device;
    _device = null;
    _sessionId = null;
    emit(
      state.copyWith(
        status: DictationStatus.idle,
        // The dictated text belongs to one session and was already inserted
        // into the composer; keeping it here would duplicate it next time.
        committedText: '',
        partialText: '',
        discardText: clearText,
        level: 0,
        errorCode: errorCode ?? (limitReached ? 'session_limit' : null),
        clearError: errorCode == null && !limitReached,
        sessionNeedsFirstUseSheet: errorCode == 'model_not_installed',
      ),
    );
    _closing = false;
    if (device != null) _logger.info('dictation session closed');
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  @override
  Future<void> close() async {
    _closing = true;
    _stopTimer?.cancel();
    _clock.stop();
    await _audioSubscription?.cancel();
    await _capture.dispose();
    await _eventSubscription?.cancel();
    await _transport?.close();
    return super.close();
  }
}
