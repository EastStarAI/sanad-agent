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

    test('inserts file path token and exports as [name](file:///...)', () {
      final controller = SlashCommandTextController();
      controller.value = const TextEditingValue(
        text: 'look at this file: ',
        selection: TextSelection.collapsed(offset: 19),
      );

      controller.insertFileToken('/Users/user/documents/report.pdf');

      expect(controller.text, startsWith('look at this file: '));
      // In the editor text, the file path is NOT visible as plain text; only the marker exists
      expect(controller.text.contains('/Users/user/documents/report.pdf'), isFalse);
      expect(controller.fileTokensByMarker, hasLength(1));

      final exported = controller.exportPlainText();
      expect(exported, 'look at this file: [report.pdf](file:///Users/user/documents/report.pdf) ');
    });

    test('prunes file token when marker is removed from text', () {
      final controller = SlashCommandTextController();
      controller.insertFileToken('/tmp/test.txt');
      expect(controller.fileTokensByMarker, hasLength(1));

      // Remove the marker
      controller.text = '';
      expect(controller.fileTokensByMarker, isEmpty);
      expect(controller.exportPlainText(), '');
    });

    test('setDraftText restores known file links into tokens and preserves non-file text', () {
      final controller = SlashCommandTextController();
      const draft = 'Check [report.pdf](file:///Users/user/report.pdf) and [web](https://example.com) for details';

      controller.setDraftText(draft);

      expect(controller.fileTokensByMarker, hasLength(1));
      // The markdown file link is re-tokenized into a marker
      expect(controller.text.contains('file:///Users/user/report.pdf'), isFalse);
      // The http link remains unchanged
      expect(controller.text.contains('[web](https://example.com)'), isTrue);

      // Exporting reproduces the markdown file link exactly
      expect(controller.exportPlainText(), draft);
    });

    test('setDraftText with empty string clears all tokens', () {
      final controller = SlashCommandTextController();
      controller.insertFileToken('/tmp/one.txt');
      expect(controller.fileTokensByMarker, hasLength(1));

      controller.setDraftText('');
      expect(controller.fileTokensByMarker, isEmpty);
      expect(controller.text, isEmpty);
    });

    test('marker allocation wraps around and reuses freed markers without limit', () {
      final controller = SlashCommandTextController();
      for (int i = 0; i < 20; i++) {
        controller.insertFileToken('/tmp/file_$i.txt');
      }
      expect(controller.fileTokensByMarker, hasLength(20));

      // Clear controller, freeing all markers
      controller.text = '';
      expect(controller.fileTokensByMarker, isEmpty);

      // Inserting again should successfully allocate without throwing StateError
      expect(() => controller.insertFileToken('/tmp/new_file.txt'), returnsNormally);
      expect(controller.fileTokensByMarker, hasLength(1));
    });
  });
}

