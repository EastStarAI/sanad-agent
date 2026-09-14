import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:test/test.dart';

void main() {
  group('Message tool result', () {
    test('legacy content-only tool message parses unchanged', () {
      final message = Message.fromJson({
        'role': 'tool',
        'content': 'legacy output',
        'toolCallId': 'call-1',
      });

      expect(message.role, MessageRole.tool);
      expect(message.content, 'legacy output');
      expect(message.toolResult, isNull);
      expect(message.toJson()['toolResult'], isNull);
    });

    test('typed result supplies and round trips compatibility content', () {
      final result = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'before'),
          ToolImageBlock(
            dataBase64: base64.encode(const [0, 1, 2]),
            mimeType: 'image/png',
            width: 1,
            height: 1,
            detail: ToolImageDetail.auto,
          ),
          ToolTextBlock(text: 'after'),
        ],
      );
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call-2',
        toolResult: result,
      );

      final json = message.toJson();
      final restored = Message.fromJson(json);

      expect(message.content, 'before\nafter');
      expect(json['content'], 'before\nafter');
      expect(
        (json['toolResult']['blocks'] as List).map((block) => block['type']),
        ['text', 'image', 'text'],
      );
      expect(restored.toolResult?.displayText, 'before\nafter');
      expect(restored.toolResult?.blocks[1], isA<ToolImageBlock>());
    });

    test('rejects rich results on non-tool roles', () {
      expect(
        () => Message(
          role: MessageRole.assistant,
          toolResult: ToolExecutionResult.text('invalid'),
        ),
        throwsArgumentError,
      );
    });

    test('rejects divergent compatibility content during construction', () {
      expect(
        () => Message(
          role: MessageRole.tool,
          content: 'divergent',
          toolResult: ToolExecutionResult.text('authoritative'),
        ),
        throwsArgumentError,
      );
    });

    test('rejects divergent compatibility content during JSON parsing', () {
      final json = Message(
        role: MessageRole.tool,
        toolResult: ToolExecutionResult.text('authoritative'),
      ).toJson()..['content'] = 'divergent';

      expect(() => Message.fromJson(json), throwsArgumentError);
    });

    test('copyWith preserves, replaces, and clears typed results', () {
      final original = Message(
        role: MessageRole.tool,
        toolResult: ToolExecutionResult.text('first'),
      );

      final preserved = original.copyWith();
      final replaced = original.copyWith(
        toolResult: ToolExecutionResult.text('second'),
      );
      final cleared = original.copyWith(clearToolResult: true);

      expect(preserved.toolResult?.displayText, 'first');
      expect(replaced.toolResult?.displayText, 'second');
      expect(replaced.content, 'second');
      expect(cleared.toolResult, isNull);
      expect(cleared.content, 'first');
    });
  });
}
