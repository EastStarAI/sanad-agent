/// Applies typed OpenAI-family thinking directives to request bodies.
library;

import 'native_thinking_directive.dart';

class OpenAiThinkingWireCodec {
  OpenAiThinkingWireCodec._();

  static void applyChatCompletionsReasoning(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case OpenAiEffortDirective(:final effort):
        body['reasoning_effort'] = effort;
      case UseProviderDefault():
      case null:
      case ResponsesReasoningDirective():
        break;
      default:
        break;
    }
  }

  static void applyResponsesReasoning(
    Map<String, dynamic> reasoning,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case ResponsesReasoningDirective(:final effort, :final summary):
        reasoning['effort'] = effort;
        reasoning['summary'] = summary;
      case OpenAiEffortDirective(:final effort):
        reasoning['effort'] = effort;
        reasoning.putIfAbsent('summary', () => 'auto');
      case UseProviderDefault():
      case null:
        reasoning.putIfAbsent('summary', () => 'auto');
      default:
        reasoning.putIfAbsent('summary', () => 'auto');
    }
  }
}
