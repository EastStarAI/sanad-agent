import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/file_reference_link.dart';

void main() {
  group('FileReferenceLink', () {
    test('round-trips names with brackets and paths with parentheses and spaces', () {
      const path = '/Users/me/Reports (2026)/q1 final).pdf';
      const name = 'q1 [final]).pdf';
      final link = FileReferenceLink.format(fileName: name, path: path);

      expect(link, r'[q1 \[final\]).pdf](file:///Users/me/Reports%20%282026%29/q1%20final%29.pdf)');
      final match = FileReferenceLink.pattern.firstMatch('see $link now');
      expect(match, isNotNull);
      final parsed = FileReferenceLink.parse(match!);
      expect(parsed?.fileName, name);
      expect(parsed?.path, path);
    });

    test('still matches links written with unescaped balanced parentheses', () {
      final match = FileReferenceLink.pattern.firstMatch('[a (1).pdf](file:///tmp/a%20(1).pdf)');
      expect(FileReferenceLink.parse(match!)?.path, '/tmp/a (1).pdf');
    });

    test('ignores non-file destinations', () {
      expect(FileReferenceLink.pattern.firstMatch('[docs](https://sanad.ai)'), isNull);
    });
  });

  group('SlashCommandTextController file tokens with special characters', () {
    test('a restored draft re-tokenizes the exported link and exports it identically', () {
      final controller = SlashCommandTextController();
      controller.insertFileToken('/Users/me/My (1) [draft].md', fileName: 'My (1) [draft].md');
      final exported = controller.exportPlainText();

      final restored = SlashCommandTextController()..setDraftText(exported);
      expect(restored.fileTokensByMarker, hasLength(1));
      expect(restored.fileTokensByMarker.values.single.path, '/Users/me/My (1) [draft].md');
      expect(restored.fileTokensByMarker.values.single.fileName, 'My (1) [draft].md');
      expect(restored.exportPlainText(), exported);
      expect(restored.text, isNot(contains('file://')));
    });
  });
}
