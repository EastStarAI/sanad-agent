import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/history_image_pruner.dart';
import 'package:test/test.dart';

void main() {
  Message imageResult(
    String id, {
    List<int> bytes = const [1, 2, 3],
    bool isError = false,
  }) => Message(
    role: MessageRole.tool,
    toolCallId: id,
    metadata: {'tool_call_id': id, 'is_error': isError},
    toolResult: ToolExecutionResult(
      blocks: [
        ToolTextBlock(text: 'before-$id'),
        ToolImageBlock(
          dataBase64: base64.encode(bytes),
          mimeType: 'image/png',
          width: 1,
          height: 1,
          detail: ToolImageDetail.high,
        ),
        ToolTextBlock(text: 'after-$id'),
      ],
      isError: isError,
      errorCode: isError ? ToolResultErrorCode.processingFailed : null,
    ),
  );

  Message completedAssistant() =>
      Message(role: MessageRole.assistant, content: 'done');

  test('defaults lock three completed turns and a 24 MiB cap', () {
    expect(retainedCompletedImageTurns, 3);
    expect(maxRetainedHistoryImageBytes, 24 * 1024 * 1024);
  });

  test('prunes older than three completed turns and preserves exact shape', () {
    final old = imageResult('old', isError: true);
    final recent1 = imageResult('recent-1');
    final recent2 = imageResult('recent-2');
    final recent3 = imageResult('recent-3');
    final history = [
      old,
      completedAssistant(),
      recent1,
      completedAssistant(),
      recent2,
      completedAssistant(),
      recent3,
      completedAssistant(),
    ];

    final result = HistoryImagePruner.prune(history);
    final pruned = result.messages.first;

    expect(result.changed, isTrue);
    expect(pruned.toolCallId, old.toolCallId);
    expect(pruned.metadata, old.metadata);
    expect(pruned.toolResult!.isError, isTrue);
    expect(pruned.toolResult!.errorCode, ToolResultErrorCode.processingFailed);
    expect(pruned.toolResult!.blocks.map((block) => block.toJson()).toList(), [
      {'type': 'text', 'text': 'before-old'},
      {'type': 'text', 'text': prunedHistoryImageMarker},
      {'type': 'text', 'text': 'after-old'},
    ]);
    for (final index in [2, 4, 6]) {
      expect(
        result.messages[index].toolResult!.blocks[1],
        isA<ToolImageBlock>(),
      );
    }
  });

  test('assistant tool calls do not count as completed turns', () {
    final image = imageResult('loop');
    final history = [
      image,
      Message(
        role: MessageRole.assistant,
        toolCalls: [ToolCall(id: 'next', name: 'read', arguments: const {})],
      ),
      Message(
        role: MessageRole.tool,
        toolCallId: 'next',
        toolResult: ToolExecutionResult.text('next result'),
      ),
      completedAssistant(),
      completedAssistant(),
      completedAssistant(),
    ];

    final result = HistoryImagePruner.prune(history);

    expect(result.changed, isFalse);
    expect(result.messages.first.toolResult!.blocks[1], isA<ToolImageBlock>());
  });

  test(
    'byte cap prunes completed images oldest-first but protects current loop',
    () {
      final oldest = imageResult('oldest');
      final newer = imageResult('newer');
      final current = imageResult('current');
      final result = HistoryImagePruner.prune(
        [oldest, completedAssistant(), newer, completedAssistant(), current],
        recentCompletedTurns: 3,
        maxRetainedBytes: 4,
      );

      expect(result.changed, isTrue);
      expect(result.messages[0].toolResult!.blocks[1].toJson(), {
        'type': 'text',
        'text': prunedHistoryImageMarker,
      });
      expect(result.messages[2].toolResult!.blocks[1].toJson(), {
        'type': 'text',
        'text': prunedHistoryImageMarker,
      });
      expect(result.messages[4].toolResult!.blocks[1], isA<ToolImageBlock>());
      expect(result.retainedImageBytes, 3);
    },
  );

  test('transform is idempotent and leaves corrupt marker text unchanged', () {
    final first = HistoryImagePruner.prune([
      imageResult('old'),
      completedAssistant(),
    ], recentCompletedTurns: 0);
    final withCorruptMarker = [
      ...first.messages,
      Message(
        role: MessageRole.tool,
        toolCallId: 'corrupt',
        toolResult: ToolExecutionResult.text(
          '[Tool result unavailable: stored rich result is corrupt.]',
          isError: true,
          errorCode: ToolResultErrorCode.executionFailed,
        ),
      ),
    ];

    final second = HistoryImagePruner.prune(
      withCorruptMarker,
      recentCompletedTurns: 0,
    );

    expect(second.changed, isFalse);
    expect(
      second.messages.map((message) => message.toJson()).toList(),
      withCorruptMarker.map((message) => message.toJson()).toList(),
    );
  });
}
