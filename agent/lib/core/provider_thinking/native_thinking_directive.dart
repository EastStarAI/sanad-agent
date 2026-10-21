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

/// A native Chat effort that also enables thinking: `thinking: {type: enabled}`
/// plus `reasoning_effort` (the documented DeepSeek / Z.AI envelope). The
/// shipped or declared `native_toggle_effort` wire produces it; the route's
/// Chat codec serializes it the same way on every template that admits the
/// wire, so the envelope never depends on a model-name table.
class NativeThinkingEffortDirective extends NativeThinkingDirective {
  final String effort;

  const NativeThinkingEffortDirective(this.effort);
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

/// A documented Chat-template keyword Boolean that toggles thinking.
///
/// NVIDIA NIM (and compatible NIM containers) document reasoning as a finite
/// `chat_template_kwargs` Boolean instead of an effort field: `{"thinking":
/// true|false}` for Kimi and `{"enable_thinking": true|false}` for Qwen. The
/// key is a finite validated allowlist — arbitrary JSON or an unknown key can
/// never reach the wire.
class ChatTemplateBooleanDirective extends NativeThinkingDirective {
  /// Documented, mode-compatible template-kwargs keys.
  static const admittedKeys = {'thinking', 'enable_thinking'};

  final String key;
  final bool value;

  factory ChatTemplateBooleanDirective({
    required String key,
    required bool value,
  }) {
    if (!admittedKeys.contains(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'Unsupported chat_template_kwargs key (admitted: '
            '${admittedKeys.join(", ")})',
      );
    }
    return ChatTemplateBooleanDirective._(key, value);
  }

  const ChatTemplateBooleanDirective._(this.key, this.value);
}
