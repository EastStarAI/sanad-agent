import 'dart:async';

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

  static const Duration _stopTimeout = Duration(seconds: 15);

  final DictationResolver _resolver;
  final DictationCapture _capture;
  final String Function() _sessionIdFactory;

  DictationTransport? _transport;
  DeviceConfig? _device;
  String? _sessionId;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  StreamSubscription<List<int>>? _audioSubscription;
  Timer? _stopTimer;
  bool _closing = false;

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
    emit(state.copyWith(status: DictationStatus.preparing, clearError: true));

    try {
      final transport = await _resolver.resolve(
        device: device,
        sessionId: _sessionId!,
      );
      _transport = transport;
      _eventSubscription = transport.events.listen(
        _handleEvent,
        onError: (Object error) => _fail('transport_error'),
        onDone: _onTransportClosed,
      );
      transport.sendCommand('start');
      emit(state.copyWith(status: DictationStatus.listening));
      await _startCapture(transport);
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
    final stream = await _capture.start();
    _audioSubscription = stream.listen(
      transport.sendAudio,
      onError: (Object _) => _fail('microphone_error'),
      cancelOnError: true,
    );
  }

  /// Stops capture, asks the daemon to drain, and keeps the finalized text.
  Future<void> stop() async {
    if (!state.isActive) return;
    emit(state.copyWith(status: DictationStatus.finalizing));
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _capture.stop();
    _transport?.sendCommand('stop');
    _stopTimer = Timer(_stopTimeout, () {
      _logger.warning('dictation stop timed out');
      unawaited(_reset(clearText: false));
    });
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
    transport.sendCommand('install', {'model_id': modelId});
  }

  /// Asks the daemon for the current status/catalog (used by the model sheet).
  Future<void> refreshStatus(DeviceConfig device) async {
    final transport = await _ensureTransport(device);
    transport?.sendCommand('status');
  }

  Future<void> selectModel(String modelId, {required DeviceConfig device}) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    transport.sendCommand('select', {'model_id': modelId});
  }

  Future<DictationTransport?> _ensureTransport(DeviceConfig device) async {
    final existing = _transport;
    if (existing != null && existing.isOpen) return existing;
    _device = device;
    _sessionId = _sessionIdFactory();
    try {
      final transport = await _resolver.resolve(
        device: device,
        sessionId: _sessionId!,
      );
      _transport = transport;
      _eventSubscription = transport.events.listen(
        _handleEvent,
        onError: (Object _) => _fail('transport_error'),
        onDone: _onTransportClosed,
      );
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

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['event']) {
      case 'stt_status':
        emit(state.copyWith(model: _modelFromStatus(event)));
      case 'stt_download_progress':
        final received = (event['received_bytes'] as num?)?.toInt() ?? 0;
        final total = (event['total_bytes'] as num?)?.toInt() ?? 0;
        emit(
          state.copyWith(
            model: state.model.copyWith(
              downloadProgress: total <= 0 ? null : (received / total).clamp(0, 1),
            ),
          ),
        );
      case 'dictation_ready':
        emit(state.copyWith(model: state.model.copyWith(isReady: true)));
      case 'dictation_partial':
        final text = (event['text'] as String?) ?? '';
        emit(
          state.copyWith(
            partialText:
                state.previewPolicy == DictationPreviewPolicy.live ? text : '',
          ),
        );
      case 'dictation_final':
        final text = (event['text'] as String?) ?? '';
        final committed = _appendSegment(state.committedText, text);
        emit(state.copyWith(committedText: committed, partialText: ''));
      case 'dictation_done':
        _logger.info('dictation drained: segments=${event['segments']}');
        unawaited(_reset(clearText: false));
      case 'dictation_error':
        _fail((event['code'] as String?) ?? 'dictation_error');
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

  static String _appendSegment(String committed, String segment) {
    if (segment.isEmpty) return committed;
    if (committed.isEmpty) return segment;
    final needsSpace = !committed.endsWith(' ') && !committed.endsWith('\n');
    return needsSpace ? '$committed $segment' : '$committed$segment';
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
        committedText: clearText ? '' : state.committedText,
        partialText: '',
        errorCode: errorCode,
        clearError: errorCode == null,
        sessionNeedsFirstUseSheet: errorCode == 'model_not_installed',
      ),
    );
    _closing = false;
    if (device != null) _logger.info('dictation session closed');
  }

  @override
  Future<void> close() async {
    _closing = true;
    _stopTimer?.cancel();
    await _audioSubscription?.cancel();
    await _capture.dispose();
    await _eventSubscription?.cancel();
    await _transport?.close();
    return super.close();
  }
}
