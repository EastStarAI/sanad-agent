import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/presentation/utils/dictation_insertion.dart';

void main() {
  late TextEditingController controller;
  late DictationInsertion insertion;

  setUp(() {
    controller = TextEditingController();
    insertion = DictationInsertion();
  });

  tearDown(() => controller.dispose());

  group('dictation insertion', () {
    test('writes at the caret and replaces only its own range', () {
      controller.value = const TextEditingValue(
        text: 'hello ',
        selection: TextSelection.collapsed(offset: 6),
      );

      insertion.apply(controller, 'السلام');
      expect(controller.text, 'hello السلام');

      insertion.apply(controller, 'السلام عليكم');
      expect(controller.text, 'hello السلام عليكم');
      expect(insertion.hasRange, isTrue);
    });

    test('a manual edit inside the range is preserved', () {
      controller.value = const TextEditingValue(
        text: 'abc ',
        selection: TextSelection.collapsed(offset: 4),
      );
      insertion.apply(controller, 'first');

      // User edits the dictation-owned text.
      controller.text = 'abc firXT';
      controller.selection = const TextSelection.collapsed(offset: 9);

      insertion.apply(controller, 'first second');

      expect(controller.text.contains('firXT'), isTrue);
      expect(controller.text.contains('second'), isTrue);
      expect(controller.text.contains('first second'), isFalse);
    });

    test('removing the owned range keeps user text intact', () {
      controller.value = const TextEditingValue(
        text: 'keep me ',
        selection: TextSelection.collapsed(offset: 8),
      );
      insertion.apply(controller, 'dictated words');
      expect(controller.text, 'keep me dictated words');

      insertion.removeOwned(controller);
      expect(controller.text, 'keep me ');
      expect(insertion.hasRange, isFalse);
    });

    test('a live IME composition defers the write until it ends', () {
      controller.value = const TextEditingValue(
        text: 'كت',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );

      insertion.apply(controller, 'نص مُملَى');
      expect(controller.text, 'كت');
      expect(insertion.hasPending, isTrue);

      controller.value = const TextEditingValue(
        text: 'كت',
        selection: TextSelection.collapsed(offset: 2),
      );
      insertion.flushPending(controller);
      expect(controller.text, 'كت نص مُملَى');
      expect(insertion.hasPending, isFalse);
    });

    test('a caret outside the owned range keeps its place', () {
      controller.value = const TextEditingValue(
        text: 'abc ',
        selection: TextSelection.collapsed(offset: 4),
      );
      insertion.apply(controller, 'one');
      expect(controller.text, 'abc one');

      // The user moves to the start while dictation keeps writing.
      controller.selection = const TextSelection.collapsed(offset: 0);
      insertion.apply(controller, 'one two');
      expect(controller.text, 'abc one two');
      expect(controller.selection.baseOffset, 0);
    });

    test('a caret inside the owned range follows the replaced text', () {
      controller.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
      insertion.apply(controller, 'one');
      expect(controller.selection.baseOffset, 3);

      controller.selection = const TextSelection.collapsed(offset: 1);
      insertion.apply(controller, 'one two');
      expect(controller.text, 'one two');
      expect(controller.selection.baseOffset, 7);
    });

    test('an empty update clears the owned range', () {
      insertion.apply(controller, 'text');
      expect(controller.text, 'text');

      insertion.apply(controller, '');
      expect(controller.text, '');
      expect(insertion.hasRange, isFalse);
    });

    // The regression: after the range was lost (a rebuild, a transient empty
    // partial), the next write appended the session text to the copy already in
    // the composer, so one phrase appeared twice.
    test('a lost range replaces the session text instead of appending it', () {
      controller.value = const TextEditingValue(
        text: 'draft: ',
        selection: TextSelection.collapsed(offset: 7),
      );
      insertion.begin(controller);
      insertion.apply(
        controller,
        'The lazy dog. the quick brown fox jump',
        previous: '',
      );
      expect(controller.text, 'draft: The lazy dog. the quick brown fox jump');

      final lost = DictationInsertion()..begin(controller);
      lost.apply(
        controller,
        'The lazy dog. the quick brown fox jumps over the lazy dog',
        previous: 'The lazy dog. the quick brown fox jump',
      );

      expect(
        controller.text,
        'draft: The lazy dog. the quick brown fox jumps over the lazy dog',
      );
      expect(RegExp('The lazy dog').allMatches(controller.text), hasLength(1));
    });

    test('recovery never rewrites text the user typed', () {
      controller.value = const TextEditingValue(
        text: 'mine: dictated',
        selection: TextSelection.collapsed(offset: 15),
      );
      final fresh = DictationInsertion();

      // The remembered text is gone from the composer, so nothing is replaced
      // and the new text lands at the caret.
      fresh.apply(controller, 'next', previous: 'dictated elsewhere');
      expect(controller.text, 'mine: dictated next');
    });
  });
}
