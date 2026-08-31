/// Reasoning-model heuristics shared by OpenAI Chat and Codex policies.
library;

import 'thinking_policy_context.dart';

/// Canonical effort tiers exposed by OpenAI-family reasoning policies.
const openAiEffortTierLabels = <String, String>{
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
};

class OpenAiReasoningModels {
  OpenAiReasoningModels._();

  static bool supportsReasoningControls(ThinkingPolicyContext context) {
    // Reasoning output and user-selectable thinking controls are independent
    // facts (Task 43 Gate B).
    return _heuristicMatch(context.modelId);
  }

  static List<String> effortOptionIdsForModel(String modelId) {
    final normalized = _normalizeModelId(modelId);
    if (normalized.startsWith('o1')) {
      return const ['medium', 'high'];
    }
    return const ['low', 'medium', 'high'];
  }

  static String labelForEffortId(String effortId) {
    return openAiEffortTierLabels[effortId] ?? effortId;
  }

  static bool allowsEffortId(String modelId, String effortId) {
    return effortOptionIdsForModel(modelId).contains(effortId);
  }

  static String _normalizeModelId(String modelId) {
    final trimmed = modelId.trim().toLowerCase();
    if (trimmed.contains('/')) {
      return trimmed.split('/').last;
    }
    return trimmed;
  }

  static bool _heuristicMatch(String modelId) {
    final normalized = _normalizeModelId(modelId);
    return normalized.contains('o1') ||
        normalized.contains('o3') ||
        normalized.contains('o4') ||
        normalized.contains('gpt-5') ||
        normalized.contains('gpt-6') ||
        normalized.contains('reasoning') ||
        normalized.contains('deepseek-r') ||
        normalized.contains('codex');
  }
}
