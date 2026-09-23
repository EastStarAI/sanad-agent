import 'dart:io';

import 'package:sanad_workflow_guards/merge_validate.dart';
import 'package:test/test.dart';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('wf-guards-merge-');
  });

  tearDown(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  String write(String name, String content) {
    final file = File('${sandbox.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file.path;
  }

  test('clean markdown/text files are accepted', () {
    final path = write('clean.md', '# Plan97\n\nNo conflict here.\n');
    final result = validateResolvedFile(path);
    expect(result.verdict, MergeVerdict.ok);
    expect(result.exitCode, 0);
  });

  test('unresolved conflict markers are rejected with line numbers', () {
    final path = write(
      'conflict.dart',
      '<<<<'
          '<<< HEAD\n'
          'final a = 1;\n'
          '===='
          '===\n'
          'final a = 2;\n'
          '>>>>'
          '>>> feature\n',
    );
    final result = validateResolvedFile(path);
    expect(result.verdict, MergeVerdict.conflictMarkers);
    expect(result.exitCode, 3);
    expect(result.markerLines, containsAllInOrder([1, 3, 5]));
  });

  test('diff3-style markers are rejected too', () {
    final path = write(
      'conflict3.txt',
      '||||||| base\nvalue\n>>>>>>> theirs\n',
    );
    expect(validateResolvedFile(path).verdict, MergeVerdict.conflictMarkers);
  });

  test('valid JSON parses and passes', () {
    final path = write('data.json', '{"a": [1, 2, 3], "b": "x"}\n');
    expect(validateResolvedFile(path).verdict, MergeVerdict.ok);
  });

  test('corrupt JSON is rejected as corrupt syntax', () {
    final path = write('data.json', '{"a": [1, 2,\n');
    final result = validateResolvedFile(path);
    expect(result.verdict, MergeVerdict.corruptSyntax);
    expect(result.exitCode, 4);
    expect(result.error, contains('invalid JSON'));
  });

  test('JSONL validates each line independently', () {
    final valid = write('events.jsonl', '{"seq":1}\n{"seq":2}\n');
    expect(validateResolvedFile(valid).verdict, MergeVerdict.ok);

    final broken = write('broken.jsonl', '{"seq":1}\nnot-json\n');
    final result = validateResolvedFile(broken);
    expect(result.verdict, MergeVerdict.corruptSyntax);
    expect(result.error, contains('line 2'));
  });

  test('CRLF line endings do not hide markers', () {
    final path = write(
      'win.txt',
      '<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\n',
    );
    expect(validateResolvedFile(path).verdict, MergeVerdict.conflictMarkers);
  });

  test('missing files are reported and never staged', () {
    final result = validateResolvedFile(
      '${sandbox.path}${Platform.pathSeparator}nope.dart',
    );
    expect(result.verdict, MergeVerdict.missing);
    expect(result.exitCode, 2);
  });

  test('UTF-8 BOM is tolerated before validation', () {
    final path = write('bom.json', '\uFEFF{"ok": true}\n');
    expect(validateResolvedFile(path).verdict, MergeVerdict.ok);
  });
}
