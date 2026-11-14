/// Manual timer scheduler for deterministic stream-order tests.
///
/// The ordering gate and any owner under test schedule their reorder window and
/// repair cooldown through an injected timer factory, so a test fires the exact
/// window it means to expire instead of waiting on wall-clock time.
library;

import 'dart:async';

class ManualTimer implements Timer {
  ManualTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  /// Runs the scheduled callback once, if the window is still pending.
  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

class ManualTimerScheduler {
  final List<ManualTimer> timers = <ManualTimer>[];
  final List<Duration> delays = <Duration>[];

  Timer factory(Duration delay, void Function() callback) {
    delays.add(delay);
    final timer = ManualTimer(callback);
    timers.add(timer);
    return timer;
  }

  void fireAll() {
    for (final timer in List<ManualTimer>.from(timers)) {
      timer.fire();
    }
    timers.clear();
  }

  int get activeCount => timers.where((timer) => timer.isActive).length;
}
