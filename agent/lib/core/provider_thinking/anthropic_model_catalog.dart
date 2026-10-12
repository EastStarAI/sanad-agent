/// Fixed Anthropic model thinking tables (Task 43 Gate F).
library;

enum AnthropicRouteThinkingKind {
  unsupported,
  manualBudget,
  adaptive,
}

class AnthropicModelCatalog {
  AnthropicModelCatalog._();

  static const budgetTokensByTier = <String, int>{
    'low': 2048,
    'medium': 8192,
    'high': 16384,
  };

  static const baseAdaptiveEffortIds = ['low', 'medium', 'high'];

  static const extendedAdaptiveEffortIds = ['low', 'medium', 'high', 'max'];

  static AnthropicRouteThinkingKind thinkingKindForModel(String modelId) {
    final normalized = _normalizeModelId(modelId);
    if (_matchesAny(normalized, _alwaysAdaptiveOnlyPatterns)) {
      return AnthropicRouteThinkingKind.adaptive;
    }
    if (_matchesAny(normalized, _adaptiveCapablePatterns)) {
      return AnthropicRouteThinkingKind.adaptive;
    }
    if (_matchesAny(normalized, _manualOnlyPatterns)) {
      return AnthropicRouteThinkingKind.manualBudget;
    }
    return AnthropicRouteThinkingKind.unsupported;
  }

  static List<String> budgetOptionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) != AnthropicRouteThinkingKind.manualBudget) {
      return const [];
    }
    return budgetTokensByTier.keys.toList(growable: false);
  }

  static List<String> adaptiveEffortOptionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) != AnthropicRouteThinkingKind.adaptive) {
      return const [];
    }
    final normalized = _normalizeModelId(modelId);
    if (_matchesAny(normalized, _extendedEffortPatterns)) {
      return extendedAdaptiveEffortIds;
    }
    return baseAdaptiveEffortIds;
  }

  static int? budgetTokensForSelection({
    required String modelId,
    required String selectionId,
  }) {
    if (thinkingKindForModel(modelId) != AnthropicRouteThinkingKind.manualBudget) {
      return null;
    }
    return budgetTokensByTier[selectionId];
  }

  static bool allowsAdaptiveEffortId({
    required String modelId,
    required String effortId,
  }) {
    return adaptiveEffortOptionIdsForModel(modelId).contains(effortId);
  }

  static bool allowsBudgetSelectionId({
    required String modelId,
    required String selectionId,
  }) {
    return budgetOptionIdsForModel(modelId).contains(selectionId);
  }

  /// Whether the route may expose an explicit off option in the descriptor.
  static bool supportsExplicitOff(String modelId) {
    final normalized = _normalizeModelId(modelId);
    if (_matchesAny(normalized, _noOffPatterns)) {
      return false;
    }
    return thinkingKindForModel(modelId) != AnthropicRouteThinkingKind.unsupported;
  }

  static String labelForOptionId(String optionId) {
    return switch (optionId) {
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'max' => 'Max',
      'off' => 'Off',
      _ => optionId,
    };
  }

  static String _normalizeModelId(String modelId) {
    final trimmed = modelId.trim().toLowerCase();
    final withoutVendor = trimmed.contains('/')
        ? trimmed.split('/').last
        : trimmed;
    return withoutVendor.replaceAll('.', '-');
  }

  static bool _matchesAny(String normalized, List<String> patterns) {
    return patterns.any(normalized.contains);
  }

  static const _alwaysAdaptiveOnlyPatterns = [
    'claude-fable-5',
    'claude-mythos-5',
    'claude-opus-4-8',
    'claude-opus-4-7',
    'claude-sonnet-5',
  ];

  static const _adaptiveCapablePatterns = [
    'claude-opus-4-6',
    'claude-sonnet-4-6',
    'claude-mythos-preview',
  ];

  static const _manualOnlyPatterns = [
    'claude-opus-4-5',
    'claude-sonnet-4-5',
    'claude-haiku-4-5',
    'claude-3-5-sonnet',
    'claude-3-5-haiku',
    'claude-3-7-sonnet',
  ];

  static const _extendedEffortPatterns = [
    'claude-fable-5',
    'claude-mythos-5',
    'claude-opus-4-8',
    'claude-opus-4-7',
    'claude-sonnet-5',
  ];

  static const _noOffPatterns = [
    'claude-fable-5',
    'claude-mythos-5',
  ];
}
