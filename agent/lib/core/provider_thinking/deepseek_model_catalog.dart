/// Fixed DeepSeek model thinking fixtures (Task 43 Gate G).
library;

enum DeepSeekRouteThinkingKind {
  unknown,
  unsupported,
  toggleEffort,
}

class DeepSeekModelCatalog {
  DeepSeekModelCatalog._();

  static const effortOptionIds = ['low', 'medium', 'high'];

  static DeepSeekRouteThinkingKind thinkingKindForModel(String modelId) {
    final normalized = _normalizeModelId(modelId);
    if (_matchesAny(normalized, _fixedReasonerPatterns)) {
      return DeepSeekRouteThinkingKind.unsupported;
    }
    if (_matchesAny(normalized, _toggleEffortPatterns)) {
      return DeepSeekRouteThinkingKind.toggleEffort;
    }
    return DeepSeekRouteThinkingKind.unknown;
  }

  static List<String> optionIdsForModel(String modelId) {
    if (thinkingKindForModel(modelId) != DeepSeekRouteThinkingKind.toggleEffort) {
      return const [];
    }
    return const ['off', ...effortOptionIds];
  }

  static bool allowsSelectionId({
    required String modelId,
    required String selectionId,
  }) {
    return optionIdsForModel(modelId).contains(selectionId);
  }

  static String labelForOptionId(String optionId) {
    return switch (optionId) {
      'off' => 'Off',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      _ => optionId,
    };
  }

  static String _normalizeModelId(String modelId) {
    final trimmed = modelId.trim().toLowerCase();
    return trimmed.contains('/') ? trimmed.split('/').last : trimmed;
  }

  static bool _matchesAny(String normalized, List<String> patterns) {
    return patterns.any(normalized.contains);
  }

  static const _fixedReasonerPatterns = [
    'deepseek-reasoner',
    'deepseek-r1',
    'reasoner',
  ];

  static const _toggleEffortPatterns = [
    'deepseek-chat',
  ];
}
