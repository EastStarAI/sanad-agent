/// Applies typed thinking directives to aggregator chat-completions bodies.
library;

import 'native_thinking_directive.dart';

class AggregatorThinkingWireCodec {
  AggregatorThinkingWireCodec._();

  /// OpenRouter-style nested `reasoning` object for aggregator routes.
  static void applyReasoning(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case OpenAiEffortDirective(:final effort):
        body['reasoning'] = {'enabled': true, 'effort': effort};
      case AnthropicBudgetDirective(:final budgetTokens):
        body['reasoning'] = {
          'enabled': true,
          'max_tokens': budgetTokens,
        };
      case AnthropicAdaptiveDirective(:final effort):
        body['reasoning'] = {'enabled': true, 'effort': effort};
      case GoogleBudgetDirective(:final budget):
        body['reasoning'] = {'enabled': true, 'max_tokens': budget};
      case GoogleLevelDirective(:final level):
        body['reasoning'] = {'enabled': true, 'effort': level};
      case ThinkingToggleDirective(enabled: false):
        body['reasoning'] = const {'effort': 'none'};
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }
}
