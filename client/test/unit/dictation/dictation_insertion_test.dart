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

    test('an empty update clears the owned range', () {
      insertion.apply(controller, 'text');
      expect(controller.text, 'text');

      insertion.apply(controller, '');
      expect(controller.text, '');
      expect(insertion.hasRange, isFalse);
    });
  });
}
