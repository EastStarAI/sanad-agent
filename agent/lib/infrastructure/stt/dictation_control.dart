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

  /// What [install] would continue from, and the total it will report.
  ///
  /// A resumed install knows both before the first network frame; publishing the
  /// projection without them states `received_bytes: 0` for a partial the daemon
  /// already holds.
  ({int received, int total})? installSeed(String modelId);

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

  /// Every channel that has spoken to this control surface.
  ///
  /// Kept after its command returns — one entry per connection, removed on
  /// detach — so an install that **starts** can be announced to a client whose
  /// sheet is already open instead of waiting for it to ask again. Before that,
  /// only the channel that pressed Download learned about the start, and every
  /// other open sheet stayed blank until it was reopened.
  final Map<Object, _InstallTarget> _channels = <Object, _InstallTarget>{};

  /// The channels currently observing the install in flight (progress + settle).
  final Map<Object, SttInstallLease> _observers = <Object, SttInstallLease>{};

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
    _observers.remove(channel)?.detach();
    _channels.remove(channel);
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
    final channel = installChannel ?? owner;
    // Registration is what makes a later install visible on a sheet that is
    // already open: the announcement goes to every channel that has spoken here,
    // not only to the one that presses Download.
    _channelTarget(channel, emit);
    try {
      switch (message.command) {
        case DictationCommand.status:
          // A channel that asks while an install runs observes it from here on,
          // so a client that joined late — a restart, a second device, a sheet
          // reopened after a reconnect — keeps receiving progress and the
          // terminal answer instead of one stale snapshot.
          _observeInstall(channel, emit);
          emit('stt_status', _service.statusPayload());
        case DictationCommand.install:
          await _install(
            message.modelId ?? _service.selectedModelId,
            channel: channel,
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
    final target = _channelTarget(channel, emit);
    // What is already on disk is part of the install from its first moment: the
    // projection is published before the first HTTP response, and a zero there
    // restarted a resumed bar at 0 % for a second.
    final seed = _service.installSeed(modelId);
    final lease = _installs.start(
      modelId,
      observer: _ChannelInstallObserver(target),
      seedReceived: seed?.received ?? 0,
      seedTotal: seed?.total ?? 0,
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
    _observers.remove(channel)?.detach();
    _observers[channel] = lease;
    if (lease.joined) {
      // This command asked for the model that is already downloading: join it,
      // answer with its truth, and never start a second writer.
      _logger.info('dictation model install joined: model=$modelId');
      emit('stt_status', _service.statusPayload());
      return;
    }
    _logger.info('dictation model install started: model=$modelId');
    // Every channel learns that it started **and** follows it from here: a sheet
    // that was already open has no other way to learn about a download another
    // client pressed, and a snapshot alone would leave its bar frozen.
    _attachAllChannels();
    _broadcast('stt_status', _service.statusPayload());
    // The command completes with the install, exactly as it did when the install
    // was connection-scoped; the channel is free to leave before that.
    await lease.done;
  }

  /// The target for [channel], refreshed with the emit of the current command.
  ///
  /// A hosted channel's emit closure is bound to one operation, so a later
  /// command replaces the destination without replacing the attachment.
  _InstallTarget _channelTarget(Object channel, DictationEmit emit) =>
      _channels.putIfAbsent(channel, () => _InstallTarget(emit))..emit = emit;

  /// Attaches every known channel to the install that just started.
  void _attachAllChannels() {
    for (final entry in _channels.entries.toList(growable: false)) {
      if (_observers.containsKey(entry.key)) continue;
      final lease = _installs.attach(
        observer: _ChannelInstallObserver(entry.value),
      );
      if (lease != null) _observers[entry.key] = lease;
    }
  }

  /// Attaches [channel] to the install in flight, if there is one.
  void _observeInstall(Object channel, DictationEmit emit) {
    final target = _channelTarget(channel, emit);
    if (_observers.containsKey(channel)) return;
    final lease = _installs.attach(
      observer: _ChannelInstallObserver(target),
    );
    if (lease == null) return;
    _observers[channel] = lease;
  }

  /// Sends one event to every channel that has spoken to this control surface.
  void _broadcast(String event, Map<String, dynamic> payload) {
    if (_channels.isEmpty) return;
    for (final target in _channels.values.toList(growable: false)) {
      try {
        target.emit(event, payload);
      } on Object {
        // A channel that died between the command and this line has nothing left
        // to receive; the install itself is unaffected.
      }
    }
  }

  /// The daemon's terminal answer, published once the install is released.
  ///
  /// One payload for every attached channel: the install truth is the device's,
  /// so no channel is told a different ending.
  void _publishInstallSettled(SttInstallOutcome outcome) {
    _observers.clear();
    if (_channels.isEmpty) return;
    _broadcast('stt_status', _service.statusPayload());
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
