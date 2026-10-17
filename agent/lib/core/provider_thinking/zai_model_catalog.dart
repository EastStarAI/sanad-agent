/// Model catalog and thinking capability classification for Z.AI / GLM models.
library;

enum ZaiRouteThinkingKind {
  unknown,
  unsupported,
  toggleOnly,
  effortWithDisable,
  forcedEffort,
}

class ZaiModelCatalog {
  ZaiModelCatalog._();

  static const _toggleOnlyModels = {
    'glm-4.5',
    'glm-4.5-air',
    'glm-4.7',
    'glm-5',
    'glm-5.1',
    'glm-4.7-flash',
  };

  static const _effortWithDisableModels = {'glm-5.2'};

  static const _forcedEffortModels = {'glm-5.3', 'glm-5.3-flash'};

  static const _standardNonThinkingModels = {
    'glm-4-plus',
    'glm-4-flash',
    'glm-4-9b',
  };

  static const toggleOptionIds = ['off', 'on'];
  static const effortWithDisableOptionIds = ['off', 'high', 'max'];
  static const forcedEffortOptionIds = ['low', 'high', 'max'];

  static String? defaultOptionIdForModel(String modelId) {
    final canonical = _canonicalize(modelId);
    if (canonical == 'glm-4.5' || canonical == 'glm-4.5-air') {
      return null;
    }
    return switch (thinkingKindForModel(canonical)) {
      ZaiRouteThinkingKind.toggleOnly => 'on',
      ZaiRouteThinkingKind.effortWithDisable => 'max',
      ZaiRouteThinkingKind.forcedEffort => 'max',
      ZaiRouteThinkingKind.unsupported || ZaiRouteThinkingKind.unknown => null,
    };
  }

  static bool isEvidencedModel(String modelId) {
    final canonical = _canonicalize(modelId);
    return _toggleOnlyModels.contains(canonical) ||
        _effortWithDisableModels.contains(canonical) ||
        _forcedEffortModels.contains(canonical) ||
        _standardNonThinkingModels.contains(canonical);
  }

  static ZaiRouteThinkingKind thinkingKindForModel(String modelId) {
    final canonical = _canonicalize(modelId);
    if (_toggleOnlyModels.contains(canonical)) {
      return ZaiRouteThinkingKind.toggleOnly;
    }
    if (_effortWithDisableModels.contains(canonical)) {
      return ZaiRouteThinkingKind.effortWithDisable;
    }
    if (_forcedEffortModels.contains(canonical)) {
      return ZaiRouteThinkingKind.forcedEffort;
    }
    if (_standardNonThinkingModels.contains(canonical)) {
      return ZaiRouteThinkingKind.unsupported;
    }
    return ZaiRouteThinkingKind.unknown;
  }

  static List<String> optionIdsForModel(String modelId) {
    return switch (thinkingKindForModel(modelId)) {
      ZaiRouteThinkingKind.toggleOnly => toggleOptionIds,
      ZaiRouteThinkingKind.effortWithDisable => effortWithDisableOptionIds,
      ZaiRouteThinkingKind.forcedEffort => forcedEffortOptionIds,
      ZaiRouteThinkingKind.unsupported ||
      ZaiRouteThinkingKind.unknown => const [],
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
    'z-ai/glm-4.7': 'glm-4.7',
    'z-ai/glm-5': 'glm-5',
    'z-ai/glm-5.1': 'glm-5.1',
    'z-ai/glm-4.7-flash': 'glm-4.7-flash',
    'z-ai/glm-5.2': 'glm-5.2',
    'z-ai/glm-5.3': 'glm-5.3',
    'z-ai/glm-5.3-flash': 'glm-5.3-flash',
    'z-ai/glm-4-plus': 'glm-4-plus',
    'z-ai/glm-4-flash': 'glm-4-flash',
    'z-ai/glm-4-9b': 'glm-4-9b',
    'z-ai/glm-4.5': 'glm-4.5',
    'z-ai/glm-4.5-air': 'glm-4.5-air',
    'zai/glm-4.7': 'glm-4.7',
    'zai/glm-5': 'glm-5',
    'zai/glm-5.1': 'glm-5.1',
    'zai/glm-4.7-flash': 'glm-4.7-flash',
    'zai/glm-5.2': 'glm-5.2',
    'zai/glm-5.3': 'glm-5.3',
    'zai/glm-5.3-flash': 'glm-5.3-flash',
    'zai/glm-4-plus': 'glm-4-plus',
    'zai/glm-4-flash': 'glm-4-flash',
    'zai/glm-4-9b': 'glm-4-9b',
    'zai/glm-4.5': 'glm-4.5',
    'zai/glm-4.5-air': 'glm-4.5-air',
  };

  static String _canonicalize(String modelId) {
    final trimmed = modelId.trim();
    return _explicitAliases[trimmed] ?? trimmed;
  }
}
