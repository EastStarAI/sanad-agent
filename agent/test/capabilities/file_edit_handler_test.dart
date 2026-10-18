import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_edit_handler.dart';
import 'package:test/test.dart';

void main() {
  group('FileEditHandler Tests', () {
    late Directory tempDir;
    late FileEditHandler handler;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'file-edit-handler-test-',
      );
      handler = const FileEditHandler(WorkspacePathResolver());
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('Smart Replacers', () {
      test('handles simple exact match and replace', () async {
        final testFile = File(p.join(tempDir.path, 'edit_test.txt'));
        await testFile.writeAsString('hello world');

        final editRaw = await handler.execute({
          'path': 'edit_test.txt',
          'old_string': 'world',
          'new_string': 'sanad',
        }, tempDir.path);
        final edited = jsonDecode(editRaw) as Map<String, dynamic>;
        expect(edited['numReplacements'], 1);
        expect(await testFile.readAsString(), 'hello sanad');
      });

      test(
        'handles line trimmed replacement (ignoring leading/trailing line spacing)',
        () async {
          final testFile = File(p.join(tempDir.path, 'edit_trimmed.txt'));
          await testFile.writeAsString(
            '  line one  \n  line two  \nline three',
          );

          await handler.execute({
            'path': 'edit_trimmed.txt',
            'old_string': 'line one\nline two',
            'new_string': 'line 1\nline 2',
          }, tempDir.path);
          expect(await testFile.readAsString(), 'line 1\nline 2\nline three');
        },
      );

      test('handles whitespace normalized replacement', () async {
        final testFile = File(p.join(tempDir.path, 'edit_whitespace.txt'));
        await testFile.writeAsString('hello      beautiful   world');

        await handler.execute({
          'path': 'edit_whitespace.txt',
          'old_string': 'hello beautiful world',
          'new_string': 'hello world',
        }, tempDir.path);
        expect(await testFile.readAsString(), 'hello world');
      });

      test('handles BlockAnchorReplacer using Levenshtein distance', () async {
        final testFile = File(p.join(tempDir.path, 'edit_anchors.txt'));
        await testFile.writeAsString(
          'START_HEADER\nsome middle text that LLM might slightly misspell\nEND_FOOTER',
        );

        await handler.execute({
          'path': 'edit_anchors.txt',
          'old_string':
              'START_HEADER\nsome middle text that LLM misspelled slightly\nEND_FOOTER',
          'new_string': 'START_HEADER\nperfect middle text\nEND_FOOTER',
        }, tempDir.path);
        expect(
          await testFile.readAsString(),
          'START_HEADER\nperfect middle text\nEND_FOOTER',
        );
      });

      test(
        'handles Windows CRLF and Unix LF normalization automatically',
        () async {
          final testFile = File(p.join(tempDir.path, 'edit_crlf.txt'));
          await testFile.writeAsString('line1\r\nline2\r\nline3\r\n');

          await handler.execute({
            'path': 'edit_crlf.txt',
            'old_string': 'line2\nline3',
            'new_string': 'updated2\nupdated3',
          }, tempDir.path);
          expect(
            await testFile.readAsString(),
            'line1\r\nupdated2\r\nupdated3\r\n',
          );
        },
      );

      test(
        'throws StateError when old_string is not found (avoids Infinity or NaN toInt)',
        () async {
          final testFile = File(p.join(tempDir.path, 'not_found_test.txt'));
          await testFile.writeAsString('some content');

          expect(
            () => handler.execute({
              'path': 'not_found_test.txt',
              'old_string': 'nonexistent_string',
              'new_string': 'replacement',
            }, tempDir.path),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('old_string was not found in the target file'),
              ),
            ),
          );
        },
      );
    });

    group('Multi-chunk Edits', () {
      test('applies multiple non-contiguous edits in a single call', () async {
        final testFile = File(p.join(tempDir.path, 'multi_edit.txt'));
        final originalLines = List.generate(
          25,
          (i) => 'Line ${i + 1}: initial content',
        );
        await testFile.writeAsString(originalLines.join('\n'));

        final resultRaw = await handler.execute({
          'path': 'multi_edit.txt',
          'edits': [
            {
              'old_string': 'Line 5: initial content',
              'new_string': 'Line 5: updated content',
            },
            {
              'old_string': 'Line 20: initial content',
              'new_string': 'Line 20: updated content',
            },
          ],
        }, tempDir.path);

        final result = jsonDecode(resultRaw) as Map<String, dynamic>;
        expect(result['numReplacements'], 2);
        expect(result['numEdits'], 2);
        expect(result['startLine'], 5);
        expect(result['editStartLines'], [5, 20]);
        expect(result['patch'], contains('- Line 5: initial content'));
        expect(result['patch'], contains('+ Line 5: updated content'));
        expect(result['patch'], contains('---'));
        expect(result['patch'], contains('- Line 20: initial content'));
        expect(result['patch'], contains('+ Line 20: updated content'));

        final updatedContent = await testFile.readAsString();
        final lines = updatedContent.split('\n');
        expect(lines[4], 'Line 5: updated content');
        expect(lines[19], 'Line 20: updated content');
        expect(lines[0], 'Line 1: initial content');
        expect(lines[24], 'Line 25: initial content');
      });

      test('atomic failure: file is untouched if any chunk fails to match', () async {
        final testFile = File(p.join(tempDir.path, 'atomic_test.txt'));
        const original = 'Line 1\nLine 5: target\nLine 10\nLine 20: target\n';
        await testFile.writeAsString(original);

        expect(
          () => handler.execute({
            'path': 'atomic_test.txt',
            'edits': [
              {
                'old_string': 'Line 5: target',
                'new_string': 'Line 5: MODIFIED',
              },
              {
                'old_string': 'Line 999: non existent line',
                'new_string': 'Line 999: replacement',
              },
            ],
          }, tempDir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Edit #2'),
                contains('old_string was not found in the target file'),
              ),
            ),
          ),
        );

        // Entire file must remain unmodified!
        expect(await testFile.readAsString(), original);
      });

      test('overlap detection: rejects overlapping edit ranges safely', () async {
        final testFile = File(p.join(tempDir.path, 'overlap_test.txt'));
        const original = 'line A\nline B\nline C\nline D\nline E\n';
        await testFile.writeAsString(original);

        expect(
          () => handler.execute({
            'path': 'overlap_test.txt',
            'edits': [
              {
                'old_string': 'line B\nline C',
                'new_string': 'line B updated\nline C updated',
              },
              {
                'old_string': 'line C\nline D',
                'new_string': 'line C overlap\nline D overlap',
              },
            ],
          }, tempDir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Overlapping edits detected in target file'),
            ),
          ),
        );

        expect(await testFile.readAsString(), original);
      });

      test('preserves CRLF line endings across multiple edits', () async {
        final testFile = File(p.join(tempDir.path, 'multi_crlf.txt'));
        const original = 'line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n';
        await testFile.writeAsString(original);

        await handler.execute({
          'path': 'multi_crlf.txt',
          'edits': [
            {'old_string': 'line2', 'new_string': 'updated2'},
            {'old_string': 'line4', 'new_string': 'updated4'},
          ],
        }, tempDir.path);

        final result = await testFile.readAsString();
        expect(result, 'line1\r\nupdated2\r\nline3\r\nupdated4\r\nline5\r\n');
        expect(result.contains('\r\n'), isTrue);
      });

      test('rejects empty or identical edit chunks', () async {
        final testFile = File(p.join(tempDir.path, 'validation_test.txt'));
        await testFile.writeAsString('content');

        expect(
          () => handler.execute({
            'path': 'validation_test.txt',
            'edits': [
              {'old_string': '', 'new_string': 'something'},
            ],
          }, tempDir.path),
          throwsA(isA<FormatException>()),
        );

        expect(
          () => handler.execute({
            'path': 'validation_test.txt',
            'edits': [
              {'old_string': 'same', 'new_string': 'same'},
            ],
          }, tempDir.path),
          throwsA(isA<StateError>()),
        );
      });
    });
  });
}
