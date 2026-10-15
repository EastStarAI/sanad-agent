/// Applies toggle/effort directives with mutual exclusion (Task 43 Gate G).
library;

import 'native_thinking_directive.dart';

class ToggleEffortThinkingWireCodec {
  ToggleEffortThinkingWireCodec._();

  static void applyChatCompletions(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive, {
    bool enableThinkingWithEffort = false,
  }) {
    switch (directive) {
      case OpenAiEffortDirective(:final effort):
        if (enableThinkingWithEffort) {
          body['thinking'] = const {'type': 'enabled'};
        } else {
          body.remove('thinking');
        }
        body['reasoning_effort'] = effort;
      case ThinkingToggleDirective(enabled: false):
        body.remove('reasoning_effort');
        body['thinking'] = const {'type': 'disabled'};
      case ThinkingToggleDirective(enabled: true):
        body.remove('reasoning_effort');
        body['thinking'] = const {'type': 'enabled'};
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }
}
