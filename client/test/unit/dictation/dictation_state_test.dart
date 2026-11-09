import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

void main() {
  group('visible text', () {
    test('shows the partial alone before any segment is committed', () {
      const state = DictationState(partialText: 'السلام', partialSeq: 0);
      expect(state.visibleText, 'السلام');
    });

    test('shows the committed text after the partial clears', () {
      const state = DictationState(segments: ['hello world']);
      expect(state.visibleText, 'hello world');
    });

    // The regression: a new segment's partial used to be glued to the committed
    // one until it was committed, then a space appeared and the text jumped.
    test('separates a live partial from the committed text with one space', () {
      const state = DictationState(
        segments: ['السلام عليكم'],
        partialSeq: 1,
        partialText: 'كيف حالك',
      );
      expect(state.visibleText, 'السلام عليكم كيف حالك');
    });

    test('never doubles the space the model already sent', () {
      const afterCommitted = DictationState(
        segments: ['hello '],
        partialSeq: 1,
        partialText: 'world',
      );
      const beforePartial = DictationState(
        segments: ['hello'],
        partialSeq: 1,
        partialText: ' world',
      );
      expect(afterCommitted.visibleText, 'hello world');
      expect(beforePartial.visibleText, 'hello world');
    });
  });

  group('seq is the replacement key', () {
    test('committed text is the segments in daemon order', () {
      const state = DictationState(segments: ['First.', 'Second.', 'Third.']);
      expect(state.committedText, 'First. Second. Third.');
    });

    // The daemon closes a segment with a final whose text is the whole segment,
    // so the partial that previewed it must not survive as an extra copy.
    test('a partial for an already finalized seq is never shown', () {
      const state = DictationState(
        segments: ['The lazy dog. the quick brown fox jumps over the lazy dog'],
        partialSeq: 0,
        partialText: 'The lazy dog. the quick brown fox jump',
      );
      expect(state.partialSlotIsCommitted, isTrue);
      expect(
        state.visibleText,
        'The lazy dog. the quick brown fox jumps over the lazy dog',
      );
    });

    test('an empty slot does not add a separator to the transcript', () {
      const state = DictationState(segments: ['', 'Only one spoke']);
      expect(state.committedText, 'Only one spoke');
      expect(state.nextSegmentSeq, 2);
    });
  });

  // The daemon owns the selected model, and another Client can change it at any
  // time. The projection therefore has to remember **when** it was read, so a
  // press can tell a fresh answer from one that may already be wrong.
  group('model projection freshness', () {
    final now = DateTime(2026, 11, 9, 12, 30);
    const bound = Duration(seconds: 30);

    test('a projection the daemon never answered is stale', () {
      const never = DictationModelStatus(selectedModelId: 'whisper-base-int8');
      expect(never.fetchedAt, isNull);
      expect(never.projectionOlderThan(bound, now: now), isTrue);
    });

    test('a projection follows the moment it was read', () {
      final fresh = DictationModelStatus(
        selectedModelId: 'whisper-base-int8',
        fetchedAt: now.subtract(const Duration(seconds: 5)),
      );
      expect(fresh.projectionOlderThan(bound, now: now), isFalse);

      final stale = DictationModelStatus(
        selectedModelId: 'whisper-base-int8',
        fetchedAt: now.subtract(const Duration(seconds: 31)),
      );
      expect(stale.projectionOlderThan(bound, now: now), isTrue);
    });

    test('the bound is inclusive, so exactly-at-age is re-read', () {
      final atBound = DictationModelStatus(
        fetchedAt: now.subtract(bound),
      );
      expect(atBound.projectionOlderThan(bound, now: now), isTrue);
    });

    test('a daemon answer keeps the selection and the timestamp together', () {
      final status = const DictationModelStatus(selectedModelId: 'a')
          .copyWith(selectedModelId: 'b', fetchedAt: now);
      expect(status.selectedModelId, 'b');
      expect(status.fetchedAt, now);
      expect(
        status.projectionOlderThan(bound, now: now.add(const Duration(seconds: 1))),
        isFalse,
      );
    });
  });
}
