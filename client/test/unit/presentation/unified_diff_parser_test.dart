import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/diff/unified_diff_parser.dart';

void main() {
  group('parseAndPairDiff', () {
    test('renders context, removal, and addition rows in diff order', () {
      final rows = parseAndPairDiff(
        ' context line\n-removed line\n+added line',
        startLine: 5,
      );

      expect(rows, hasLength(3));
      expect(
        rows.map((row) => row.prefix).toList(),
        <String>[' ', '-', '+'],
      );
      expect(
        rows.map((row) => row.content).toList(),
        <String>['context line', 'removed line', 'added line'],
      );

      // The context row consumes both counters; the deletion keeps the old
      // counter and the addition keeps the new one.
      expect(rows[0].oldLineNumber, 5);
      expect(rows[0].newLineNumber, 5);
      expect(rows[1].oldLineNumber, 6);
      expect(rows[1].newLineNumber, isNull);
      expect(rows[2].oldLineNumber, isNull);
      expect(rows[2].newLineNumber, 6);
    });

    test('pairs each deletion with the addition on the same index', () {
      final rows = parseAndPairDiff('-a\n-b\n+c\nd');

      // Deletions stay grouped in front of their additions, and only the
      // shared indexes are paired.
      expect(rows.map((row) => row.prefix).toList(), <String>['-', '-', '+', ' ']);
      expect(rows[0].content, 'a');
      expect(rows[0].pairedContent, 'c');
      expect(rows[1].content, 'b');
      expect(rows[1].pairedContent, isNull);
      expect(rows[2].content, 'c');
      expect(rows[2].pairedContent, 'a');
      expect(rows[3].content, 'd');
      expect(rows[3].pairedContent, isNull);
    });

    test('pairs a lone addition with its deletion', () {
      final rows = parseAndPairDiff('-old\n+new');

      expect(rows[0].pairedContent, 'new');
      expect(rows[1].pairedContent, 'old');
    });

    test('leaves line numbers unset when no start line is supplied', () {
      final rows = parseAndPairDiff('+added\n context');

      expect(rows[0].oldLineNumber, isNull);
      expect(rows[0].newLineNumber, isNull);
      expect(rows[1].oldLineNumber, isNull);
      expect(rows[1].newLineNumber, isNull);
    });

    test('re-anchors every hunk at its reported start line', () {
      final rows = parseAndPairDiff(
        '-first\n+first updated\n---\n-second\n+second updated',
        startLine: 5,
        editStartLines: const <int>[5, 20],
      );

      expect(rows, hasLength(4));
      expect(rows[0].oldLineNumber, 5);
      expect(rows[1].newLineNumber, 5);
      // The second hunk restarts at 20 instead of continuing from 6.
      expect(rows[2].oldLineNumber, 20);
      expect(rows[3].newLineNumber, 20);
    });

    test('keeps the counter running when a hunk has no reported start line', () {
      final rows = parseAndPairDiff(
        '-first\n+first updated\n---\n-second\n+second updated',
        startLine: 5,
      );

      expect(rows[2].oldLineNumber, 6);
      expect(rows[3].newLineNumber, 6);
    });

    test('keeps the counter running past a separator with short anchors', () {
      final rows = parseAndPairDiff(
        '-first\n+first updated\n---\n-second\n+second updated',
        startLine: 5,
        editStartLines: const <int>[5],
      );

      // A separator whose index is past the anchors must not reset the counters.
      expect(rows[2].oldLineNumber, 6);
      expect(rows[3].newLineNumber, 6);
    });

    test('returns no rows for malformed or empty input', () {
      expect(parseAndPairDiff(''), isEmpty);
      expect(parseAndPairDiff('---'), isEmpty);
      expect(parseAndPairDiff('---\n---'), isEmpty);
    });

    test('treats an unprefixed line as context content', () {
      final rows = parseAndPairDiff('plain text', startLine: 3);

      expect(rows, hasLength(1));
      expect(rows.single.prefix, ' ');
      expect(rows.single.content, 'plain text');
      expect(rows.single.oldLineNumber, 3);
      expect(rows.single.newLineNumber, 3);
    });
  });

  group('parseEditStartLines', () {
    test('returns null without a payload or the key', () {
      expect(parseEditStartLines(null), isNull);
      expect(parseEditStartLines(<String, dynamic>{}), isNull);
      expect(parseEditStartLines(<String, dynamic>{'patch': '-a\n+b'}), isNull);
    });

    test('reads numeric and numeric-string anchors', () {
      expect(
        parseEditStartLines(<String, dynamic>{
          'editStartLines': <dynamic>[5, 20],
        }),
        <int>[5, 20],
      );
      expect(
        parseEditStartLines(<String, dynamic>{
          'editStartLines': <dynamic>['5', 20, '7'],
        }),
        <int>[5, 20, 7],
      );
    });

    test('returns null for a malformed anchor list', () {
      expect(
        parseEditStartLines(<String, dynamic>{
          'editStartLines': <dynamic>[5, 'not-a-line'],
        }),
        isNull,
      );
      expect(
        parseEditStartLines(<String, dynamic>{'editStartLines': '5,20'}),
        isNull,
      );
    });

    test('reads an empty anchor list as no anchors', () {
      expect(
        parseEditStartLines(<String, dynamic>{
          'editStartLines': <dynamic>[],
        }),
        isEmpty,
      );
    });
  });
}
