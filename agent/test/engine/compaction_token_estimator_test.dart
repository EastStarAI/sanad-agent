import 'dart:convert';

import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
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

    test('prices an image from its observed dimensions, not its encoding', () {
      // 1203x1321 needs no scaling: 3x3 tiles of 512px.
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 1203, height: 1321),
        CompactionTokenEstimator.imageBaseTokens +
            CompactionTokenEstimator.imageTileTokens * 9,
      );
      // A tiny image is still scaled to the minimum short side (2x2 tiles).
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 1, height: 1),
        CompactionTokenEstimator.imageBaseTokens +
            CompactionTokenEstimator.imageTileTokens * 4,
      );
      // Largest accepted image: the documented per-image ceiling.
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 2048, height: 2048),
        CompactionTokenEstimator.maxImageTokensPerImage,
      );
      expect(
        CompactionTokenEstimator.estimateImageTokens(
          width: 2048,
          height: 2048,
          lowDetail: true,
        ),
        CompactionTokenEstimator.imageBaseTokens,
      );
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 0, height: 10),
        0,
      );
    });

    test('tool-result image accounting is dimension-based and counted once', () {
      final imageTokens = CompactionTokenEstimator.estimateImageTokens(
        width: 1203,
        height: 1321,
      );
      final toolResult = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'rendered view'),
          ToolImageBlock(
            dataBase64: base64Encode(List<int>.filled(120000, 7)),
            mimeType: 'image/png',
            width: 1203,
            height: 1321,
            detail: ToolImageDetail.high,
          ),
        ],
      );
      final message = Message(
        role: MessageRole.tool,
        content: toolResult.displayText,
        toolCallId: 'call_image',
        toolResult: toolResult,
      );

      final textTokens = CompactionTokenEstimator.estimateMessage(message);
      expect(textTokens, lessThan(50), reason: 'only text is charged as text');
      expect(
        CompactionTokenEstimator.estimateMediaTokens([message]),
        imageTokens,
      );

      final attachment = UserAttachment(
        id: 'attachment-1',
        safeName: 'photo.png',
        mimeType: 'image/png',
        sizeBytes: 1024 * 1024,
        sha256: 'a' * 64,
        kind: UserAttachmentKind.image,
        agentLocalReference: 'attachment-1',
        mediaId: 'b' * 64,
      );
      expect(
        CompactionTokenEstimator.estimateMediaTokens([
          Message(
            role: MessageRole.user,
            content: 'see attached',
            attachments: [attachment],
          ),
        ]),
        CompactionTokenEstimator.maxImageTokensPerImage,
        reason:
            'an image attachment without recorded dimensions is bounded by '
            'the per-image ceiling instead of its transport bytes',
      );
    });

    test('wire payload pricing drops encoded media transport', () {
      final media = 'data:image/png;base64,${'A' * 200000}';
      expect(
        CompactionTokenEstimator.estimateWirePayload({'image_url': media}),
        0,
        reason: 'encoded media is transport, not visible text',
      );
      expect(
        CompactionTokenEstimator.estimateWirePayload({
          'text': 'visible text',
          'image_url': media,
        }),
        CompactionTokenEstimator.estimateText('visible text'),
      );
      expect(
        CompactionTokenEstimator.estimateWirePayload(
          {'encrypted_content': 'E' * 100000},
          opaqueKeys: const {'encrypted_content'},
        ),
        0,
      );
    });

    test('thin and degenerate image geometry stays finite and bounded', () {
      // 1x10000: fitting the maximum edge rounds the thin side to zero before
      // the minimum-short-side scale, which used to divide by zero and round
      // NaN; the repaired fit keeps one pixel and clamps the tile grid.
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 1, height: 10000),
        CompactionTokenEstimator.maxImageTokensPerImage,
      );
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 10000, height: 1),
        CompactionTokenEstimator.maxImageTokensPerImage,
      );
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 2, height: 4000),
        CompactionTokenEstimator.maxImageTokensPerImage,
      );
      // Panorama: reaching a 768px short side from 20px would demand a
      // 154x2 tile grid (52k tokens) without the per-image ceiling.
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 10000, height: 100),
        CompactionTokenEstimator.maxImageTokensPerImage,
      );
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 100, height: 10000),
        CompactionTokenEstimator.maxImageTokensPerImage,
      );
      // A tiny image still scales to the minimum short side (2x2 tiles) and
      // stays far below the ceiling.
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 10, height: 10),
        CompactionTokenEstimator.imageBaseTokens +
            CompactionTokenEstimator.imageTileTokens * 4,
      );
      // Non-positive dimensions never charge anything.
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: -1, height: 10),
        0,
      );
      expect(
        CompactionTokenEstimator.estimateImageTokens(width: 10, height: 0),
        0,
      );
    });

    test('original detail is priced as the wire high detail, not low', () {
      // The tool-result wire codec maps canonical `original` to wire `high`
      // (agent/lib/engine/adapters/tool_result_wire_codec.dart), so accounting
      // must charge the high tile grid for both.
      Message messageWithDetail(ToolImageDetail detail) {
        final toolResult = ToolExecutionResult(
          blocks: [
            ToolTextBlock(text: 'rendered view'),
            ToolImageBlock(
              dataBase64: 'A' * 2000,
              mimeType: 'image/png',
              width: 1203,
              height: 1321,
              detail: detail,
            ),
          ],
        );
        return Message(
          role: MessageRole.tool,
          content: toolResult.displayText,
          toolCallId: 'call_image',
          toolResult: toolResult,
        );
      }

      final high = CompactionTokenEstimator.estimateMediaTokens([
        messageWithDetail(ToolImageDetail.high),
      ]);
      expect(
        high,
        CompactionTokenEstimator.imageBaseTokens +
            CompactionTokenEstimator.imageTileTokens * 9,
      );
      expect(
        CompactionTokenEstimator.estimateMediaTokens([
          messageWithDetail(ToolImageDetail.original),
        ]),
        high,
        reason: 'canonical original reaches the wire as high and costs the same',
      );
      expect(
        CompactionTokenEstimator.estimateMediaTokens([
          messageWithDetail(ToolImageDetail.low),
        ]),
        CompactionTokenEstimator.imageBaseTokens,
        reason: 'only low detail is charged the base rate',
      );
    });
  });
}
