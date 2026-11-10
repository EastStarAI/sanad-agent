/// One daemon-scoped model install: single writer, bounded progress, joinable.
///
/// The install belongs to the daemon, not to the connection that asked for it:
/// closing the model sheet, switching device, or reconnecting never stops it,
/// and it is cancelled only by an explicit [SttInstallControl.cancel]. That is
/// what lets `stt_status` answer the same install truth to every client, and it
/// is why progress is emitted here — one coalescing emitter for the local
/// channel and the hosted relay alike — instead of once per HTTP chunk per
/// transport.
///
/// Bounds, all of them deliberate:
///
/// * **one writer** — a repeated `install` for a model already downloading joins
///   the running install, and a different model is refused, so no second writer
///   can ever touch the same partial file;
/// * **at most one progress tick per [interval] and at most one per [step] of
///   the total** — the ~160 000 per-chunk events of the 874 MB default model
///   become ~100, a dropped tick is replaced by the next one rather than queued,
///   and a link so slow that 1 % takes many seconds still gets a
///   [kSttInstallProgressHeartbeatIntervals] heartbeat so the bar is never
///   mistaken for a frozen one;
/// * **the first tick, every phase change, and the terminal 100 % tick are
///   always emitted**, so the bar appears immediately and can never stall short
///   of the end — but a phase change that arrives before any byte is known rides
///   the first real tick instead of publishing a zero the resumed install would
///   have to contradict;
/// * **listeners are bounded by channels** — a channel attaches at most one
///   observer, and a join replaces it instead of accumulating;
/// * **the terminal truth is published after the install stops being truth** —
///   [onSettled] runs once `state` is null, so the last `stt_status` of an
///   install is the one that says nothing is in flight.
library;

import 'dart:async';

import 'stt_types.dart';

/// Cadence floor of one install's progress ticks.
const Duration kSttInstallProgressInterval = Duration(milliseconds: 250);

/// Least progress that must accumulate to release a tick.
///
/// It is what bounds one install at ~100 intermediate ticks whatever the link
/// speed; [kSttInstallProgressInterval] bounds the rate instead.
const double kSttInstallProgressStep = 0.01;

/// How many [kSttInstallProgressInterval]s a tick may wait for its step.
///
/// A link slow enough to need more than 1 % every two seconds would otherwise
/// look frozen; the heartbeat keeps the estimate and the bar alive without
/// relaxing the rate limit.
const int kSttInstallProgressHeartbeatIntervals = 8;

/// Hard ceiling on intermediate ticks for one install.
///
/// It only ever binds on a pathological producer; the step and interval rules
/// are what shape a real download, and this keeps the count bounded whatever a
/// future transport does.
const int kSttInstallMaxProgressTicks = 400;

/// Runs one install and reports raw progress.
///
/// `onProgress` is called for every unit the store can report (potentially once
/// per network chunk); coalescing is this file's job, not the runner's.
typedef SttInstallRunner =
    Future<void> Function(
      String modelId, {
      required void Function(int received, int total) onProgress,
      required void Function(SttInstallPhase phase) onPhase,
      required bool Function() isCancelled,
    });

/// The install truth a client rebuilds its bar from.
class SttInstallState {
  const SttInstallState({
    required this.modelId,
    required this.receivedBytes,
    required this.totalBytes,
    required this.phase,
    required this.bytesPerSecond,
  });

  final String modelId;
  final int receivedBytes;
  final int totalBytes;
  final SttInstallPhase phase;

  /// Observed transfer rate, or 0 before enough time has passed to measure one.
  final int bytesPerSecond;

  /// 0..1 while the total is known, null otherwise.
  double? get progress =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  /// Wire shape of `stt_status.install` and the additive progress fields.
  Map<String, dynamic> toWire() => {
    'model_id': modelId,
    'received_bytes': receivedBytes,
    'total_bytes': totalBytes,
    'phase': phase.name,
    'bytes_per_second': bytesPerSecond,
  };
}

/// How one install ended. A null [error] is success.
class SttInstallOutcome {
  const SttInstallOutcome({required this.modelId, this.error});

  final String modelId;
  final SttException? error;

  bool get succeeded => error == null;

  /// The install stopped because someone asked it to, not because it failed.
  bool get cancelled => error?.code == 'cancelled';
}

/// Receives one install's coalesced ticks and its terminal outcome.
abstract class SttInstallObserver {
  void onInstallProgress(SttInstallState state);

  void onInstallSettled(SttInstallOutcome outcome);
}

/// One channel's attachment to a running install.
///
/// Detaching stops the events and never the install: the connection that asked
/// may disappear while the download continues.
class SttInstallLease {
  SttInstallLease._(this._install, this._observer, {required this.joined});

  final _SttInstall _install;
  final SttInstallObserver _observer;

  /// True when this call attached to an install that was already running.
  final bool joined;

  bool _detached = false;

  /// The running install's current truth.
  SttInstallState get state => _install.snapshot;

  /// Completes when the install settles; never completes with an error.
  Future<void> get done => _install.done;

  void detach() {
    if (_detached) return;
    _detached = true;
    _install.observers.remove(_observer);
  }
}

/// Single-flight install owner for the whole daemon.
class SttInstallControl {
  SttInstallControl({
    required SttInstallRunner runner,
    DateTime Function()? clock,
    this.interval = kSttInstallProgressInterval,
    this.step = kSttInstallProgressStep,
    this.onSettled,
  }) : _runner = runner,
       _clock = clock ?? DateTime.now;

  final SttInstallRunner _runner;
  final DateTime Function() _clock;

  /// Cadence floor and step ceiling of one install's progress ticks.
  final Duration interval;
  final double step;

  _SttInstall? _active;

  /// The install in flight, or null.
  SttInstallState? get state => _active?.snapshot;

  bool get isRunning => _active != null;

  String? get modelId => _active?.modelId;

  /// Called once per install **after** [state] stops describing it.
  ///
  /// It is the only correct moment to publish a terminal `stt_status`: a status
  /// built while the install is still the active one carries `install` again,
  /// which is exactly how a finished download used to freeze a client's row.
  final void Function(SttInstallOutcome outcome)? onSettled;

  /// Attaches [observer] to the running install, or returns null when idle.
  ///
  /// This is what makes an install observable by every channel of the device
  /// rather than by the one that started it: a client that arrives mid-download
  /// asks for the status, attaches here, and then receives the same ticks and the
  /// same terminal event as the client that pressed the button.
  SttInstallLease? attach({required SttInstallObserver observer}) =>
      _active?.attach(observer, joined: true);

  /// Starts an install of [modelId], or attaches to the running one.
  ///
  /// Returns null when a **different** model is already installing: the caller
  /// reports `install_in_progress` and must not start a second writer.
  SttInstallLease? start(
    String modelId, {
    required SttInstallObserver observer,
    int seedReceived = 0,
    int seedTotal = 0,
  }) {
    final active = _active;
    if (active != null) {
      if (active.modelId != modelId) return null;
      return active.attach(observer, joined: true);
    }
    final install = _SttInstall(
      modelId: modelId,
      runner: _runner,
      clock: _clock,
      interval: interval,
      step: step,
      seedReceived: seedReceived,
      seedTotal: seedTotal,
    );
    _active = install;
    final lease = install.attach(observer, joined: false);
    unawaited(
      install.run().then((outcome) {
        // Release first, notify second: everything downstream builds its
        // terminal answer from [state].
        if (identical(_active, install)) _active = null;
        onSettled?.call(outcome);
      }),
    );
    return lease;
  }

  /// Explicit cancel. It is the only thing that stops a running install.
  void cancel() {
    _active?.requestCancel();
  }
}

class _SttInstall {
  _SttInstall({
    required this.modelId,
    required SttInstallRunner runner,
    required DateTime Function() clock,
    required Duration interval,
    required double step,
    int seedReceived = 0,
    int seedTotal = 0,
  }) : _runner = runner,
       _clock = clock,
       _interval = interval,
       _step = step,
       _seed = seedReceived,
       _received = seedReceived,
       _total = seedTotal;

  final String modelId;
  final SttInstallRunner _runner;
  final DateTime Function() _clock;
  final Duration _interval;
  final double _step;

  /// One observer per attached channel; a join replaces, never accumulates.
  final Set<SttInstallObserver> observers = <SttInstallObserver>{};

  final Completer<void> _done = Completer<void>();
  Future<void> get done => _done.future;

  bool _cancelled = false;
  bool _settled = false;

  /// Bytes a resumed install already had when it started.
  ///
  /// They belong in the projection from the first moment — the payload is built
  /// before the first HTTP response — but not in the observed rate, or the first
  /// tick would report a spike measured from zero.
  final int _seed;

  int _received;
  int _total;
  SttInstallPhase _phase = SttInstallPhase.downloading;
  int _bytesPerSecond = 0;

  final Stopwatch _elapsed = Stopwatch()..start();
  DateTime? _lastEmitAt;
  int _lastEmitBytes = -1;
  int _emitted = 0;

  SttInstallState get snapshot => SttInstallState(
    modelId: modelId,
    receivedBytes: _received,
    totalBytes: _total,
    phase: _phase,
    bytesPerSecond: _bytesPerSecond,
  );

  SttInstallLease attach(SttInstallObserver observer, {required bool joined}) {
    observers.add(observer);
    // A joining channel is answered with the truth it just missed, not with a
    // silent wait for the next tick.
    if (joined) observer.onInstallProgress(snapshot);
    return SttInstallLease._(this, observer, joined: joined);
  }

  void requestCancel() => _cancelled = true;

  Future<SttInstallOutcome> run() async {
    SttInstallOutcome outcome;
    try {
      await _runner(
        modelId,
        onProgress: _onProgress,
        onPhase: _onPhase,
        isCancelled: _isCancelled,
      );
      outcome = SttInstallOutcome(modelId: modelId);
    } on SttException catch (error) {
      outcome = SttInstallOutcome(modelId: modelId, error: error);
    } on Object catch (error) {
      outcome = SttInstallOutcome(
        modelId: modelId,
        error: SttException('download_failed', '$error'),
      );
    }
    _settle(outcome);
    return outcome;
  }

  bool _isCancelled() => _cancelled || _settled;

  void _onProgress(int received, int total) {
    if (_settled) return;
    _received = received;
    if (total > 0) _total = total;
    _measureRate();
    _maybeEmit();
  }

  void _onPhase(SttInstallPhase phase) {
    if (_settled || phase == _phase) return;
    _phase = phase;
    // A resumed install reports `verifying` before it has reported a byte, and
    // publishing that as a tick would send `received_bytes: 0` for a partial the
    // bar already had at 29 %: the bar dips to zero and then jumps back. The
    // phase is not lost — the first real tick carries it.
    if (_lastEmitAt == null) return;
    // Three or four phase changes per install: they are always delivered, so a
    // bar whose bytes stopped moving still says what the daemon is doing.
    _emit();
  }

  /// Observed rate over the whole install.
  ///
  /// It is deliberately monotonic and simple: a windowed rate on a link that
  /// stalls for a proxy retry reads as zero, and the Client only uses it to
  /// estimate the remaining time.
  void _measureRate() {
    final elapsedMs = _elapsed.elapsedMilliseconds;
    if (elapsedMs < 400) return;
    final transferred = _received - _seed;
    if (transferred <= 0) return;
    _bytesPerSecond = (transferred * 1000 / elapsedMs).round();
  }

  void _maybeEmit() {
    final last = _lastEmitAt;
    if (last == null) {
      // The first tick: the bar has to appear as soon as the install does.
      _emit();
      return;
    }
    final sinceLast = _clock().difference(last);
    // Rate limit, hard: never more than one tick per interval.
    if (sinceLast < _interval) return;
    final advanced = _total <= 0
        ? 1.0
        : (_received - _lastEmitBytes) / _total;
    // Count limit: a tick needs a step of progress, unless the step itself is
    // taking longer than the heartbeat, which only a very slow link does.
    final dueByStep = advanced >= _step;
    final dueByHeartbeat =
        sinceLast >= _interval * kSttInstallProgressHeartbeatIntervals;
    if (!dueByStep && !dueByHeartbeat) return;
    if (_emitted >= kSttInstallMaxProgressTicks) return;
    _emit();
  }

  void _emit() {
    _emitted++;
    _lastEmitAt = _clock();
    _lastEmitBytes = _received;
    if (observers.isEmpty) return;
    final state = snapshot;
    for (final observer in observers.toList(growable: false)) {
      observer.onInstallProgress(state);
    }
  }

  void _settle(SttInstallOutcome outcome) {
    if (_settled) return;
    _settled = true;
    _elapsed.stop();
    if (outcome.succeeded) {
      // The bar must land on 100 % even when the last real tick was coalesced
      // away.
      _received = _total;
      _notifyAll();
    }
    final attached = observers.toList(growable: false);
    observers.clear();
    for (final observer in attached) {
      observer.onInstallSettled(outcome);
    }
    if (!_done.isCompleted) _done.complete();
  }

  void _notifyAll() {
    final state = snapshot;
    for (final observer in observers.toList(growable: false)) {
      observer.onInstallProgress(state);
    }
  }
}
