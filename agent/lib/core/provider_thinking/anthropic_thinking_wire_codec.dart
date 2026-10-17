/// Applies typed Anthropic thinking directives to Messages API bodies.
///
/// An explicitly selected token budget is emitted exactly as selected. The
/// Messages API requires `budget_tokens` to stay below `max_tokens`, so a
/// selection the request cannot honour raises
/// [ThinkingWireSerializationException] while the body is built: the request
/// fails actionably before dispatch instead of silently sending a smaller
/// budget than the one the user selected.
library;

import 'native_thinking_directive.dart';
import 'thinking_wire_vocabulary.dart';

class AnthropicThinkingWireCodec {
  AnthropicThinkingWireCodec._();

  static void applyThinking(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case AnthropicBudgetDirective(:final budgetTokens):
        final maxTokens = _readMaxTokens(body);
        // A declared ceiling must genuinely host the selected budget: the
        // Messages API requires `budget_tokens` to stay below `max_tokens`,
        // which no positive budget can satisfy when the ceiling leaves no room
        // for it. An absent `max_tokens` has no declared ceiling to compare
        // against, so the selected budget passes through unchanged rather than
        // being replaced.
        if (maxTokens != null && budgetTokens > maxTokens - 1) {
          throw ThinkingWireSerializationException(
            'Anthropic thinking budget $budgetTokens exceeds this request\'s '
            'max_tokens $maxTokens; the selected budget cannot be honoured.',
          );
        }
        body['thinking'] = {
          'type': 'enabled',
          'budget_tokens': budgetTokens,
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
