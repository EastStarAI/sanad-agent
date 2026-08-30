import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';

void main() {
  group('SkillComposerUtils', () {
    test('detectRuntimeSlashQuery handles slash at message start', () {
      const value = TextEditingValue(text: '/tes', selection: TextSelection.collapsed(offset: 4));

      final query = SkillComposerUtils.detectRuntimeSlashQuery(value);

      expect(query, isNotNull);
      expect(query!.slashIndex, 0);
      expect(query.query, 'tes');
    });

    test('detectSlashQuery ignores slash at message start', () {
      const value = TextEditingValue(text: '/tes', selection: TextSelection.collapsed(offset: 4));

      expect(SkillComposerUtils.detectSlashQuery(value), isNull);
    });

    test('detects slash query in the middle of the message', () {
      const value = TextEditingValue(text: 'please /tes', selection: TextSelection.collapsed(offset: 11));

      final query = SkillComposerUtils.detectSlashQuery(value);

      expect(query, isNotNull);
      expect(query!.slashIndex, 7);
      expect(query.query, 'tes');
    });

    test('detectRuntimeSlashQuery keeps spaces in runtime command token', () {
      const value = TextEditingValue(text: '/test sanad', selection: TextSelection.collapsed(offset: 11));

      final query = SkillComposerUtils.detectRuntimeSlashQuery(value);

      expect(query, isNotNull);
      expect(query!.query, 'test sanad');
    });

    test('exits slash query when the user types a second space', () {
      const value = TextEditingValue(text: '/test sanad client', selection: TextSelection.collapsed(offset: 18));

      expect(SkillComposerUtils.detectRuntimeSlashQuery(value), isNull);
      expect(SkillComposerUtils.detectSlashQuery(value), isNull);
    });

    test('ignores slashes that are not token-prefixed by whitespace', () {
      const value = TextEditingValue(text: 'path/to/file', selection: TextSelection.collapsed(offset: 12));

      final query = SkillComposerUtils.detectSlashQuery(value);

      expect(query, isNull);
    });

    test('applies selected skill into the current token range', () {
      const value = TextEditingValue(text: 'please /tes now', selection: TextSelection.collapsed(offset: 11));
      final query = SkillComposerUtils.detectSlashQuery(value)!;

      final updated = SkillComposerUtils.applySkillSelection(value, query: query, skillName: 'test-sanad-plugin');

      expect(updated.text, 'please test-sanad-plugin now');
      expect(updated.selection.baseOffset, 'please test-sanad-plugin'.length);
    });

    test('normalizes spaces and separators for slash matching', () {
      expect(SkillComposerUtils.normalizeSlashSearchToken('Test Sanad_Plugin'), 'testsanadplugin');
    });
  });
}
