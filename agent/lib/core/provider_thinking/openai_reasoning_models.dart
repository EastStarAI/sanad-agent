/// Reasoning-model heuristics shared by OpenAI Chat and Codex policies.
library;

import 'thinking_policy_context.dart';

/// Canonical effort tiers exposed by OpenAI-family reasoning policies.
const openAiEffortTierLabels = <String, String>{
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
  'xhigh': 'Extra High',
  'max': 'Max',
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
    if (_supportsMaxEffort(normalized)) {
      return const ['low', 'medium', 'high', 'xhigh', 'max'];
    }
    return const ['low', 'medium', 'high', 'xhigh'];
  }

  static bool _supportsMaxEffort(String normalized) {
    return normalized.contains('gpt-5.6') ||
        normalized.contains('gpt-6') ||
        normalized.contains('astra') ||
        normalized.contains('daybreak');
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
        normalized.contains('astra') ||
        normalized.contains('daybreak') ||
        normalized.contains('reasoning') ||
        normalized.contains('deepseek-r') ||
        normalized.contains('deepseek-v') ||
        normalized.contains('deepseek-flash') ||
        normalized.contains('kimi') ||
        normalized.contains('glm') ||
        normalized.contains('qwen') ||
        normalized.contains('minimax') ||
        normalized.contains('mimo') ||
        normalized.contains('hy') ||
        normalized.contains('longcat') ||
        normalized.contains('codex');
  }
}
