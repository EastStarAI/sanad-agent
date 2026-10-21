// Task 111 G1: one session-scoped authority decides whether an active
// assistant row is the terminal result of its turn.

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/terminal_assistant_classifier.dart';
import 'package:test/test.dart';

Message _assistant(String content, {Map<String, dynamic>? metadata}) =>
    Message(role: MessageRole.assistant, content: content, metadata: metadata);

Message _root(String content) =>
    Message(role: MessageRole.user, content: content);

void main() {
  group('isTerminal', () {
    test('a stamped reply is terminal wherever it sits', () {
      final stamped = _assistant(
        'done',
        metadata: const {'terminal_work_item_id': 'w-1'},
      );
      expect(
        TerminalAssistantClassifier.isTerminal(
          stamped,
          next: _assistant('later'),
        ),
        isTrue,
      );
    });

    test('an unstamped reply that ends its turn is terminal', () {
      final reply = _assistant('answer');
      expect(
        TerminalAssistantClassifier.isTerminal(reply, next: _root('next')),
        isTrue,
      );
      expect(TerminalAssistantClassifier.isTerminal(reply, next: null), isTrue);
    });

    test('commentary followed by more assistant output is not terminal', () {
      expect(
        TerminalAssistantClassifier.isTerminal(
          _assistant('let me check'),
          next: _assistant('result'),
        ),
        isFalse,
      );
    });

    test('a reply followed by a steer in the same turn is not terminal', () {
      for (final steer in [
        Message(
          role: MessageRole.user,
          content: 'adjust',
          metadata: const {'steer': true},
        ),
        Message(
          role: MessageRole.user,
          content: 'adjust',
          metadata: const {'input_kind': 'steer'},
        ),
      ]) {
        expect(
          TerminalAssistantClassifier.isTerminal(
            _assistant('draft'),
            next: steer,
          ),
          isFalse,
        );
      }
    });

    test('tool calls, steer-superseded rows, and non-assistant rows are '
        'never terminal', () {
      final toolAsk = Message(
        role: MessageRole.assistant,
        content: 'reading',
        toolCalls: [ToolCall(id: 'c-1', name: 'read', arguments: const {})],
        metadata: const {'terminal_work_item_id': 'w-1'},
      );
      final superseded = _assistant(
        'before steer',
        metadata: const {
          'superseded_by_steer': true,
          'terminal_work_item_id': 'w-1',
        },
      );
      for (final message in [toolAsk, superseded, _root('question')]) {
        expect(
          TerminalAssistantClassifier.isTerminal(message, next: null),
          isFalse,
        );
      }
    });
  });

  group('carryForwardStamp', () {
    final stored = _assistant(
      'answer',
      metadata: const {
        'message_id': 'm-1',
        'terminal_work_item_id': 'w-1',
        'terminal_generation': 4,
      },
    );

    test('restores a stamp the replacement dropped', () {
      final replacement = _assistant(
        'answer',
        metadata: const {
          'message_id': 'm-1',
          'usage': {'output_tokens': 2},
        },
      );
      final merged = TerminalAssistantClassifier.carryForwardStamp(
        stored: stored,
        replacement: replacement,
      );
      expect(merged.metadata?['terminal_work_item_id'], 'w-1');
      expect(merged.metadata?['terminal_generation'], 4);
      expect(merged.metadata?['usage'], {'output_tokens': 2});
    });

    test('keeps a replacement that already carries its own stamp', () {
      final replacement = _assistant(
        'answer',
        metadata: const {
          'message_id': 'm-1',
          'terminal_work_item_id': 'w-2',
          'terminal_generation': 5,
        },
      );
      expect(
        identical(
          TerminalAssistantClassifier.carryForwardStamp(
            stored: stored,
            replacement: replacement,
          ),
          replacement,
        ),
        isTrue,
      );
    });

    test('never stamps an unstamped stored row or a non-assistant row', () {
      final plain = _assistant('answer', metadata: const {'message_id': 'm-1'});
      expect(
        identical(
          TerminalAssistantClassifier.carryForwardStamp(
            stored: plain,
            replacement: plain,
          ),
          plain,
        ),
        isTrue,
      );
      final user = Message(
        role: MessageRole.user,
        content: 'q',
        metadata: const {'message_id': 'm-1'},
      );
      expect(
        identical(
          TerminalAssistantClassifier.carryForwardStamp(
            stored: stored,
            replacement: user,
          ),
          user,
        ),
        isTrue,
      );
    });
  });
}
