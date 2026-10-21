import 'dart:convert';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/compaction_summarizer.dart';
import 'package:sanad_agent/engine/context/compaction_tail_selector.dart';
import 'package:sanad_agent/engine/context/compaction_tool_pruner.dart';
import 'package:sanad_agent/engine/context/context_compaction_engine.dart';
import 'package:test/test.dart';

void main() {
  group('CompactionToolPruner G6 Structured-Result Pruning Integrity', () {
    test('plain legacy text: truncates long content and keeps hint without toolResult', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 25);
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call_legacy_1',
        content: 'plain legacy text exceeding limit with ok status',
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: message),
      ];

      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 5,
      );

      final resultMessage = pruned.single.message;
      expect(resultMessage.toolResult, isNull);
      expect(resultMessage.content, contains('[truncated for compaction; tool_call_id=call_legacy_1; status=ok]'));
      expect(resultMessage.toolCallId, 'call_legacy_1');
    });

    test('structured text: prunes ToolExecutionResult and keeps content == toolResult.displayText', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 30);
      final structured = ToolExecutionResult.text('long structured text result content that exceeds the maximum limit for pruning');
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call_struct_1',
        toolResult: structured,
        metadata: {'test_key': 'test_val'},
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: message),
      ];

      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 10,
      );

      final resultMessage = pruned.single.message;
      expect(resultMessage.toolResult, isNotNull);
      expect(resultMessage.content, resultMessage.toolResult!.displayText);
      expect(resultMessage.content, contains('[truncated for compaction; tool_call_id=call_struct_1; status=ok]'));
      expect(resultMessage.toolResult!.schemaVersion, structured.schemaVersion);
      expect(resultMessage.toolResult!.isError, isFalse);
      expect(resultMessage.toolResult!.errorCode, isNull);
      expect(resultMessage.toolCallId, 'call_struct_1');
      expect(resultMessage.metadata?['test_key'], 'test_val');
    });

    test('error results: preserves isError and errorCode while reflecting status=error in truncation hint', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 20);
      final structured = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'An unhandled exception occurred during command processing in the engine'),
        ],
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call_err_1',
        toolResult: structured,
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: message),
      ];

      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 5,
      );

      final resultMessage = pruned.single.message;
      expect(resultMessage.toolResult!.isError, isTrue);
      expect(resultMessage.toolResult!.errorCode, ToolResultErrorCode.executionFailed);
      expect(resultMessage.content, contains('status=error'));
      expect(resultMessage.content, resultMessage.toolResult!.displayText);
    });

    test('mixed text and image blocks: forSummarizer replaces image with description and keeps invariants', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 1200);
      final imageBytes = [1, 2, 3, 4, 5, 6, 7, 8];
      final structured = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'Here is the rendered chart:'),
          ToolImageBlock(
            dataBase64: base64.encode(imageBytes),
            mimeType: 'image/png',
            width: 100,
            height: 100,
            detail: ToolImageDetail.high,
          ),
        ],
      );
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call_img_1',
        toolResult: structured,
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: message),
      ];

      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 5,
      );

      final resultMessage = pruned.single.message;
      expect(resultMessage.toolResult!.blocks.any((b) => b is ToolImageBlock), isFalse);
      expect(resultMessage.content, contains('media omitted for compaction summary: 8 bytes'));
      expect(resultMessage.content, resultMessage.toolResult!.displayText);
    });

    test('mixed text and image blocks: pruneOversizedForProjection preserves ToolImageBlock and truncates oversized text', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 20);
      final imageBytes = [1, 2, 3, 4];
      final structured = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'very long text description in projection that must be truncated'),
          ToolImageBlock(
            dataBase64: base64.encode(imageBytes),
            mimeType: 'image/png',
            width: 50,
            height: 50,
            detail: ToolImageDetail.auto,
          ),
        ],
      );
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call_proj_1',
        toolResult: structured,
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: message),
      ];

      final pruned = pruner.pruneOversizedForProjection(messages);

      final resultMessage = pruned.single.message;
      // Image block must be preserved, not emptied or omitted
      expect(resultMessage.toolResult!.blocks.any((b) => b is ToolImageBlock), isTrue);
      final img = resultMessage.toolResult!.blocks.whereType<ToolImageBlock>().single;
      expect(img.dataBase64, base64.encode(imageBytes));
      expect(resultMessage.content, contains('[truncated for compaction; tool_call_id=call_proj_1; status=ok]'));
      expect(resultMessage.content, resultMessage.toolResult!.displayText);
    });

    test('source-media replacement: data-uri or media_bytes metadata transforms toolResult coherently', () {
      const pruner = CompactionToolPruner();
      final structured = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'data:image/png;base64,${'A' * 80}'),
        ],
      );
      final message = Message(
        role: MessageRole.tool,
        toolCallId: 'call_uri_1',
        toolResult: structured,
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: message),
      ];

      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 5,
      );

      final resultMessage = pruned.single.message;
      expect(resultMessage.content, contains('media omitted for compaction summary: image/png data-uri'));
      expect(resultMessage.content, resultMessage.toolResult!.displayText);
    });

    test('canonical input records and protected tail messages remain completely untouched and immutable', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 20);
      final longText = 'y' * 100;
      final originalToolResult = ToolExecutionResult.text(longText);
      final tailToolResult = ToolExecutionResult.text('protected tail content');
      final msg1 = Message(
        role: MessageRole.tool,
        toolCallId: 'call_1',
        toolResult: originalToolResult,
      );
      final msg2 = Message(
        role: MessageRole.tool,
        toolCallId: 'call_2',
        toolResult: tailToolResult,
      );
      final messages = [
        IndexedConversationMessage(rowId: 1, message: msg1),
        IndexedConversationMessage(rowId: 5, message: msg2),
      ];

      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 5,
      );

      // Input objects must be untouched
      expect(msg1.content, longText);
      expect(msg1.toolResult?.displayText, longText);
      expect(msg2.content, 'protected tail content');
      expect(pruned.last.message, same(msg2));
      expect(pruned.first.message.content, isNot(longText));
      expect(pruned.first.message.content, pruned.first.message.toolResult!.displayText);
    });

    test('ContextCompactionEngine candidate build succeeds with structured tool results without ArgumentError', () async {
      final engine = ContextCompactionEngine(
        summarizer: StructuredCompactionSummarizer(),
        toolPruner: const CompactionToolPruner(maxToolResultChars: 50),
      );
      final structured = ToolExecutionResult.text('long tool output that exceeds fifty characters ' * 10);
      final timeline = <IndexedConversationMessage>[
        IndexedConversationMessage(
          rowId: 1,
          message: Message(
            role: MessageRole.user,
            content: 'goal: complete implementation of Wave A',
          ),
        ),
        IndexedConversationMessage(
          rowId: 2,
          message: Message(
            role: MessageRole.assistant,
            content: 'running tool now',
            toolCalls: [
              ToolCall(id: 'call_1', name: 'run_test', arguments: const {}),
            ],
          ),
        ),
        IndexedConversationMessage(
          rowId: 3,
          message: Message(
            role: MessageRole.tool,
            toolCallId: 'call_1',
            toolResult: structured,
          ),
        ),
        for (var i = 4; i <= 20; i++)
          IndexedConversationMessage(
            rowId: i,
            message: Message(
              role: MessageRole.user,
              content: 'status update turn $i ${'x' * 60}',
            ),
          ),
      ];

      final request = CompactionEngineRequest(
        compactionId: 'cmp-test-1',
        sessionId: 'session-test-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: const CompactionHistoryRevision(1),
        routeSignature: const RouteSignature(
          providerInstanceId: 'provider-1',
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://api.example.com/v1',
          modelId: 'gpt-4o',
          configRevision: 1,
          credentialRevision: 1,
        ),
        contextWindowTokens: 4000,
        timeline: timeline,
        systemPrompt: 'system prompt',
        runtimeContext: '',
        toolSchemas: const [],
        // Above the complete-request target, so manual compaction has work.
        targetRequestTokens: 100,
      );

      final candidate = await engine.buildCandidate(request, force: true);
      expect(candidate, isNotNull);
      expect(candidate!.internalSummary.currentGoal, isNotEmpty);
      expect(candidate.sourceRange.start.rowId, 1);
    });
  });
}
