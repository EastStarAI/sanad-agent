/// Catalog, install, selection, and preparation commands — one surface, two
/// channels, so local and hosted behavior cannot diverge.
///
/// These commands are stateless: they create no per-`dictation_id` context. The
/// **install** is the one exception, and deliberately so: it is daemon-scoped,
/// owned by [DictationControl] rather than by the connection that asked for it,
/// and therefore survives a sheet close, a device switch, and a reconnect.
/// Progress streams to whichever channels are attached; a channel that leaves
/// detaches and never cancels.
///
/// Session commands (`start`, `stop`, `cancel`) stay with `DictationSession` and
/// its single dictation lease.
library;

import 'package:logging/logging.dart';

import 'dictation_session.dart';
import 'stt_install_control.dart';
import 'stt_model_store.dart';
import 'stt_types.dart';

typedef DictationEmit = void Function(String event, Map<String, dynamic> payload);

/// What the control surface needs from the dictation service.
///
/// An interface rather than the concrete service, so the install owner can be
/// exercised — single writer, coalesced ticks, join, cancel — without a daemon,
/// a socket, or a real download.
abstract class DictationControlHost {
  String get selectedModelId;

  Map<String, dynamic> statusPayload();

  Future<void> install(
    String modelId, {
    SttProgressCallback? onProgress,
    void Function(SttInstallPhase phase)? onPhase,
    bool Function()? isCancelled,
  });

  Future<void> selectModel(String modelId);

  bool prepareNativeRuntime();
}

class DictationControl {
  DictationControl(this._service) {
    _installs = SttInstallControl(runner: _runInstall);
  }

  final DictationControlHost _service;
  final Logger _logger = Logger('DictationControl');

  late final SttInstallControl _installs;

  /// One attachment per **channel**, so a repeat command replaces its own
  /// observer instead of adding a second one and the map never grows with
  /// command count.
  final Map<Object, SttInstallLease> _installLeases =
      <Object, SttInstallLease>{};

  bool get isInstalling => _installs.isRunning;

  String? get installingModelId => _installs.modelId;

  /// The in-flight install truth, or null.
  SttInstallState? get installState => _installs.state;

  /// `stt_status.install`: what any client rebuilds its bar from.
  Map<String, dynamic>? get installPayload => _installs.state?.toWire();

  /// Stops sending install progress to [channel]; the install keeps running.
  ///
  /// This is the whole difference between a connection-scoped and a
  /// daemon-scoped install: teardown detaches, and only [cancelInstall] stops.
  void detachInstallChannel(Object channel) {
    _installLeases.remove(channel)?.detach();
  }

  /// Explicit cancel command. It is the only thing that stops an install.
  void cancelInstall() {
    if (!_installs.isRunning) return;
    _logger.info('dictation model install cancelled: model=${_installs.modelId}');
    _installs.cancel();
  }

  /// Runs one stateless command, reporting every outcome through [emit].
  ///
  /// [installChannel] identifies the channel for install progress and defaults
  /// to [owner]. The hosted relay passes itself, because its dispatch owner is
  /// one operation while the channel that must keep receiving progress is the
  /// relay.
  Future<void> handle(
    DictationMessage message, {
    required Object owner,
    required DictationEmit emit,
    Object? installChannel,
  }) async {
    try {
      switch (message.command) {
        case DictationCommand.status:
          emit('stt_status', _service.statusPayload());
        case DictationCommand.install:
          await _install(
            message.modelId ?? _service.selectedModelId,
            channel: installChannel ?? owner,
            emit: emit,
          );
        case DictationCommand.cancelInstall:
          cancelInstall();
          emit('stt_status', _service.statusPayload());
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
      _logger.warning('dictation command failed: ${error.runtimeType}');
      emit('dictation_error', {
        'code': 'internal',
        'message': '$error',
      });
    }
  }

  Future<void> _install(
    String modelId, {
    required Object channel,
    required DictationEmit emit,
  }) async {
    final lease = _installs.start(
      modelId,
      observer: _ChannelInstallObserver(emit: emit, host: _service),
    );
    if (lease == null) {
      // A different model is installing. The running download is the device's
      // own truth, so the refused channel is told what is running instead of
      // being left with a stale projection.
      _logger.info('dictation model install refused: install_in_progress');
      emit('dictation_error', {
        'code': 'install_in_progress',
        'message': 'another model install is running',
      });
      emit('stt_status', _service.statusPayload());
      return;
    }
    _installLeases.remove(channel)?.detach();
    _installLeases[channel] = lease;
    if (lease.joined) {
      // This command asked for the model that is already downloading: join it,
      // answer with its truth, and never start a second writer.
      _logger.info('dictation model install joined: model=$modelId');
      emit('stt_status', _service.statusPayload());
      return;
    }
    _logger.info('dictation model install started: model=$modelId');
    // The command completes with the install, exactly as it did when the install
    // was connection-scoped; the channel is free to leave before that.
    await lease.done;
  }

  Future<void> _runInstall(
    String modelId, {
    required void Function(int received, int total) onProgress,
    required void Function(SttInstallPhase phase) onPhase,
    required bool Function() isCancelled,
  }) => _service.install(
    modelId,
    onProgress: (_, received, total) => onProgress(received, total),
    onPhase: onPhase,
    isCancelled: isCancelled,
  );
}

/// Maps one install's ticks onto wire events for one channel.
class _ChannelInstallObserver implements SttInstallObserver {
  _ChannelInstallObserver({required this.emit, required this.host});

  final DictationEmit emit;
  final DictationControlHost host;

  @override
  void onInstallProgress(SttInstallState state) {
    emit('stt_download_progress', {
      'model_id': state.modelId,
      'received_bytes': state.receivedBytes,
      'total_bytes': state.totalBytes,
      'phase': state.phase.name,
      'bytes_per_second': state.bytesPerSecond,
    });
  }

  @override
  void onInstallSettled(SttInstallOutcome outcome) {
    // The status is always the terminal event: `install` is absent from it once
    // nothing is in flight, which is how a client knows the bar is finished.
    emit('stt_status', host.statusPayload());
    final error = outcome.error;
    if (error == null || outcome.cancelled) {
      // A requested cancel is not a failure, and reporting it as one makes a
      // client tear down the very connection that must ask for status next.
      return;
    }
    emit('dictation_error', {
      'code': error.code,
      'message': error.message,
    });
  }
}
