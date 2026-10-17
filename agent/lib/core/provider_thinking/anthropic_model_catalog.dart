/// Fixed Anthropic model thinking tables (Task 43 Gate F).
library;

enum AnthropicRouteThinkingKind { unsupported, manualBudget, adaptive }

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
    final canonical = _canonicalize(modelId);
    if (_alwaysAdaptiveOnlyModels.contains(canonical)) {
      return AnthropicRouteThinkingKind.adaptive;
    }
    if (_adaptiveCapableModels.contains(canonical)) {
      return AnthropicRouteThinkingKind.adaptive;
    }
    if (_manualOnlyModels.contains(canonical)) {
      return AnthropicRouteThinkingKind.manualBudget;
    }
    return AnthropicRouteThinkingKind.unsupported;
  }

  static bool isEvidencedModel(String modelId) {
    return thinkingKindForModel(modelId) !=
        AnthropicRouteThinkingKind.unsupported;
  }

  static List<String> budgetOptionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) !=
        AnthropicRouteThinkingKind.manualBudget) {
      return const [];
    }
    return budgetTokensByTier.keys.toList(growable: false);
  }

  static List<String> adaptiveEffortOptionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) != AnthropicRouteThinkingKind.adaptive) {
      return const [];
    }
    final canonical = _canonicalize(modelId);
    if (_extendedEffortModels.contains(canonical)) {
      return extendedAdaptiveEffortIds;
    }
    return baseAdaptiveEffortIds;
  }

  static int? budgetTokensForSelection({
    required String modelId,
    required String selectionId,
  }) {
    if (thinkingKindForModel(modelId) !=
        AnthropicRouteThinkingKind.manualBudget) {
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
    final canonical = _canonicalize(modelId);
    if (_noOffModels.contains(canonical)) {
      return false;
    }
    return thinkingKindForModel(modelId) !=
        AnthropicRouteThinkingKind.unsupported;
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

  static const Map<String, String> _explicitAliases = {
    'claude-3.7-sonnet': 'claude-3-7-sonnet',
    'claude-3-7-sonnet-20250219': 'claude-3-7-sonnet',
    'claude-3.7-sonnet-20250219': 'claude-3-7-sonnet',
    'claude-3.7-sonnet:thinking': 'claude-3-7-sonnet',
    'anthropic/claude-3-7-sonnet': 'claude-3-7-sonnet',
    'anthropic/claude-3.7-sonnet': 'claude-3-7-sonnet',
    'anthropic/claude-3-7-sonnet-20250219': 'claude-3-7-sonnet',
    'anthropic/claude-3.7-sonnet:thinking': 'claude-3-7-sonnet',
    'claude-opus-4.7': 'claude-opus-4-7',
    'anthropic/claude-opus-4.7': 'claude-opus-4-7',
    'anthropic/claude-opus-4-7': 'claude-opus-4-7',
    'claude-opus-4.8': 'claude-opus-4-8',
    'anthropic/claude-opus-4.8': 'claude-opus-4-8',
    'anthropic/claude-opus-4-8': 'claude-opus-4-8',
    'claude-opus-4.6': 'claude-opus-4-6',
    'anthropic/claude-opus-4.6': 'claude-opus-4-6',
    'anthropic/claude-opus-4-6': 'claude-opus-4-6',
    'claude-sonnet-4.6': 'claude-sonnet-4-6',
    'anthropic/claude-sonnet-4.6': 'claude-sonnet-4-6',
    'anthropic/claude-sonnet-4-6': 'claude-sonnet-4-6',
    'claude-opus-4.5': 'claude-opus-4-5',
    'anthropic/claude-opus-4.5': 'claude-opus-4-5',
    'anthropic/claude-opus-4-5': 'claude-opus-4-5',
    'claude-sonnet-4.5': 'claude-sonnet-4-5',
    'anthropic/claude-sonnet-4.5': 'claude-sonnet-4-5',
    'anthropic/claude-sonnet-4-5': 'claude-sonnet-4-5',
    'claude-haiku-4.5': 'claude-haiku-4-5',
    'anthropic/claude-haiku-4.5': 'claude-haiku-4-5',
    'anthropic/claude-haiku-4-5': 'claude-haiku-4-5',
    'anthropic/claude-fable-5': 'claude-fable-5',
    'anthropic/claude-mythos-5': 'claude-mythos-5',
    'anthropic/claude-sonnet-5': 'claude-sonnet-5',
    'anthropic/claude-mythos-preview': 'claude-mythos-preview',
  };

  static String _canonicalize(String modelId) {
    final trimmed = modelId.trim();
    return _explicitAliases[trimmed] ?? trimmed;
  }

  static const _alwaysAdaptiveOnlyModels = {
    'claude-fable-5',
    'claude-mythos-5',
    'claude-opus-4-8',
    'claude-opus-4-7',
    'claude-sonnet-5',
  };

  static const _adaptiveCapableModels = {
    'claude-opus-4-6',
    'claude-sonnet-4-6',
    'claude-mythos-preview',
  };

  static const _manualOnlyModels = {
    'claude-opus-4-5',
    'claude-sonnet-4-5',
    'claude-haiku-4-5',
    'claude-3-7-sonnet',
  };

  static const _extendedEffortModels = {
    'claude-fable-5',
    'claude-mythos-5',
    'claude-opus-4-8',
    'claude-opus-4-7',
    'claude-sonnet-5',
  };

  static const _noOffModels = {'claude-fable-5', 'claude-mythos-5'};
}
