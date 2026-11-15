// Deterministic coverage for the client-side stream order gate.
//
// Every case drives the gate through its public decisions only: which events it
// returns for application, when it asks for one repair snapshot, and how it
// bounds its own windows. Time is fully injected, so no case sleeps.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/stream_delta_order_gate.dart';

import '../../helpers/manual_timer_scheduler.dart';

void main() {
  late ManualTimerScheduler scheduler;
  late DateTime now;
  late StreamDeltaOrderGate gate;
  late List<CanonicalEvent> applied;
  late List<String> repairRequests;
  late Future<CanonicalEvent?> Function(String sessionId) onRepair;

  setUp(() {
    scheduler = ManualTimerScheduler();
    now = DateTime.utc(2026, 1, 1, 12);
    gate = StreamDeltaOrderGate(
      timerFactory: scheduler.factory,
      now: () => now,
    );
    applied = <CanonicalEvent>[];
    repairRequests = <String>[];
    onRepair = (sessionId) async {
      repairRequests.add(sessionId);
      return null;
    };
    gate.configure(
      repair: (sessionId) => onRepair(sessionId),
      applyAdopted: (events) => applied.addAll(events),
    );
    gate.setRepairEnabled(true);
  });

  CanonicalEvent delta({
    int? seq,
    String text = 'x',
    EventKind kind = EventKind.thinking,
    String sessionId = 's1',
    String? step = 'step-1',
    String? run = 'run-1',
    bool snapshot = false,
    EventStatus status = EventStatus.running,
  }) {
    return CanonicalEvent(
      id: '${kind.name}_${step ?? run}',
      kind: kind,
      status: status,
      text: text,
      timestamp: now,
      sessionId: sessionId,
      runId: run,
      modelStepId: step,
      streamSeq: seq,
      isSnapshot: snapshot,
    );
  }

  List<CanonicalEvent> admitAll(Iterable<CanonicalEvent> events) {
    final out = <CanonicalEvent>[];
    for (final event in events) {
      out.addAll(gate.admit(event));
    }
    applied.addAll(out);
    return out;
  }

  String textOf(EventKind kind) => applied
      .where((event) => event.kind == kind)
      .map((event) => event.text)
      .join();

  test('applies an in-order stream immediately and keeps no timer', () {
    final out = admitAll([
      delta(seq: 1, text: 'A'),
      delta(seq: 2, text: 'B'),
      delta(seq: 3, text: 'C'),
    ]);

    expect(out.map((event) => event.streamSeq), [1, 2, 3]);
    expect(textOf(EventKind.thinking), 'ABC');
    expect(scheduler.delays, isEmpty);
    expect(gate.bufferedStreamCount, 0);
  });

  test('drops a duplicate or stale ordinal without touching the text', () {
    admitAll([delta(seq: 1, text: 'A'), delta(seq: 2, text: 'B')]);

    final duplicate = gate.admit(delta(seq: 2, text: 'B'));
    final stale = gate.admit(delta(seq: 1, text: 'A'));

    expect(duplicate, isEmpty);
    expect(stale, isEmpty);
    expect(textOf(EventKind.thinking), 'AB');
  });

  test('holds 5 until 4 arrives, then applies both in sequence order', () {
    final late5 = gate.admit(delta(seq: 5, text: 'E'));
    expect(late5, isEmpty, reason: 'the predecessor is missing');
    expect(gate.bufferedStreamCount, 1);
    expect(scheduler.delays, [StreamDeltaOrderLimits.reorderWindow]);

    final ordered = gate.admit(delta(seq: 4, text: 'D'));
    applied.addAll(ordered);

    expect(ordered.map((event) => event.streamSeq), [4, 5]);
    expect(ordered.map((event) => event.text), ['D', 'E']);
    expect(gate.bufferedStreamCount, 0);
    expect(repairRequests, isEmpty);
  });

  test('a permanent gap asks for exactly one repair after the window', () {
    gate.admit(delta(seq: 3, text: 'C'));
    expect(repairRequests, isEmpty);

    scheduler.fireAll();
    expect(repairRequests, ['s1']);
    expect(gate.bufferedStreamCount, 0, reason: 'the buffer is dropped with the gap');
  });

  test('repair respects the cooldown and never overlaps a request', () async {
    final neverCompletes = Completer<CanonicalEvent?>();
    onRepair = (sessionId) {
      repairRequests.add(sessionId);
      return neverCompletes.future;
    };

    gate.admit(delta(seq: 3, text: 'C'));
    scheduler.fireAll();
    expect(repairRequests, ['s1']);

    // A second stream in the same session expires while the first request is
    // still unanswered: no second request leaves the Client.
    gate.admit(delta(seq: 2, text: 'B', kind: EventKind.reasoning));
    scheduler.fireAll();
    expect(repairRequests, ['s1']);

    neverCompletes.complete(null);
    await Future<void>.delayed(Duration.zero);
    now = now.add(StreamDeltaOrderLimits.repairCooldown);

    // After the cooldown the session may ask again, once per gap.
    now = now.add(StreamDeltaOrderLimits.repairCooldown);
    gate.noteTerminal(sessionId: 's1', modelStepId: 'step-1', turnTerminal: true);
    gate.admit(delta(seq: 3, text: 'C', step: 'step-2'));
    scheduler.fireAll();
    expect(repairRequests, ['s1', 's1']);
  });

  test('a gap inside the cooldown window waits instead of asking again', () async {
    onRepair = (sessionId) async {
      repairRequests.add(sessionId);
      return delta(seq: 2, text: 'AB', snapshot: true);
    };

    gate.admit(delta(seq: 3, text: 'C'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(repairRequests, ['s1']);

    now = now.add(const Duration(milliseconds: 300));
    gate.admit(delta(seq: 5, text: 'E'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(repairRequests, ['s1'], reason: 'inside the cooldown');

    now = now.add(StreamDeltaOrderLimits.repairCooldown);
    gate.admit(delta(seq: 6, text: 'F'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(repairRequests, ['s1', 's1']);
  });

  test('the reorder window bounds count, bytes, and stream keys', () {
    for (var sequence = 2; sequence <= StreamDeltaOrderLimits.maxBufferedDeltas + 1; sequence++) {
      gate.admit(delta(seq: sequence, text: 'c', run: 'run-count'));
    }
    gate.admit(delta(seq: 99, text: 'overflow', run: 'run-count'));
    expect(gate.bufferedStreamCount, 0, reason: 'count cap drops the buffer');
    expect(repairRequests, ['s1']);

    gate.setRepairEnabled(false);
    applied.clear();
    final big = 'x' * 8192;
    for (var index = 1; index <= 9; index++) {
      gate.admit(delta(seq: index + 1, text: big, run: 'run-bytes'));
    }
    expect(
      gate.bufferedStreamCount,
      0,
      reason: '8 x 8 KiB fills the byte window, the ninth drops it',
    );

    gate.setRepairEnabled(true);
    for (var step = 0; step < StreamDeltaOrderLimits.maxStreamsPerSession + 4; step++) {
      gate.admit(delta(seq: 2, text: 'g', step: 'step-$step', run: 'run-$step'));
    }
    expect(
      gate.bufferedStreamCount,
      StreamDeltaOrderLimits.maxStreamsPerSession,
      reason: 'tracked stream keys never exceed their own bound',
    );
  });

  test('a snapshot replaces the watermark and stale deltas below it are dropped', () {
    admitAll([delta(seq: 1, text: 'A'), delta(seq: 2, text: 'B')]);

    final snapshot = gate.admit(delta(seq: 4, text: 'ABCD', snapshot: true));
    expect(snapshot, hasLength(1));
    expect(snapshot.single.isSnapshot, isTrue);

    expect(gate.admit(delta(seq: 3, text: 'C')), isEmpty);
    expect(gate.admit(delta(seq: 4, text: 'D')), isEmpty);
    final next = gate.admit(delta(seq: 5, text: 'E'));
    expect(next.map((event) => event.streamSeq), [5]);
  });

  test('a terminal seals its step so a late delta cannot reopen the stream', () {
    admitAll([delta(seq: 1, text: 'A')]);
    gate.noteTerminal(
      sessionId: 's1',
      modelStepId: 'step-1',
      runId: 'run-1',
      turnTerminal: true,
    );

    expect(gate.admit(delta(seq: 2, text: 'B')), isEmpty);
    expect(gate.admit(delta(seq: 3, text: 'C', kind: EventKind.reasoning)), isEmpty);

    // A new step owns a new key and streams normally.
    final nextStep = gate.admit(delta(seq: 1, text: 'N', step: 'step-2'));
    expect(nextStep.map((event) => event.text), ['N']);
  });

  test('a stop seals the run so a late run-scoped delta is dropped', () {
    admitAll([delta(seq: 1, text: 'A', step: null)]);
    gate.noteTerminal(sessionId: 's1', runId: 'run-1', turnTerminal: true);

    expect(gate.admit(delta(seq: 2, text: 'B', step: null)), isEmpty);
  });

  test('a stream without ordinals keeps plain arrival order for its lifetime', () {
    final legacy = admitAll([
      delta(text: 'A'),
      delta(text: 'B'),
      delta(text: 'C'),
    ]);
    expect(legacy, hasLength(3));
    expect(textOf(EventKind.thinking), 'ABC');

    // Even a late ordinal on that key stays best-effort: the stream is already
    // unsequenced for its lifetime and must not start judging arrivals.
    final mixed = gate.admit(delta(seq: 1, text: 'D'));
    expect(mixed, hasLength(1));
    applied.addAll(mixed);
    expect(textOf(EventKind.thinking), 'ABCD');
    expect(scheduler.delays, isEmpty);
  });

  test('reasoning and ordinary text keep independent ordinals', () {
    admitAll([delta(seq: 1, text: 'h')]);
    admitAll([delta(seq: 1, text: 'r', kind: EventKind.reasoning)]);
    admitAll([delta(seq: 2, text: 'i')]);

    expect(textOf(EventKind.thinking), 'hi');
    expect(textOf(EventKind.reasoning), 'r');
    expect(gate.admit(delta(seq: 2, text: 'r2', kind: EventKind.reasoning)), hasLength(1));
  });

  test('an absent answer keeps the last good text and waits for the terminal', () async {
    admitAll([delta(seq: 1, text: 'A')]);

    gate.admit(delta(seq: 3, text: 'C'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);

    expect(repairRequests, ['s1']);
    expect(applied.map((event) => event.text), ['A']);
    expect(gate.bufferedStreamCount, 0);

    // Suspended until the terminal: another gap inside the cooldown window is
    // dropped without inventing text and without a second query.
    gate.admit(delta(seq: 4, text: 'D'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(repairRequests, ['s1']);
    expect(textOf(EventKind.thinking), 'A');

    gate.noteTerminal(sessionId: 's1', modelStepId: 'step-1', turnTerminal: true);
    now = now.add(StreamDeltaOrderLimits.repairCooldown);
    gate.admit(delta(seq: 2, text: 'B', step: 'step-2'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(repairRequests, ['s1', 's1']);
  });

  test('an adopted repair snapshot replaces text and drains what follows it', () async {
    onRepair = (sessionId) async {
      repairRequests.add(sessionId);
      return delta(seq: 3, text: 'ABC', snapshot: true);
    };

    admitAll([delta(seq: 1, text: 'A')]);
    gate.admit(delta(seq: 4, text: 'D'));
    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);

    expect(repairRequests, ['s1']);
    final adopted = applied.last;
    expect(adopted.isSnapshot, isTrue);
    expect(adopted.streamSeq, 3);
    expect(gate.admit(delta(seq: 2, text: 'B')), isEmpty);
    expect(gate.admit(delta(seq: 4, text: 'D')).map((event) => event.streamSeq), [4]);
  });

  test('cross-transport interleave converges on the same text', () {
    // Two transports deliver the same stream interleaved; the second copy of
    // every ordinal is a duplicate, never an append.
    final out = admitAll([
      delta(seq: 1, text: 'A'),
      delta(seq: 2, text: 'B'),
      delta(seq: 1, text: 'A'),
      delta(seq: 3, text: 'C'),
      delta(seq: 2, text: 'B'),
    ]);

    expect(out.map((event) => event.streamSeq), [1, 2, 3]);
    expect(textOf(EventKind.thinking), 'ABC');
  });

  test('sessions are independent and ordered on their own', () {
    gate.admit(delta(seq: 3, text: 'S2C', sessionId: 's2'));
    final accepted = admitAll([delta(seq: 1, text: 'S1A', sessionId: 's1')]);
    expect(accepted, hasLength(1));
    expect(textOf(EventKind.thinking), 'S1A');
    expect(gate.bufferedStreamCount, 1);
  });

  test('a session switch and disposal release every buffer and timer', () {
    gate.admit(delta(seq: 3, text: 'C'));
    expect(scheduler.activeCount, 1);

    gate.resetSession('s1');
    expect(gate.bufferedStreamCount, 0);
    expect(gate.trackedSessionCount, 0);
    expect(scheduler.activeCount, 0);
    expect(gate.isIdle, isTrue);

    gate.admit(delta(seq: 3, text: 'C', sessionId: 's1'));
    gate.admit(delta(seq: 3, text: 'C', sessionId: 's2'));
    gate.dispose();
    expect(gate.isIdle, isTrue);
    expect(scheduler.activeCount, 0);
  });

  test('a repair that returns after the session was reset is ignored', () async {
    final pending = Completer<CanonicalEvent?>();
    onRepair = (sessionId) {
      repairRequests.add(sessionId);
      return pending.future;
    };

    admitAll([delta(seq: 1, text: 'A')]);
    gate.admit(delta(seq: 3, text: 'C'));
    scheduler.fireAll();
    expect(repairRequests, ['s1']);

    // A session switch releases the ordering state while the request is out.
    gate.resetSession('s1');
    pending.complete(delta(seq: 3, text: 'ABC', snapshot: true));
    await Future<void>.delayed(Duration.zero);

    expect(
      applied.map((event) => event.text),
      ['A'],
      reason: 'a stale answer must not inject text after the owner is gone',
    );
    expect(gate.trackedSessionCount, 0);
    expect(gate.repairRequestCount, 1);
  });

  test('a repair that returns after a turn terminal is ignored', () async {
    final pending = Completer<CanonicalEvent?>();
    onRepair = (sessionId) {
      repairRequests.add(sessionId);
      return pending.future;
    };

    admitAll([delta(seq: 1, text: 'A')]);
    gate.admit(delta(seq: 3, text: 'C'));
    scheduler.fireAll();

    gate.noteTerminal(
      sessionId: 's1',
      modelStepId: 'step-1',
      runId: 'run-1',
      turnTerminal: true,
    );
    pending.complete(delta(seq: 5, text: 'ABCDE', snapshot: true));
    await Future<void>.delayed(Duration.zero);

    expect(applied.map((event) => event.text), ['A']);
    expect(gate.admit(delta(seq: 6, text: 'F', step: 'step-2')), isEmpty,
        reason: 'the run key stays sealed for the finished turn');
  });

  test('a repair that returns after disposal is ignored entirely', () async {
    final pending = Completer<CanonicalEvent?>();
    onRepair = (sessionId) {
      repairRequests.add(sessionId);
      return pending.future;
    };

    admitAll([delta(seq: 1, text: 'A')]);
    gate.admit(delta(seq: 3, text: 'C'));
    scheduler.fireAll();

    gate.dispose();
    pending.complete(delta(seq: 3, text: 'ABC', snapshot: true));
    await Future<void>.delayed(Duration.zero);

    expect(applied.map((event) => event.text), ['A']);
    expect(gate.isIdle, isTrue);
    expect(gate.admit(delta(seq: 2, text: 'B')), isEmpty,
        reason: 'a disposed gate never decides again');
  });

  test('a hydrated baseline replaces arrival state with its watermark', () {
    admitAll([delta(seq: 1, text: 'A'), delta(seq: 2, text: 'B')]);

    gate.adoptBaseline(
      sessionId: 's1',
      events: [delta(seq: 6, text: 'ABCDEF', snapshot: true)],
    );

    expect(gate.admit(delta(seq: 3, text: 'C')), isEmpty);
    expect(gate.admit(delta(seq: 7, text: 'G')).map((event) => event.text), ['G']);
  });

  test('ordering works without the capability; only repair is disabled', () {
    final offline = StreamDeltaOrderGate(
      timerFactory: scheduler.factory,
      now: () => now,
    );
    final adopted = <CanonicalEvent>[];
    final requests = <String>[];
    offline.configure(
      repair: (sessionId) async {
        requests.add(sessionId);
        return delta(seq: 2, text: 'AB', snapshot: true);
      },
      applyAdopted: adopted.addAll,
    );

    expect(offline.admit(delta(seq: 1, text: 'A')), hasLength(1));
    expect(offline.admit(delta(seq: 3, text: 'C')), isEmpty);

    final drained = offline.admit(delta(seq: 2, text: 'B'));
    expect(drained.map((event) => event.text), ['B', 'C']);

    // A window that cannot close asks nobody when the peer never declared the
    // contract, and the applied text stays untouched.
    expect(offline.admit(delta(seq: 5, text: 'E')), isEmpty);
    scheduler.fireAll();
    expect(requests, isEmpty, reason: 'an undeclared peer is never queried');
    expect(adopted, isEmpty);
    offline.dispose();
  });

  test('the tracked-session window evicts the least recently used session', () {
    for (var index = 0; index < StreamDeltaOrderLimits.maxTrackedSessions; index++) {
      gate.admit(delta(seq: 3, text: 'C', sessionId: 'session-$index'));
    }
    expect(gate.trackedSessionCount, StreamDeltaOrderLimits.maxTrackedSessions);

    gate.admit(delta(seq: 3, text: 'C', sessionId: 'session-new'));

    expect(
      gate.trackedSessionCount,
      StreamDeltaOrderLimits.maxTrackedSessions,
      reason: 'the session window never grows',
    );
    expect(scheduler.activeCount, lessThanOrEqualTo(StreamDeltaOrderLimits.maxTrackedSessions));

    // The most recent session still holds its ordinal state.
    expect(
      gate.admit(delta(seq: 2, text: 'A', sessionId: 'session-new')).map((event) => event.text),
      ['A', 'C'],
    );
  });

  test('a bare delta on a sequenced key keeps the window and the watermark', () {
    admitAll([delta(seq: 1, text: 'A')]);
    expect(gate.admit(delta(seq: 3, text: 'C')), isEmpty);
    expect(gate.bufferedStreamCount, 1);

    final bestEffort = gate.admit(delta(text: 'B'));
    expect(bestEffort, hasLength(1), reason: 'legacy best-effort still applies');
    expect(
      gate.bufferedStreamCount,
      1,
      reason: 'a bare delta never discards a pending sequenced delta',
    );

    final drained = gate.admit(delta(seq: 2, text: 'B2'));
    expect(drained.map((event) => event.streamSeq), [2, 3]);

    // The key is still sequenced: an out-of-order arrival is held, not applied.
    expect(gate.admit(delta(seq: 5, text: 'E')), isEmpty);
    expect(gate.admit(delta(seq: 4, text: 'D')).map((event) => event.streamSeq), [4, 5]);
  });
}
