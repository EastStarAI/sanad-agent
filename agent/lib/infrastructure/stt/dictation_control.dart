/// Catalog, install, selection, and preparation commands — one surface, two
/// channels, so local and hosted behavior cannot diverge.
///
/// These commands are stateless: they create no per-`dictation_id` context. The
/// **install** is the one exception, and deliberately so: it is daemon-scoped,
/// owned by [DictationControl] rather than by the connection that asked for it,
/// and therefore survives a sheet close, a device switch, and a reconnect.
/// Progress and the terminal answer stream to **every channel attached to the
/// device**, not only to the one that pressed the button: a client that arrives
/// mid-download asks for status, attaches, and stays truthful from there. A
/// channel that leaves detaches and never cancels.
///
/// The terminal `stt_status` is emitted **after** the install stops being truth,
/// because it is the event that tells a client the row is finished. A terminal
/// answer built while the install is still active carries `install` again, and
/// the row it unfreezes is exactly the one it froze.
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
    _installs = SttInstallControl(
      runner: _runInstall,
      // The terminal status is published here, not by an observer: by the time
      // this runs the install has been released, so the payload says `install`
      // is absent and every client clears its row.
      onSettled: _publishInstallSettled,
    );
  }

  final DictationControlHost _service;
  final Logger _logger = Logger('DictationControl');

  late final SttInstallControl _installs;

  /// One attachment per **channel**, so a repeat command replaces its own
  /// observer instead of adding a second one and the map never grows with
  /// command count. Cleared when the install settles.
  final Map<Object, _InstallChannel> _installChannels =
      <Object, _InstallChannel>{};

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
    _installChannels.remove(channel)?.lease?.detach();
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
          // A channel that asks while an install runs observes it from here on,
          // so a client that joined late — a restart, a second device, a sheet
          // reopened after a reconnect — keeps receiving progress and the
          // terminal answer instead of one stale snapshot.
          _observeInstall(installChannel ?? owner, emit);
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
    final target = _InstallTarget(emit);
    final lease = _installs.start(
      modelId,
      observer: _ChannelInstallObserver(target),
    );
    if (lease == null) {
      // A different model is installing. The running download is the device's
      // own truth, so the refused channel is told what is running *and* attached
      // to it: its row then ends with that install instead of freezing on the
      // refusal.
      _observeInstall(channel, emit);
      _logger.info('dictation model install refused: install_in_progress');
      emit('dictation_error', {
        'code': 'install_in_progress',
        'message': 'another model install is running',
      });
      emit('stt_status', _service.statusPayload());
      return;
    }
    _installChannels.remove(channel)?.lease?.detach();
    _installChannels[channel] = _InstallChannel(target)..lease = lease;
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

  /// Attaches [channel] to the install in flight, if there is one.
  void _observeInstall(Object channel, DictationEmit emit) {
    final existing = _installChannels[channel];
    if (existing != null) {
      // A hosted channel's emit closure is bound to one operation, so a later
      // command refreshes the target instead of adding a second attachment.
      existing.target.emit = emit;
      return;
    }
    final target = _InstallTarget(emit);
    final lease = _installs.attach(
      observer: _ChannelInstallObserver(target),
    );
    if (lease == null) return;
    _installChannels[channel] = _InstallChannel(target)..lease = lease;
  }

  /// The daemon's terminal answer, published once the install is released.
  ///
  /// One payload for every attached channel: the install truth is the device's,
  /// so no channel is told a different ending.
  void _publishInstallSettled(SttInstallOutcome outcome) {
    if (_installChannels.isEmpty) return;
    final channels = _installChannels.values.toList(growable: false);
    _installChannels.clear();
    final payload = _service.statusPayload();
    for (final channel in channels) {
      try {
        channel.target.emit('stt_status', payload);
      } on Object {
        // A channel that died between the settle and this line has nothing left
        // to receive; the install itself is already over.
      }
    }
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

/// Mutable emit target of one channel.
///
/// The observer holds the target, not a closure, so a hosted channel's next
/// operation replaces its destination without replacing its attachment.
class _InstallTarget {
  _InstallTarget(this.emit);

  DictationEmit emit;
}

/// One channel's attachment to the install in flight.
class _InstallChannel {
  _InstallChannel(this.target);

  final _InstallTarget target;
  SttInstallLease? lease;
}

/// Maps one install's ticks onto wire events for one channel.
class _ChannelInstallObserver implements SttInstallObserver {
  _ChannelInstallObserver(this.channel);

  final _InstallTarget channel;

  @override
  void onInstallProgress(SttInstallState state) {
    channel.emit('stt_download_progress', {
      'model_id': state.modelId,
      'received_bytes': state.receivedBytes,
      'total_bytes': state.totalBytes,
      'phase': state.phase.name,
      'bytes_per_second': state.bytesPerSecond,
    });
  }

  @override
  void onInstallSettled(SttInstallOutcome outcome) {
    // The status is not this observer's: it belongs to the control, which emits
    // it after the install is released (see `_publishInstallSettled`). Emitting
    // it here built it while the install was still active, so it carried
    // `install` again and the row never cleared.
    final error = outcome.error;
    if (error == null || outcome.cancelled) {
      // A requested cancel is not a failure, and reporting it as one makes a
      // client tear down the very connection that must ask for status next.
      return;
    }
    channel.emit('dictation_error', {
      'code': error.code,
      'message': error.message,
    });
  }
}
