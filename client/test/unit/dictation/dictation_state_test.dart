import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

void main() {
  group('visible text', () {
    test('shows the partial alone before any segment is committed', () {
      const state = DictationState(partialText: 'السلام');
      expect(state.visibleText, 'السلام');
    });

    test('shows the committed text after the partial clears', () {
      const state = DictationState(committedText: 'hello world');
      expect(state.visibleText, 'hello world');
    });

    // The regression: a new segment's partial used to be glued to the committed
    // one until it was committed, then a space appeared and the text jumped.
    test('separates a live partial from the committed text with one space', () {
      const state = DictationState(
        committedText: 'السلام عليكم',
        partialText: 'كيف حالك',
      );
      expect(state.visibleText, 'السلام عليكم كيف حالك');
    });

    test('never doubles the space the model already sent', () {
      const afterCommitted = DictationState(
        committedText: 'hello ',
        partialText: 'world',
      );
      const beforePartial = DictationState(
        committedText: 'hello',
        partialText: ' world',
      );
      expect(afterCommitted.visibleText, 'hello world');
      expect(beforePartial.visibleText, 'hello world');
    });
  });
}
