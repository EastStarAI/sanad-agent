import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';

void main() {
  group('SlashCommandTextController', () {
    test('exports selected slash command tokens back to plain text', () {
      final controller = SlashCommandTextController();
      const originalValue = TextEditingValue(
        text: 'please /tes help',
        selection: TextSelection.collapsed(offset: 12),
      );
      final query = SkillComposerUtils.detectSlashQuery(originalValue)!;

      controller.value = controller.applySlashCommandSelection(
        value: originalValue,
        query: query,
        entry: const SlashCommandEntry(
          sourceId: 'skills',
          command: 'test sanad plugin',
          insertText: 'test sanad plugin',
        ),
      );

      expect(controller.exportPlainText(), 'please test sanad plugin help');
    });

    test('exports selected slash command token metadata for dispatch rewriting', () {
      final controller = SlashCommandTextController();
      const originalValue = TextEditingValue(
        text: 'tell me about /sanad',
        selection: TextSelection.collapsed(offset: 20),
      );
      final query = SkillComposerUtils.detectSlashQuery(originalValue)!;

      controller.value = controller.applySlashCommandSelection(
        value: originalValue,
        query: query,
        entry: const SlashCommandEntry(
          sourceId: 'skills',
          command: 'Sanad Agentic Developer',
          insertText: 'Sanad Agentic Developer',
        ),
      );

      final exported = controller.exportForDispatch();

      expect(exported.plainText, 'tell me about Sanad Agentic Developer ');
      expect(exported.tokens, hasLength(1));
      expect(exported.tokens.single.entry.command, 'Sanad Agentic Developer');
      expect(exported.tokens.single.start, 'tell me about '.length);
    });

    test('removes the whole token when the marker is deleted', () {
      final controller = SlashCommandTextController();
      const originalValue = TextEditingValue(
        text: 'please /review',
        selection: TextSelection.collapsed(offset: 14),
      );
      final query = SkillComposerUtils.detectSlashQuery(originalValue)!;

      controller.value = controller.applySlashCommandSelection(
        value: originalValue,
        query: query,
        entry: const SlashCommandEntry(sourceId: 'skills', command: 'review', insertText: 'review'),
      );

      final markerIndex = controller.text.indexOf(RegExp(r'[\uE000-\uF8FF]'));
      controller.value = TextEditingValue(
        text: controller.text.replaceRange(markerIndex, markerIndex + 1, ''),
        selection: TextSelection.collapsed(offset: markerIndex),
      );

      expect(controller.exportPlainText().trim(), 'please');
    });
  });
}
