/// Fixed Google Gemini model thinking tables (Task 43 Gate G).
library;

enum GoogleRouteThinkingKind {
  unsupported,
  tokenBudget,
  level,
}

class GoogleModelCatalog {
  GoogleModelCatalog._();

  static const budgetTokensByTier = <String, int>{
    'low': 1024,
    'medium': 8192,
    'high': 24576,
  };

  static const baseLevelIds = ['low', 'medium', 'high'];
  static const extendedLevelIds = ['minimal', 'low', 'medium', 'high'];

  static GoogleRouteThinkingKind thinkingKindForModel(String modelId) {
    final normalized = _normalizeModelId(modelId);
    if (_matchesAny(normalized, _budgetModelPatterns)) {
      return GoogleRouteThinkingKind.tokenBudget;
    }
    if (_matchesAny(normalized, _levelModelPatterns)) {
      return GoogleRouteThinkingKind.level;
    }
    return GoogleRouteThinkingKind.unsupported;
  }

  static List<String> budgetOptionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) != GoogleRouteThinkingKind.tokenBudget) {
      return const [];
    }
    return ['off', ...budgetTokensByTier.keys];
  }

  static List<String> levelOptionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) != GoogleRouteThinkingKind.level) {
      return const [];
    }
    final normalized = _normalizeModelId(modelId);
    if (_matchesAny(normalized, _extendedLevelPatterns)) {
      return extendedLevelIds;
    }
    return baseLevelIds;
  }

  static int? budgetTokensForSelection({
    required String modelId,
    required String selectionId,
  }) {
    if (thinkingKindForModel(modelId) != GoogleRouteThinkingKind.tokenBudget) {
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
  }) {
    return levelOptionIdsForModel(modelId).contains(levelId);
  }

  static bool supportsExplicitOff(String modelId) {
    return thinkingKindForModel(modelId) == GoogleRouteThinkingKind.tokenBudget;
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

  static String _normalizeModelId(String modelId) {
    final trimmed = modelId.trim().toLowerCase();
    final withoutVendor = trimmed.contains('/')
        ? trimmed.split('/').last
        : trimmed;
    return withoutVendor.replaceAll('_', '-');
  }

  static bool _matchesAny(String normalized, List<String> patterns) {
    return patterns.any(normalized.contains);
  }

  static const _budgetModelPatterns = [
    'gemini-2.5',
    'gemini-2-5',
  ];

  static const _levelModelPatterns = [
    'gemini-3',
    'gemini-3.1',
    'gemini-3.5',
    'gemini-3.6',
    'gemini-pro-latest',
  ];

  static const _extendedLevelPatterns = [
    'gemini-3.5-flash',
    'gemini-3.6-flash',
    'gemini-3-flash',
    'gemini-3.1-flash',
  ];
}
