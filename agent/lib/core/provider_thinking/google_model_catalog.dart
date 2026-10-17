/// Exact evidenced Google Gemini thinking fixtures (Task 43 Gate G).
///
/// Model identity owns intrinsic thinking facts. Recognition is exact and
/// case-preserving: only grounded model ids and the single documented `google/`
/// catalog namespace resolve here. Substring, prefix, wildcard or case-folding
/// rules are prohibited because they let arbitrary, variant or differently
/// cased model ids acquire controls that were never evidenced.
///
/// Every retained id carries its own documented finite option set and default;
/// there is no shared family set. Facts are taken from Google's official
/// thinking table and each model's own capability line:
/// * `gemini-4-argon` — `low`/`medium`/`high`, default `medium`.
/// * `gemini-3.8-flash` — `low`/`medium`/`high`, default `medium` (`minimal`
///   documents an error for this model).
/// * `gemini-3.6-flash` — `minimal`/`low`/`medium`/`high`, default `medium`.
/// * `gemini-3.5-flash-lite` — `minimal`/`low`/`medium`/`high`, default
///   `minimal`.
/// * `gemini-3-flash-preview` — `minimal`/`low`/`medium`/`high`, default
///   `high`.
/// * `gemini-3.1-pro-preview` — `low`/`medium`/`high`, default `high`.
/// * `gemini-3-pro-preview` — `low`/`high`, default `high`.
/// * Gemini 2.5 models stay budget-based: documented disable exists only for
///   `gemini-2.5-flash`; `gemini-2.5-pro` is always-on, and both delegate an
///   omitted budget to their model-managed dynamic default, so no default
///   option is advertised.
///
/// An id whose per-model finite set/default is not obtained stays `unknown`
/// (declinable through `model_capabilities`) rather than inheriting a
/// neighbouring model's tiers.
library;

enum GoogleRouteThinkingKind { unknown, unsupported, tokenBudget, level }

/// Documented finite thinking-level facts for one exact Gemini model.
class GoogleModelLevelFacts {
  final List<String> optionIds;
  final String? defaultOptionId;

  const GoogleModelLevelFacts({
    required this.optionIds,
    required this.defaultOptionId,
  });
}

/// Documented finite thinking-budget facts for one exact Gemini model.
class GoogleModelBudgetFacts {
  final List<String> tierOptionIds;
  final bool supportsExplicitOff;
  final String? defaultOptionId;

  const GoogleModelBudgetFacts({
    required this.tierOptionIds,
    required this.supportsExplicitOff,
    required this.defaultOptionId,
  });

  List<String> get optionIds =>
      supportsExplicitOff ? ['off', ...tierOptionIds] : tierOptionIds;

  bool get isAlwaysOn => !supportsExplicitOff;
}

class GoogleModelCatalog {
  GoogleModelCatalog._();

  static const budgetTokensByTier = <String, int>{
    'low': 1024,
    'medium': 8192,
    'high': 24576,
  };

  static const _baseTiers = ['low', 'medium', 'high'];
  static const _minimalTiers = ['minimal', 'low', 'medium', 'high'];

  /// Per-model documented thinking-level facts.
  static const levelFactsByModel = <String, GoogleModelLevelFacts>{
    'gemini-4-argon': GoogleModelLevelFacts(
      optionIds: _baseTiers,
      defaultOptionId: 'medium',
    ),
    'gemini-3.8-flash': GoogleModelLevelFacts(
      optionIds: _baseTiers,
      defaultOptionId: 'medium',
    ),
    'gemini-3.6-flash': GoogleModelLevelFacts(
      optionIds: _minimalTiers,
      defaultOptionId: 'medium',
    ),
    'gemini-3.5-flash-lite': GoogleModelLevelFacts(
      optionIds: _minimalTiers,
      defaultOptionId: 'minimal',
    ),
    'gemini-3-flash-preview': GoogleModelLevelFacts(
      optionIds: _minimalTiers,
      defaultOptionId: 'high',
    ),
    'gemini-3.1-pro-preview': GoogleModelLevelFacts(
      optionIds: _baseTiers,
      defaultOptionId: 'high',
    ),
    'gemini-3-pro-preview': GoogleModelLevelFacts(
      optionIds: ['low', 'high'],
      defaultOptionId: 'high',
    ),
  };

  /// Per-model documented thinking-budget facts.
  static const budgetFactsByModel = <String, GoogleModelBudgetFacts>{
    'gemini-2.5-flash': GoogleModelBudgetFacts(
      tierOptionIds: _baseTiers,
      supportsExplicitOff: true,
      defaultOptionId: null,
    ),
    'gemini-2.5-pro': GoogleModelBudgetFacts(
      tierOptionIds: _baseTiers,
      supportsExplicitOff: false,
      defaultOptionId: null,
    ),
  };

  /// Exact grounded Gemini-family ids whose native contract has no request-time
  /// thinking control. These are `unsupported`; anything else unevidenced stays
  /// `unknown`.
  static const nonThinkingModels = {'gemini-1.5-pro', 'gemini-1.5-flash'};

  /// The single documented catalog namespace for Gemini models. A namespaced id
  /// stays grounded only when its exact suffix is itself an evidenced id; other
  /// namespaces, prefixes or suffixes never promote a model.
  static const groundedVendorNamespaces = ['google/'];

  static GoogleRouteThinkingKind thinkingKindForModel(String modelId) {
    final canonical = _canonicalize(modelId);
    if (budgetFactsByModel.containsKey(canonical)) {
      return GoogleRouteThinkingKind.tokenBudget;
    }
    if (levelFactsByModel.containsKey(canonical)) {
      return GoogleRouteThinkingKind.level;
    }
    if (nonThinkingModels.contains(canonical)) {
      return GoogleRouteThinkingKind.unsupported;
    }
    return GoogleRouteThinkingKind.unknown;
  }

  static bool isEvidencedModel(String modelId) {
    final canonical = _canonicalize(modelId);
    return budgetFactsByModel.containsKey(canonical) ||
        levelFactsByModel.containsKey(canonical);
  }

  static GoogleModelLevelFacts? levelFactsForModel(String modelId) =>
      levelFactsByModel[_canonicalize(modelId)];

  static GoogleModelBudgetFacts? budgetFactsForModel(String modelId) =>
      budgetFactsByModel[_canonicalize(modelId)];

  /// Whether this exact model documents an explicit disable option.
  static bool supportsExplicitOff(String modelId) =>
      budgetFactsForModel(modelId)?.supportsExplicitOff ?? false;

  static List<String> budgetOptionIdsForModel(String modelId) =>
      budgetFactsForModel(modelId)?.optionIds ?? const [];

  static List<String> levelOptionIdsForModel(String modelId) =>
      levelFactsForModel(modelId)?.optionIds ?? const [];

  /// Budget tokens for an explicit budget selection, `0` for the documented
  /// disable option, or `null` when the selection is not advertised.
  static int? budgetTokensForSelection({
    required String modelId,
    required String selectionId,
  }) {
    if (!budgetOptionIdsForModel(modelId).contains(selectionId)) {
      return null;
    }
    if (selectionId == 'off') {
      return 0;
    }
    return budgetTokensByTier[selectionId];
  }

  static bool allowsLevelSelectionId({
    required String modelId,
    required String levelId,
  }) => levelOptionIdsForModel(modelId).contains(levelId);

  /// Documented default option for this exact model, or `null` when the model's
  /// default is model-managed and must stay an omission.
  static String? defaultOptionIdForModel(String modelId) {
    final canonical = _canonicalize(modelId);
    return budgetFactsByModel[canonical]?.defaultOptionId ??
        levelFactsByModel[canonical]?.defaultOptionId;
  }

  static String labelForOptionId(String optionId) {
    return switch (optionId) {
      'minimal' => 'Minimal',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'off' => 'Off',
      _ => optionId,
    };
  }

  static String _canonicalize(String modelId) {
    final trimmed = modelId.trim();
    for (final namespace in groundedVendorNamespaces) {
      if (trimmed.length > namespace.length && trimmed.startsWith(namespace)) {
        return trimmed.substring(namespace.length);
      }
    }
    return trimmed;
  }
}
