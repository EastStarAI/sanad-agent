/// Applies typed Anthropic thinking directives to Messages API bodies.
library;

import 'native_thinking_directive.dart';

class AnthropicThinkingWireCodec {
  AnthropicThinkingWireCodec._();

  static void applyThinking(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case AnthropicBudgetDirective(:final budgetTokens):
        final maxTokens = _readMaxTokens(body);
        final effectiveBudget = maxTokens == null
            ? budgetTokens
            : lowerBudgetTokens(
                budgetTokens: budgetTokens,
                maxTokens: maxTokens,
              );
        body['thinking'] = {
          'type': 'enabled',
          'budget_tokens': effectiveBudget,
        };
      case AnthropicAdaptiveDirective(:final effort):
        body['thinking'] = const {'type': 'adaptive'};
        final outputConfig = _outputConfig(body);
        outputConfig['effort'] = effort;
        body['output_config'] = outputConfig;
      case ThinkingToggleDirective(enabled: false):
        body['thinking'] = const {'type': 'disabled'};
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }

  /// Anthropic requires `budget_tokens` to stay below `max_tokens`.
  static int lowerBudgetTokens({
    required int budgetTokens,
    required int maxTokens,
  }) {
    if (maxTokens <= 1) {
      return budgetTokens;
    }
    final ceiling = maxTokens - 1;
    return budgetTokens > ceiling ? ceiling : budgetTokens;
  }

  static int? _readMaxTokens(Map<String, dynamic> body) {
    final raw = body['max_tokens'];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return null;
  }

  static Map<String, dynamic> _outputConfig(Map<String, dynamic> body) {
    final existing = body['output_config'];
    if (existing is Map<String, dynamic>) {
      return Map<String, dynamic>.from(existing);
    }
    if (existing is Map) {
      return existing.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }
}
