import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/context/compaction_token_estimator.dart';
import 'package:test/test.dart';

void main() {
  group('CompactionTokenEstimator', () {
    test('estimates plain text at charsPerToken ratio', () {
      expect(CompactionTokenEstimator.estimateText(''), 0);
      expect(CompactionTokenEstimator.estimateText(null), 0);
      expect(CompactionTokenEstimator.estimateText('1234'), 1);
      expect(CompactionTokenEstimator.estimateText('12345'), 2);
      expect(CompactionTokenEstimator.estimateText('a' * 400), 100);
    });

    test('excludes message thought and reasoning from wire token estimation', () {
      final message = Message(
        role: MessageRole.assistant,
        content: 'Hello, world!', // 13 chars -> 4 tokens
        thought: 't' * 4000, // 1000 tokens of internal thought
        reasoning: 'r' * 8000, // 2000 tokens of internal reasoning
      );

      final tokens = CompactionTokenEstimator.estimateMessage(message);
      // Only content (13 chars / 4 = 4 tokens) must be counted
      expect(tokens, 4);
    });

    test('excludes message providerState from wire token estimation', () {
      final message = Message(
        role: MessageRole.assistant,
        content: 'Response content', // 16 chars -> 4 tokens
        providerState: const LLMProviderState(
          namespace: 'sanad.evolution',
          issuer: 'openai|chat_completions|https://api.openai.com/v1',
          data: {
            'session_id': 'sess-1234567890',
            'encrypted_payload': 'huge_encrypted_blob_that_never_reaches_model',
            'reasoning_details': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
          },
        ),
      );

      final tokens = CompactionTokenEstimator.estimateMessage(message);
      expect(tokens, 4);
    });

    test('accurately prices tool calls and arguments', () {
      final message = Message(
        role: MessageRole.assistant,
        content: null,
        toolCalls: [
          ToolCall(
            id: 'call_123',
            name: 'browse_workspace',
            arguments: const {'path': '/src', 'recursive': true},
          ),
        ],
      );

      final tokens = CompactionTokenEstimator.estimateMessage(message);
      // name: 16 chars -> 4
      // jsonEncode(arguments): '{"path":"/src","recursive":true}' (32 chars) -> 8
      // id: 'call_123' (8 chars) -> 2
      // total = 14
      expect(tokens, 14);
    });

    test('accurately prices tool result messages with toolCallId', () {
      final message = Message(
        role: MessageRole.tool,
        content: '{"success": true}', // 17 chars -> 5 tokens
        toolCallId: 'call_123', // 8 chars -> 2 tokens
      );

      final tokens = CompactionTokenEstimator.estimateMessage(message);
      expect(tokens, 7);
    });

    test('prices media payloads using byte accounting rather than naive chars/4', () {
      final base64Image = 'data:image/png;base64,${'A' * 4096}';
      final message = Message(
        role: MessageRole.user,
        content: base64Image,
      );

      final textTokens = CompactionTokenEstimator.estimateMessage(message);
      // data URI is recognized as media payload and excluded from text estimation
      expect(textTokens, 0);

      final mediaTokens = CompactionTokenEstimator.estimateMediaTokens([message]);
      expect(mediaTokens, greaterThan(0));
      // 4096 base64 chars is ~3 KiB -> ~255 media tokens (3 * 85), far less than 1024 text tokens
      expect(mediaTokens, lessThan(400));
    });
  });
}
