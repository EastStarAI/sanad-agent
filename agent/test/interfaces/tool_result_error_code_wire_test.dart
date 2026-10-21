import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:test/test.dart';

void main() {
  test('a live tool_result carries the typed error code', () {
    final event = AgentToCanonical.translate(
      GatewayResponse(
        sessionId: 's1',
        toolName: 'shell_execute',
        toolCallId: 'call-1',
        isToolResult: true,
        isToolError: true,
        message: Message(
          role: MessageRole.tool,
          toolCallId: 'call-1',
          toolResult: ToolExecutionResult.text(
            'Error executing tool: User denied permission for tool shell_execute.',
            isError: true,
            errorCode: ToolResultErrorCode.permissionDenied,
          ),
        ),
      ),
    );
    expect(event.payload['errorCode'], 'permission_denied');
  });

  test(
    'the executor-shaped live response (code in metadata) carries errorCode',
    () {
      final event = AgentToCanonical.translate(
        GatewayResponse(
          sessionId: 's1',
          toolName: 'shell_execute',
          toolCallId: 'call-2',
          isToolResult: true,
          isToolError: true,
          message: Message(
            role: MessageRole.tool,
            content: 'Error executing tool: Exception: User denied permission.',
            metadata: const {'error_code': 'permission_denied'},
          ),
        ),
      );
      expect(event.payload['errorCode'], 'permission_denied');
    },
  );
}
