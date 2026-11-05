import 'dart:convert';

import 'package:sanad_agent/engine/context/context.dart';
import 'package:test/test.dart';

/// The continuity labels the extractor can produce, plus the section keys a
/// continuity result can carry.
const _repairableNames = <String>[
  'goal',
  'constraints',
  'pending ask',
  'pending_ask',
  'ask',
  'path',
  'blocker',
  'decision',
  'currentGoal',
  'latestUserRequest',
  'activeState',
  'criticalContext',
  'remainingWork',
];

/// Fields named by the instruction's repair sentence.
List<String> _repairFields(String instruction) {
  final match = RegExp(
    r'Ensure these fields are present and non-empty: ([^.]+)\.',
  ).firstMatch(instruction);
  if (match == null) return const [];
  return match
      .group(1)!
      .split(',')
      .map((field) => field.trim())
      .where((field) => field.isNotEmpty)
      .toList(growable: false);
}

String _summaryJson({
  Object? currentGoal = 'ship the anchored extraction',
  String extraKey = '',
}) => jsonEncode({
  'schemaVersion': 1,
  'currentGoal': currentGoal,
  'latestUserRequest': 'finish the verification',
  'successCriteria': 'tests pass',
  'constraints': 'none',
  'completedWork': 'discovery',
  'activeState': 'verifying',
  'criticalContext': 'route stays unchanged',
  'decisions': 'typed JSON',
  'blockers': 'none',
  'filesAndPaths': 'agent/lib/example.dart',
  'pendingAsks': 'finish',
  'remainingWork': 'run the suite',
  if (extraKey.isNotEmpty) extraKey: 'not part of the schema',
});

void main() {
  group('CompactionSummaryPrompt repair fields', () {
    test('every named repair field is a summary schema key', () {
      for (final name in _repairableNames) {
        final instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: [name],
        );
        final named = _repairFields(instruction);
        for (final field in named) {
          expect(
            CompactionSummaryPrompt.allowedKeys,
            contains(field),
            reason: 'repair for "$name" named the non-schema field "$field"',
          );
        }
      }
    });

    test('an ask anchor repairs the schema fields that carry it', () {
      final instruction = CompactionSummaryPrompt.buildJsonInstruction(
        missingFields: const ['ask'],
      );

      expect(_repairFields(instruction), [
        'pendingAsks',
        'latestUserRequest',
      ]);
      expect(
        instruction,
        isNot(matches(RegExp(r'Ensure[^.]*:\s*ask\b'))),
      );
    });

    test('anchor keys map onto their schema owners', () {
      expect(
        _repairFields(
          CompactionSummaryPrompt.buildJsonInstruction(
            missingFields: const ['goal', 'blocker', 'path', 'decision'],
          ),
        ),
        ['currentGoal', 'blockers', 'filesAndPaths', 'decisions'],
      );
      expect(
        _repairFields(
          CompactionSummaryPrompt.buildJsonInstruction(
            missingFields: const ['pending ask', 'pending_ask', 'constraints'],
          ),
        ),
        ['pendingAsks', 'constraints'],
      );
    });

    test('a name that has no schema field falls back to the fixed sentence', () {
      for (final name in ['valid JSON only; summary_invalid_json', 'task']) {
        final instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: [name],
        );

        expect(_repairFields(instruction), isEmpty);
        expect(instruction, isNot(contains('Your previous attempt was invalid')));
        expect(instruction, contains('Use exactly these keys'));
      }
    });

    test('a type mismatch still names only allowlisted keys', () {
      final instruction = CompactionSummaryPrompt.buildJsonInstruction(
        typeMismatches: const [CompactionSummaryFieldMismatch('filesAndPaths', 'object')],
      );

      expect(instruction, contains('the value of filesAndPaths must be'));
      expect(instruction, isNot(contains('Ensure these fields')));
    });
  });

  group('CompactionSummaryParser tolerates a duplicated object', () {
    test('a summary repeated back-to-back decodes its first object', () {
      final document = _summaryJson();

      final summary = CompactionSummaryParser.parse('$document$document');

      expect(summary.currentGoal, 'ship the anchored extraction');
      expect(summary.remainingWork, 'run the suite');
    });

    test('a duplicated object still rejects an unknown key', () {
      final document = _summaryJson(extraKey: 'ask');

      expect(
        () => CompactionSummaryParser.parse('$document$document'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('ask'),
          ),
        ),
      );
    });

    test('an unknown key in the first object is still rejected', () {
      final document = _summaryJson(extraKey: 'blocker');

      expect(
        () => CompactionSummaryParser.parse('$document${_summaryJson()}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('leading prose before the object is still invalid', () {
      expect(
        () => CompactionSummaryParser.parse('Here is the summary:\n${_summaryJson()}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a wrong-typed field inside a duplicated object still fails', () {
      final document = _summaryJson(currentGoal: {'nested': 'object'});

      expect(
        () => CompactionSummaryParser.parse('$document$document'),
        throwsA(isA<CompactionSummarySchemaMismatch>()),
      );
    });
  });
}
