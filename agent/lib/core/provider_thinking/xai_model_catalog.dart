/// Exact evidenced xAI Grok reasoning-effort fixtures (Plan77 G4).
///
/// Model identity owns intrinsic reasoning facts; the active API mode owns the
/// wire. Grounding (official xAI documentation, source-neutral): `grok-4.7`,
/// `grok-4.6` and `grok-4.5` support the `reasoning_effort` parameter, which
/// defaults to `"high"`; reasoning cannot be disabled; `xhigh` is available on
/// `grok-4.6` and later, while earlier models map it to `high` and therefore
/// must never advertise it separately.
library;

class XaiModelCatalog {
  XaiModelCatalog._();

  /// Exact grounded Grok ids with a documented selectable effort, in the
  /// model's own documented order.
  static const effortTiersByModel = <String, List<String>>{
    'grok-4.5': ['low', 'medium', 'high'],
    'grok-4.6': ['low', 'medium', 'high', 'xhigh'],
    'grok-4.7': ['low', 'medium', 'high', 'xhigh'],
  };

  /// Documented default when the request omits `reasoning_effort`.
  static const defaultEffortId = 'high';

  /// `Reasoning cannot be disabled` for the documented effort models, so no
  /// `Off` option is ever advertised.
  static const supportsExplicitDisable = false;

  /// Exact grounded Grok ids that expose reasoning output without a documented
  /// request-time effort control. They must stay unresolved rather than acquire
  /// an invented tier.
  static const reasoningOnlyModels = {'grok-4.20-0309-reasoning'};

  /// Exact grounded Grok ids documented as the non-reasoning variant of a
  /// reasoning family.
  static const nonReasoningModels = {'grok-4.20-0309-non-reasoning'};

  /// Exact grounded Grok ids without a request-time effort control.
  static bool isKnownModel(String modelId) =>
      effortTiersByModel.containsKey(modelId.trim()) ||
      reasoningOnlyModels.contains(modelId.trim()) ||
      nonReasoningModels.contains(modelId.trim());

  /// Whether this exact model documents a selectable reasoning effort.
  static bool supportsEffort(String modelId) =>
      effortTiersByModel.containsKey(modelId.trim());

  /// Documented finite effort options for [modelId], or an empty list when the
  /// model is not evidenced for a selectable effort.
  static List<String> effortOptionIdsForModel(String modelId) =>
      effortTiersByModel[modelId.trim()] ?? const [];

  static bool allowsEffortId({
    required String modelId,
    required String effortId,
  }) => effortOptionIdsForModel(modelId).contains(effortId.trim());

  /// Documented default effort for [modelId], or `null` when none is
  /// documented for that exact model.
  static String? defaultEffortIdForModel(String modelId) =>
      supportsEffort(modelId) ? defaultEffortId : null;

  static String labelForEffortId(String effortId) {
    return switch (effortId) {
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'xhigh' => 'Extra High',
      'max' => 'Max',
      _ => effortId,
    };
  }
}
