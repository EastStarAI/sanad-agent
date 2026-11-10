// The install owner's contract: one writer, bounded progress, join, cancel.
//
// These are the properties the client depends on and that the shipped code got
// wrong before: a second press started nothing but was reported as a failure, a
// socket close deleted the partial, and progress was one event per HTTP chunk
// (~160 000 for the default model).

import 'dart:async';

import 'package:sanad_agent/infrastructure/stt/stt_install_control.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

/// Records every tick and settles when the runner finishes.
class _Recorder implements SttInstallObserver {
  final List<SttInstallState> ticks = <SttInstallState>[];
  final List<SttInstallOutcome> outcomes = <SttInstallOutcome>[];

  @override
  void onInstallProgress(SttInstallState state) => ticks.add(state);

  @override
  void onInstallSettled(SttInstallOutcome outcome) => outcomes.add(outcome);
}

void main() {
  group('progress throttle', () {
    test('coalesces per-chunk progress into a bounded number of ticks', () async {
      // 12 400 chunks over 2 s of fake time: the shape of one real install.
      const chunks = 12400;
      const total = 1000000;
      var now = DateTime(2026, 11, 9, 12);
      DateTime clock() => now;
      var chunk = -1;

      final control = SttInstallControl(
        clock: clock,
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          for (var index = 0; index < chunks; index++) {
            chunk = index;
            // ~0.16 ms per chunk, so a real download's 2 s.
            now = now.add(const Duration(microseconds: 161));
            onProgress(((index + 1) * total) ~/ chunks, total);
          }
        },
      );
      final recorder = _Recorder();
      final lease = control.start('m', observer: recorder)!;
      await lease.done;

      // 2 s of transfer at 4 Hz is 8 ticks plus the first and the 100 % tick:
      // nothing like one per chunk.
      expect(recorder.ticks.length, lessThanOrEqualTo(12));
      expect(recorder.ticks.length, greaterThanOrEqualTo(5));
      expect(chunk, chunks - 1);
      expect(recorder.ticks.first.receivedBytes, greaterThan(0));
      expect(recorder.ticks.last.receivedBytes, total);
      expect(recorder.ticks.last.progress, 1);
      expect(recorder.outcomes.single.succeeded, isTrue);
    });

    test('a fast link is bounded by the 1 % step, not by the clock', () async {
      // 100 000 chunks over 100 s of fake time with 1 ms per chunk: the clock
      // alone would allow 400 ticks, so the step rule is what has to bound it.
      const total = 100000;
      var now = DateTime(2026, 11, 9, 12);
      final control = SttInstallControl(
        clock: () => now,
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          for (var index = 0; index < total; index++) {
            now = now.add(const Duration(milliseconds: 1));
            onProgress(index + 1, total);
          }
        },
      );
      final recorder = _Recorder();
      await control.start('m', observer: recorder)!.done;

      // One tick per 1 % is 100; nothing like one per 250 ms (400).
      expect(recorder.ticks.length, lessThanOrEqualTo(105));
      expect(recorder.ticks.length, greaterThanOrEqualTo(95));
      expect(recorder.ticks.last.progress, 1);
    });

    test('a very slow link still gets a heartbeat', () async {
      // 1 % would need 10 minutes here: the heartbeat, not the step, keeps the
      // bar and the estimate alive.
      const total = 1000000;
      var now = DateTime(2026, 11, 9, 12);
      final control = SttInstallControl(
        clock: () => now,
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          for (var index = 0; index < 20; index++) {
            now = now.add(const Duration(seconds: 5));
            onProgress(index + 1, total);
          }
        },
      );
      final recorder = _Recorder();
      await control.start('m', observer: recorder)!.done;

      expect(recorder.ticks.length, greaterThanOrEqualTo(5));
      expect(recorder.ticks.last.receivedBytes, total);
    });

    test('the terminal tick is 100 % even when the last one was coalesced', () async {
      var now = DateTime(2026, 11, 9, 12);
      final control = SttInstallControl(
        clock: () => now,
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onProgress(10, 1000);
          onProgress(20, 1000);
          // The last real bytes arrive inside the same 250 ms window.
          onProgress(1000, 1000);
        },
      );
      final recorder = _Recorder();
      await control.start('m', observer: recorder)!.done;
      expect(recorder.ticks.last.receivedBytes, 1000);
      expect(recorder.ticks.last.progress, 1);
    });

    test('a resumed install never publishes a zero it has to contradict', () async {
      // A `.partial` on disk makes the store report `verifying` before it reports
      // a byte. Emitting that as a tick sent `received_bytes: 0` for an artifact
      // the bar showed at 29 %, so the sheet dipped to 0 % and jumped back: the
      // first tick has to carry the resumed offset instead.
      const resumed = 468542332;
      const total = 1624555275;
      var now = DateTime(2026, 11, 9, 12);
      final control = SttInstallControl(
        clock: () => now,
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onPhase(SttInstallPhase.verifying);
          now = now.add(const Duration(milliseconds: 100));
          onProgress(resumed, total);
          onPhase(SttInstallPhase.downloading);
          now = now.add(const Duration(seconds: 3));
          onProgress(total, total);
        },
      );
      final recorder = _Recorder();
      await control.start('m', observer: recorder)!.done;

      expect(recorder.ticks.first.receivedBytes, resumed);
      expect(recorder.ticks.first.phase, SttInstallPhase.verifying);
      expect(
        recorder.ticks.any((tick) => tick.receivedBytes == 0),
        isFalse,
        reason: 'a resumed bar must never restart from zero',
      );
      expect(recorder.ticks.last.progress, 1);
    });

    test('a phase change is always delivered', () async {
      var now = DateTime(2026, 11, 9, 12);
      final control = SttInstallControl(
        clock: () => now,
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onProgress(500, 1000);
          onPhase(SttInstallPhase.verifying);
          onPhase(SttInstallPhase.activating);
        },
      );
      final recorder = _Recorder();
      await control.start('m', observer: recorder)!.done;
      final phases = recorder.ticks.map((tick) => tick.phase).toSet();
      expect(phases, contains(SttInstallPhase.downloading));
      expect(phases, contains(SttInstallPhase.verifying));
      expect(phases, contains(SttInstallPhase.activating));
    });
  });

  group('single writer', () {
    test('a second install of the same model joins instead of writing twice',
        () async {
      final release = Completer<void>();
      var runs = 0;
      final control = SttInstallControl(
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          runs++;
          onProgress(100, 1000);
          await release.future;
          onProgress(1000, 1000);
        },
      );

      final first = _Recorder();
      final firstLease = control.start('m', observer: first)!;
      expect(firstLease.joined, isFalse);

      final second = _Recorder();
      final secondLease = control.start('m', observer: second)!;
      expect(secondLease.joined, isTrue);
      expect(runs, 1, reason: 'a join must never start a second writer');
      // The joining channel is answered with the running truth immediately.
      expect(second.ticks.single.receivedBytes, 100);
      expect(control.state?.modelId, 'm');

      release.complete();
      await Future.wait([firstLease.done, secondLease.done]);

      expect(runs, 1);
      expect(first.ticks.last.progress, 1);
      expect(second.ticks.last.progress, 1);
      expect(first.outcomes.single.succeeded, isTrue);
      expect(second.outcomes.single.succeeded, isTrue);
      expect(control.isRunning, isFalse);
    });

    test('a different model is refused while one is installing', () async {
      final release = Completer<void>();
      final control = SttInstallControl(
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onProgress(1, 10);
          await release.future;
        },
      );

      final lease = control.start('first', observer: _Recorder())!;
      expect(control.start('second', observer: _Recorder()), isNull);
      release.complete();
      await lease.done;
      // Once the first settles, the second model is admitted.
      expect(control.start('second', observer: _Recorder()), isNotNull);
    });
  });

  group('lifetime and cancel', () {
    test('a detached channel does not stop the install', () async {
      final release = Completer<void>();
      var finished = false;
      final control = SttInstallControl(
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onProgress(1, 10);
          await release.future;
          finished = !isCancelled();
        },
      );

      final recorder = _Recorder();
      final lease = control.start('m', observer: recorder)!;
      // This is what a closed socket does: it stops listening, nothing more.
      lease.detach();
      release.complete();
      await lease.done;

      expect(finished, isTrue, reason: 'detaching must not cancel the install');
      expect(recorder.outcomes, isEmpty, reason: 'a detached channel is silent');
      expect(control.isRunning, isFalse);
    });

    test('an explicit cancel ends the install with a cancelled outcome', () async {
      final cancelled = Completer<void>();
      final control = SttInstallControl(
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onProgress(1, 10);
          while (!isCancelled()) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          cancelled.complete();
          throw const SttException('cancelled', 'download cancelled');
        },
      );

      final recorder = _Recorder();
      final lease = control.start('m', observer: recorder)!;
      control.cancel();
      await lease.done;

      expect(cancelled.isCompleted, isTrue);
      expect(recorder.outcomes.single.cancelled, isTrue);
      expect(recorder.ticks.last.receivedBytes, 1);
    });

    test('a failed install reports its typed error and stops being truth',
        () async {
      final control = SttInstallControl(
        runner: (modelId, {required onProgress, required onPhase, required isCancelled}) async {
          onProgress(5, 10);
          throw const SttException('storage_full', 'no space');
        },
      );
      final recorder = _Recorder();
      await control.start('m', observer: recorder)!.done;

      expect(recorder.outcomes.single.error?.code, 'storage_full');
      expect(control.state, isNull);
    });
  });
}
