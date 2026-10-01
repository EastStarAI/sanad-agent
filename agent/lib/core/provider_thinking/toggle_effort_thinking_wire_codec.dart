/// Applies toggle/effort directives with mutual exclusion (Task 43 Gate G).
library;

import 'native_thinking_directive.dart';

class ToggleEffortThinkingWireCodec {
  ToggleEffortThinkingWireCodec._();

  static void applyChatCompletions(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case OpenAiEffortDirective(:final effort):
        body.remove('thinking');
        body['reasoning_effort'] = effort;
      case ThinkingToggleDirective(enabled: false):
        body.remove('reasoning_effort');
        body['thinking'] = const {'type': 'disabled'};
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }
}
