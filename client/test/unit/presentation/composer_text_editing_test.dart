import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_text_editing.dart';

void main() {
  group('insertDroppedPathsAtSelection', () {
    test('inserts paths at the collapsed caret', () {
      const value = TextEditingValue(
        text: 'open this please',
        selection: TextSelection.collapsed(offset: 5),
      );

      final result = insertDroppedPathsAtSelection(value, const [
        '/tmp/one.txt',
        '/tmp/two.txt',
      ]);

      expect(
        result.text,
        'open /tmp/one.txt /tmp/two.txt this please',
      );
      expect(result.selection.isCollapsed, isTrue);
      expect(result.selection.baseOffset, 31);
    });

    test('replaces the selected range and keeps surrounding spacing', () {
      const value = TextEditingValue(
        text: 'open old file please',
        selection: TextSelection(baseOffset: 5, extentOffset: 13),
      );

      final result = insertDroppedPathsAtSelection(value, const [
        '/tmp/new.txt',
      ]);

      expect(result.text, 'open /tmp/new.txt please');
      expect(result.selection.baseOffset, 17);
    });

    test('falls back to the end for an invalid selection', () {
      const value = TextEditingValue(text: 'open');

      final result = insertDroppedPathsAtSelection(value, const [
        '/tmp/file.txt',
      ]);

      expect(result.text, 'open /tmp/file.txt ');
      expect(result.selection.baseOffset, result.text.length);
    });
  });
}
