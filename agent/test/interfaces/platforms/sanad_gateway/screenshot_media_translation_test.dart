import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/view_image_media_metadata.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:test/test.dart';

/// Task 114e regression suite for the live translation boundary:
/// `system_screenshot` reaches the client through the same canonical media
/// descriptor as `view_image`, and stays byte-free and fail-closed.
Map<String, dynamic> _publicMediaFixture() => {
  'media_id': List.filled(64, 'a').join(),
  'name': 'view-image.jpg',
  'mime_type': 'image/jpeg',
  'width': 1920,
  'height': 1080,
  'availability': 'available',
};

ToolExecutionResult _screenshotResult() => ToolExecutionResult(
  blocks: [
    ToolTextBlock(
      text:
          'Screenshot taken successfully from monitor 1 , imagePaht: /tmp/shot.jpg ',
    ),
    ToolImageBlock(
      dataBase64: base64.encode(const [9, 8, 7, 6]),
      mimeType: 'image/jpeg',
      width: 1920,
      height: 1080,
      detail: ToolImageDetail.auto,
    ),
  ],
);

GatewayResponse _toolResult({
  required String toolName,
  ToolExecutionResult? toolResult,
  Map<String, dynamic>? metadata,
  bool isToolError = false,
}) => GatewayResponse(
  sessionId: 'session-114e',
  message: Message(
    role: MessageRole.tool,
    content: toolResult?.displayText ?? 'Screenshot taken successfully from monitor 1',
    toolResult: toolResult,
    metadata: metadata,
  ),
  toolName: toolName,
  toolCallId: 'call-shot-1',
  isToolResult: true,
  isToolError: isToolError,
);

void main() {
  test(
    'live system_screenshot tool result publishes a byte-free media descriptor',
    () {
      final result = _screenshotResult();
      final expected = ViewImageMediaMetadata.project(
        sessionId: 'session-114e',
        toolName: 'system_screenshot',
        toolCallId: 'call-shot-1',
        result: result,
      )!;

      final event = AgentToCanonical.translate(
        _toolResult(toolName: 'system_screenshot', toolResult: result),
      );

      expect(event.payload['media'], expected.toPublicJson());
      expect(
        jsonEncode(event.toJson()),
        isNot(contains(base64.encode(const [9, 8, 7, 6]))),
      );
    },
  );

  test(
    'live system_screenshot event accepts a validated terminal media descriptor',
    () {
      final event = AgentToCanonical.translate(
        _toolResult(
          toolName: 'system_screenshot',
          metadata: {'media': _publicMediaFixture()},
        ),
      );

      expect(event.payload['media'], _publicMediaFixture());
    },
  );

  test(
    'tool results that are not media tools never publish a media descriptor',
    () {
      final event = AgentToCanonical.translate(
        _toolResult(
          toolName: 'system_mouse',
          metadata: {'media': _publicMediaFixture()},
        ),
      );

      expect(event.payload.containsKey('media'), isFalse);
    },
  );

  test(
    'failed system_screenshot terminal descriptors stay unpublished',
    () {
      // The primary projection is keyed on the typed result's own error state;
      // the terminal-descriptor fallback is additionally gated on the response
      // error/cancellation flags.
      final event = AgentToCanonical.translate(
        _toolResult(
          toolName: 'system_screenshot',
          metadata: {'media': _publicMediaFixture()},
          isToolError: true,
        ),
      );

      expect(event.payload.containsKey('media'), isFalse);
    },
  );
}
