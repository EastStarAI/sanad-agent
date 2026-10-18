/// Applies typed thinking directives to aggregator chat-completions bodies.
///
/// The aggregator owns a serialization boundary of its own: the official
/// OpenRouter reasoning guide documents the nested `reasoning` object, where
/// `effort` accepts `max`, `xhigh`, `high`, `medium`, `low`, `minimal` or
/// `none` and explicitly documents `"none"` as disabling reasoning. A positive
/// budget arrives as `max_tokens` (Anthropic-style), and `enabled: true` only
/// *enables* reasoning with default parameters.
///
/// Only canonical admitted directives are serialized:
/// * admitted efforts (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`,
///   `max`) — exactly `none` is the documented disable envelope;
/// * a **positive** Google/Anthropic budget as `max_tokens`, with a Google
///   budget of exactly zero mapping to the disable envelope;
/// * the documented finite Google levels;
/// * a typed toggle.
///
/// Anything else — a non-admitted effort or level, a negative budget, a
/// non-positive Anthropic budget, or a directive this envelope cannot carry —
/// raises [ThinkingWireSerializationException] while the body is built, so the
/// request fails actionably before dispatch instead of being silently omitted
/// or remapped. Omission stays reserved for [UseProviderDefault].
library;

import 'native_thinking_directive.dart';
import 'thinking_wire_vocabulary.dart';

class AggregatorThinkingWireCodec {
  AggregatorThinkingWireCodec._();

  /// The documented aggregator disable envelope.
  static const disableEnvelope = {'effort': 'none'};

  /// Documented admitted effort vocabulary (shared with declaration
  /// validation, so the two can never drift).
  static const admittedEfforts = ThinkingWireVocabulary.effortIds;

  /// Documented admitted Google level vocabulary.
  static const admittedGoogleLevels = ThinkingWireVocabulary.googleLevelIds;

  /// OpenRouter-style nested `reasoning` object for aggregator routes.
  static void applyReasoning(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case OpenAiEffortDirective(:final effort):
      case AnthropicAdaptiveDirective(:final effort):
        _applyEffort(body, effort);
      case GoogleLevelDirective(:final level):
        if (!admittedGoogleLevels.contains(level)) {
          throw ThinkingWireSerializationException(
            'Aggregator cannot carry Google thinking level "$level"',
          );
        }
        body['reasoning'] = {'enabled': true, 'effort': level};
      case GoogleBudgetDirective(:final budget):
        if (budget == 0) {
          body['reasoning'] = disableEnvelope;
          return;
        }
        if (budget < 0) {
          throw ThinkingWireSerializationException(
            'Aggregator cannot carry a negative Google budget ($budget)',
          );
        }
        body['reasoning'] = {'enabled': true, 'max_tokens': budget};
      case AnthropicBudgetDirective(:final budgetTokens):
        if (budgetTokens <= 0) {
          throw ThinkingWireSerializationException(
            'Aggregator budget must be a positive token budget '
            '($budgetTokens)',
          );
        }
        body['reasoning'] = {'enabled': true, 'max_tokens': budgetTokens};
      case ThinkingToggleDirective(enabled: true):
        body['reasoning'] = const {'enabled': true};
      case ThinkingToggleDirective(enabled: false):
        body['reasoning'] = disableEnvelope;
      case UseProviderDefault():
      case null:
        break;
      default:
        throw ThinkingWireSerializationException(
          'Aggregator envelope cannot carry this directive',
        );
    }
  }

  static void _applyEffort(Map<String, dynamic> body, String effort) {
    if (!admittedEfforts.contains(effort)) {
      throw ThinkingWireSerializationException(
        'Aggregator cannot carry effort "$effort"',
      );
    }
    if (effort == ThinkingWireVocabulary.disableEffort) {
      body['reasoning'] = disableEnvelope;
      return;
    }
    body['reasoning'] = {'enabled': true, 'effort': effort};
  }
}
