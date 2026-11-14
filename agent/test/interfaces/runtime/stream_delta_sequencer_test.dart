/// The run-owned allocator of `stream_seq`.
///
/// One run owns one sequencer, and every stream key inside it counts from `1`
/// independently. These cases pin the three properties a consumer relies on:
/// one key's ordinals are contiguous, two kinds never consume each other's
/// numbers, and a new model step or a new run starts over.
library;

import 'package:sanad_agent/interfaces/runtime/stream_delta_sequencer.dart';
import 'package:test/test.dart';

void main() {
  group('StreamDeltaSequencer', () {
    test('interleaved kinds keep independent contiguous ordinals', () {
      final sequencer = StreamDeltaSequencer(runId: 'run-1');

      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        1,
      );
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.reasoningKind,
          modelStepId: 'step-1',
        ),
        1,
      );
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        2,
      );
    });

    test('two stream kinds in one model step never share a counter', () {
      final sequencer = StreamDeltaSequencer(runId: 'run-1');
      for (var index = 1; index <= 3; index++) {
        expect(
          sequencer.next(
            kind: StreamDeltaSequencer.thoughtKind,
            modelStepId: 'step-1',
          ),
          index,
        );
      }

      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.reasoningKind,
          modelStepId: 'step-1',
        ),
        1,
        reason: 'reasoning must not continue the thought ordinals',
      );
      expect(
        sequencer.lastAllocated(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        3,
      );
    });

    test('a new model step starts its key at one', () {
      final sequencer = StreamDeltaSequencer(runId: 'run-1');
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        1,
      );
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        2,
      );
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-2',
        ),
        1,
      );
    });

    test('a new run starts its keys at one', () {
      final first = StreamDeltaSequencer(runId: 'run-1');
      expect(
        first.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        1,
      );

      final second = StreamDeltaSequencer(runId: 'run-2');
      expect(
        second.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        1,
      );
    });

    test('an absent model step keys on the run, never on another step', () {
      final sequencer = StreamDeltaSequencer(runId: 'run-1');
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: null,
        ),
        1,
      );
      expect(
        sequencer.next(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        1,
      );
      expect(
        sequencer.keyFor(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: null,
        ),
        sequencer.keyFor(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: '',
        ),
      );
      expect(
        sequencer.keyFor(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: null,
        ),
        isNot(
          sequencer.keyFor(
            kind: StreamDeltaSequencer.thoughtKind,
            modelStepId: 'step-1',
          ),
        ),
      );
    });

    test('lastAllocated reports nothing for an unseen key', () {
      final sequencer = StreamDeltaSequencer(runId: 'run-1');
      expect(
        sequencer.lastAllocated(
          kind: StreamDeltaSequencer.thoughtKind,
          modelStepId: 'step-1',
        ),
        0,
      );
    });
  });
}
