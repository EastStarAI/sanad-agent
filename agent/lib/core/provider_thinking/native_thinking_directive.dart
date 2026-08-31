/// Typed native thinking directives produced by provider thinking policies.
///
/// Adapters translate these directives into protocol wire payloads. No raw
/// request maps cross this boundary (Task 43 Gate A).
library;

sealed class NativeThinkingDirective {
  const NativeThinkingDirective();
}

/// Preserve provider/model default by omitting thinking controls.
class UseProviderDefault extends NativeThinkingDirective {
  const UseProviderDefault();
}

class OpenAiEffortDirective extends NativeThinkingDirective {
  final String effort;

  const OpenAiEffortDirective(this.effort);
}

class ResponsesReasoningDirective extends NativeThinkingDirective {
  final String effort;
  final String summary;

  const ResponsesReasoningDirective({
    required this.effort,
    this.summary = 'auto',
  });
}

class AnthropicBudgetDirective extends NativeThinkingDirective {
  final int budgetTokens;

  const AnthropicBudgetDirective(this.budgetTokens);
}

class AnthropicAdaptiveDirective extends NativeThinkingDirective {
  final String effort;

  const AnthropicAdaptiveDirective(this.effort);
}

class GoogleBudgetDirective extends NativeThinkingDirective {
  final int budget;

  const GoogleBudgetDirective(this.budget);
}

class GoogleLevelDirective extends NativeThinkingDirective {
  final String level;

  const GoogleLevelDirective(this.level);
}

class ThinkingToggleDirective extends NativeThinkingDirective {
  final bool enabled;

  const ThinkingToggleDirective({required this.enabled});
}

class OllamaThinkLevelDirective extends NativeThinkingDirective {
  final String level;

  const OllamaThinkLevelDirective(this.level);
}
