/// Fixed DeepSeek model thinking fixtures (Task 43 Gate G).
library;

enum DeepSeekRouteThinkingKind { unknown, unsupported, toggle, toggleEffort }

class DeepSeekModelCatalog {
  DeepSeekModelCatalog._();

  static const _fixedReasonerModels = {
    'deepseek-reasoner',
    'deepseek-r1',
    'deepseek-r1-zero',
  };

  static const _legacyToggleModels = {
    'deepseek-chat',
    'deepseek-v3',
    'deepseek-chat-v3',
  };

  static const _effortCapableModels = {
    'deepseek-v4',
    'deepseek-v4-pro',
    'deepseek-v4-flash',
    // Exact OpenCode Go / DeepSeek API id for V4.1-Flash. Grounded in
    // https://www.deepseek.com/en/news/deepseek-v4-1-flash/ (V4.1-Flash is live
    // on the DeepSeek API; OpenCode is an official partner) and
    // https://opencode.ai/docs/go/ (Go lists `DeepSeek V4.1 Flash`).
    'deepseek-v4.1-flash',
    'deepseek-flash',
  };

  static const toggleOptionIds = ['off', 'on'];
  static const effortOptionIds = ['off', 'low', 'high', 'max'];

  static bool isEvidencedModel(String modelId) {
    final canonical = _canonicalize(modelId);
    return _fixedReasonerModels.contains(canonical) ||
        _legacyToggleModels.contains(canonical) ||
        _effortCapableModels.contains(canonical);
  }

  static DeepSeekRouteThinkingKind thinkingKindForModel(String modelId) {
    final canonical = _canonicalize(modelId);
    if (_fixedReasonerModels.contains(canonical)) {
      return DeepSeekRouteThinkingKind.unsupported;
    }
    if (_legacyToggleModels.contains(canonical)) {
      return DeepSeekRouteThinkingKind.toggle;
    }
    if (_effortCapableModels.contains(canonical)) {
      return DeepSeekRouteThinkingKind.toggleEffort;
    }
    return DeepSeekRouteThinkingKind.unknown;
  }

  static List<String> optionIdsForModel(String modelId) {
    return switch (thinkingKindForModel(modelId)) {
      DeepSeekRouteThinkingKind.toggle => toggleOptionIds,
      DeepSeekRouteThinkingKind.toggleEffort => effortOptionIds,
      DeepSeekRouteThinkingKind.unsupported ||
      DeepSeekRouteThinkingKind.unknown => const [],
    };
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
      'on' => 'On',
      'low' => 'Low',
      'high' => 'High',
      'max' => 'Max',
      _ => optionId,
    };
  }

  static const Map<String, String> _explicitAliases = {
    'deepseek/deepseek-reasoner': 'deepseek-reasoner',
    'deepseek/deepseek-r1': 'deepseek-r1',
    'deepseek/deepseek-r1-zero': 'deepseek-r1-zero',
    'deepseek/deepseek-chat': 'deepseek-chat',
    'deepseek/deepseek-v3': 'deepseek-v3',
    'deepseek/deepseek-chat-v3': 'deepseek-chat-v3',
    'deepseek/deepseek-v4': 'deepseek-v4',
    'deepseek/deepseek-v4-pro': 'deepseek-v4-pro',
    'deepseek/deepseek-v4-flash': 'deepseek-v4-flash',
    'deepseek/deepseek-flash': 'deepseek-flash',
    'deepseek-ai/deepseek-reasoner': 'deepseek-reasoner',
    'deepseek-ai/deepseek-r1': 'deepseek-r1',
    'deepseek-ai/deepseek-r1-zero': 'deepseek-r1-zero',
    'deepseek-ai/deepseek-chat': 'deepseek-chat',
    'deepseek-ai/deepseek-v3': 'deepseek-v3',
    'deepseek-ai/deepseek-chat-v3': 'deepseek-chat-v3',
    'deepseek-ai/deepseek-v4': 'deepseek-v4',
    'deepseek-ai/deepseek-v4-pro': 'deepseek-v4-pro',
    'deepseek-ai/deepseek-v4-flash': 'deepseek-v4-flash',
    'deepseek-ai/deepseek-flash': 'deepseek-flash',
    'deepseek-ai/DeepSeek-V3': 'deepseek-v3',
    'deepseek-ai/DeepSeek-R1': 'deepseek-r1',
  };

  static String _canonicalize(String modelId) {
    final trimmed = modelId.trim();
    return _explicitAliases[trimmed] ?? trimmed;
  }
}
