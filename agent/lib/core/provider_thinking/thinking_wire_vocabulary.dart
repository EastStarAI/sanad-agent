/// Centralized finite vocabularies for thinking wire values.
///
/// These are the single source of truth shared by declaration validation and
/// the typed serializers, so an admitted value can never drift between the two
/// (no duplicated per-wire lists, no competing validator). Each set is finite
/// and comes from provider documentation:
/// * effort vocabularies follow the documented OpenAI-style effort enum used by
///   the Chat and Responses wires and by the aggregator `reasoning.effort`;
/// * Google `thinking_level` is the documented finite level enum;
/// * the aggregator disable is the documented `effort: "none"` envelope.
library;

class ThinkingWireVocabulary {
  ThinkingWireVocabulary._();

  /// Documented OpenAI-style effort vocabulary (Chat, Responses, aggregator).
  static const effortIds = {
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  };

  /// The canonical effort that means "disable reasoning".
  static const disableEffort = 'none';

  /// Canonical effort *tier* ids (the effort vocabulary without the disable).
  static const effortTierIds = {
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  };

  static bool isAdmittedEffortTier(String value) =>
      effortTierIds.contains(value);

  /// The shared no-remap invariant for canonical effort labels: a canonical
  /// effort-tier id must map to exactly that canonical effort string, so it can
  /// neither elevate nor downgrade its meaning. Opaque ids stay free to carry
  /// any admitted explicit value.
  static bool canonicalEffortMatches({
    required String optionId,
    required String value,
  }) {
    final id = optionId.trim().toLowerCase();
    if (!effortTierIds.contains(id)) return true;
    return value.trim().toLowerCase() == id;
  }

  /// The same invariant for declared string levels: **no** canonical
  /// effort-tier or Google-level id may change its meaning into a different
  /// string level, including a level that this particular wire does not support
  /// (the separate admitted-value check reports an unsupported tier). Only
  /// genuinely opaque ids may map to any admitted level string; numeric budget
  /// mappings are a distinct budget contract and are not governed here.
  static bool canonicalLevelMatches({
    required String optionId,
    required String value,
  }) {
    final id = optionId.trim().toLowerCase();
    if (!effortTierIds.contains(id) && !googleLevelIds.contains(id)) {
      return true;
    }
    return value.trim().toLowerCase() == id;
  }

  /// Documented Google `thinking_level` enum (never `off`).
  static const googleLevelIds = {'minimal', 'low', 'medium', 'high'};

  /// Documented self-hosted NIM Qwen effort tiers.
  static const nimQwenEffortIds = {'low', 'medium', 'xhigh'};

  static bool isAdmittedEffort(String value) => effortIds.contains(value);

  static bool isAdmittedGoogleLevel(String value) =>
      googleLevelIds.contains(value);
}

/// A typed directive reached a serializer that cannot carry it, or carried a
/// value outside the documented finite vocabulary. Raised while the request
/// body is being built, so the failure happens before any HTTP dispatch and is
/// never silently omitted.
class ThinkingWireSerializationException implements Exception {
  final String message;

  const ThinkingWireSerializationException(this.message);

  @override
  String toString() => 'ThinkingWireSerializationException: $message';
}
