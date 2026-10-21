/// Applies toggle/effort directives with mutual exclusion (Task 43 Gate G).
///
/// This is also the shared generic Chat-codec seam the adapter uses for every
/// policy id that is not a first-party native, Google or aggregator policy
/// (for example the NIM Chat policy): it therefore owns the documented
/// `chat_template_kwargs` Boolean toggle serialization for those routes.
library;

import 'chat_template_kwargs_wire_codec.dart';
import 'native_thinking_directive.dart';

class ToggleEffortThinkingWireCodec {
  ToggleEffortThinkingWireCodec._();

  static void applyChatCompletions(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive, {
    bool enableThinkingWithEffort = false,
  }) {
    switch (directive) {
      case NativeThinkingEffortDirective(:final effort):
        body['thinking'] = const {'type': 'enabled'};
        body['reasoning_effort'] = effort;
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
      case ChatTemplateBooleanDirective():
        ChatTemplateKwargsWireCodec.apply(body, directive);
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }
}
