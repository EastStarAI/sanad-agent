import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:sanad_agent/cli/models/cli_events.dart';
import 'package:test/test.dart';

void main() {
  test('tool use carries the latest context usage snapshot', () {
    final event = AgentToCanonical.translate(
      GatewayResponse(
        sessionId: 'session-1',
        message: Message(role: MessageRole.tool, content: '{}'),
        isComplete: false,
        isToolUse: true,
        toolName: 'search',
        contextUsage: const {
          'input_tokens': 194000,
          'cached_tokens': 120000,
          'context_window_tokens': 258000,
        },
      ),
    );

    expect(event.type, 'tool_use');
    expect(event.payload['context_usage'], {
      'input_tokens': 194000,
      'cached_tokens': 120000,
      'context_window_tokens': 258000,
    });
  });

  test('G3: a typed pre-dispatch rejection keeps its error code on the final '
      'answer and in the CLI turn event', () {
    final event = AgentToCanonical.translate(
      GatewayResponse(
        sessionId: 'session-1',
        message: Message(
          role: MessageRole.assistant,
          content: 'The selected thinking option is unavailable for this route.',
          metadata: const {
            'error_code': 'thinking_option_unavailable_for_route',
            'thinking_selection_error': true,
          },
        ),
        isComplete: true,
      ),
    );
    expect(event.type, 'final_answer');
    expect(event.payload['error_code'], 'thinking_option_unavailable_for_route');

    final cli = CliEvent.fromJson(event.toJson());
    expect(cli, isA<CliTurnCompleteEvent>());
    expect(
      (cli as CliTurnCompleteEvent).errorCode,
      'thinking_option_unavailable_for_route',
    );
  });

  test('an ordinary final answer carries no error code', () {
    final event = AgentToCanonical.translate(
      GatewayResponse(
        sessionId: 'session-1',
        message: Message(role: MessageRole.assistant, content: 'ok'),
        isComplete: true,
      ),
    );
    expect(event.payload.containsKey('error_code'), isFalse);
  });
}
