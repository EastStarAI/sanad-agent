/// Exact and native reasoning model specifications shared by OpenAI Chat and Codex policies.
library;

import 'thinking_policy_context.dart';

/// Canonical effort tiers exposed by OpenAI-family reasoning policies.
const openAiEffortTierLabels = <String, String>{
  'none': 'None',
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
  'xhigh': 'Extra High',
  'max': 'Max',
};

class CodexNativeReasoningSchema {
  final List<String> supportedEfforts;
  final String? defaultEffort;

  const CodexNativeReasoningSchema({
    required this.supportedEfforts,
    this.defaultEffort,
  });

  /// Lean strict parser for native OpenAI Codex model metadata.
  ///
  /// Requires exact-model-owned metadata: if [expectedModelId] is supplied and
  /// [metadata] carries an explicit `slug` or `id`, they must match exactly
  /// without generic namespace/case/substring heuristics.
  ///
  /// Parses `supported_reasoning_levels` where each item must be a Map containing
  /// a non-empty String `effort`. If `default_reasoning_level` is present, it must
  /// be a non-empty String matching one of the supported efforts.
  ///
  /// Any invalid, malformed, empty, or mixed values fail closed (returns null).
  static CodexNativeReasoningSchema? tryParse(
    Map<String, Object?>? metadata, {
    String? expectedModelId,
  }) {
    if (metadata == null) return null;

    if (expectedModelId != null) {
      final rawSlug = metadata['slug'] ?? metadata['id'];
      if (rawSlug != null) {
        if (rawSlug is! String) return null;
        if (rawSlug != expectedModelId &&
            rawSlug != OpenAiReasoningModels._canonicalize(expectedModelId)) {
          return null;
        }
      }
    }

    final rawLevels = metadata['supported_reasoning_levels'];
    if (rawLevels is! List || rawLevels.isEmpty) {
      return null;
    }

    final efforts = <String>[];
    for (final item in rawLevels) {
      if (item is! Map) return null;
      final effort = item['effort'];
      if (effort is! String) return null;
      final trimmed = effort.trim();
      if (trimmed.isEmpty) return null;
      if (!efforts.contains(trimmed)) {
        efforts.add(trimmed);
      }
    }

    if (efforts.isEmpty) {
      return null;
    }

    final rawDefault = metadata['default_reasoning_level'];
    String? defaultEffort;
    if (rawDefault != null) {
      if (rawDefault is! String) return null;
      final trimmedDefault = rawDefault.trim();
      if (trimmedDefault.isEmpty || !efforts.contains(trimmedDefault)) {
        return null;
      }
      defaultEffort = trimmedDefault;
    }

    return CodexNativeReasoningSchema(
      supportedEfforts: List.unmodifiable(efforts),
      defaultEffort: defaultEffort,
    );
  }
}

class OpenAiReasoningModels {
  OpenAiReasoningModels._();

  static const Map<String, List<String>> _exactModelTiers = {
    // o1
    'o1': ['medium', 'high'],
    'o1-2024-12-17': ['medium', 'high'],
    // o3-mini
    'o3-mini': ['low', 'medium', 'high'],
    'o3-mini-2025-01-31': ['low', 'medium', 'high'],
    // o3
    'o3': ['low', 'medium', 'high'],
    // Codex / GPT reasoning
    // https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini.md
    'gpt-5.1-codex-mini': ['low', 'medium', 'high', 'xhigh'],
    // https://developers.openai.com/api/docs/models/gpt-5.2-codex.md
    'gpt-5.2-codex': ['low', 'medium', 'high', 'xhigh'],
    // https://developers.openai.com/api/docs/models/gpt-5.6-sol.md:
    // Model ID: gpt-5.6-sol.
    // Reasoning.effort supports: none, low, medium (default), high, xhigh, and max.
    'gpt-5.6-sol': ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
    // https://developers.openai.com/api/docs/models/gpt-6-astra.md and
    // https://developers.openai.com/api/docs/guides/reasoning.md:
    // Model ID: gpt-6-astra. Reasoning.effort supports low, medium, high, xhigh, and max. Rejects none.
    'gpt-6-astra': ['low', 'medium', 'high', 'xhigh', 'max'],
  };

  static const Map<String, String> _exactModelDefaults = {
    // Documented legacy OpenAI reasoning defaults:
    // reasoning_effort defaults to medium for o1 and o3-mini.
    'o1': 'medium',
    'o1-2024-12-17': 'medium',
    'o3-mini': 'medium',
    'o3-mini-2025-01-31': 'medium',
    'o3': 'medium',
    // https://developers.openai.com/api/docs/models/gpt-5.6-sol.md:
    // Model ID: gpt-5.6-sol. Reasoning.effort supports: none, low, medium (default), high, xhigh, and max.
    'gpt-5.6-sol': 'medium',
    // Note: gpt-5.1-codex-mini, gpt-5.2-codex, and gpt-6-astra document supported effort
    // tiers but do NOT document an exact default reasoning level in official docs.
    // Their defaults remain null (provider-managed omission).
  };

  static const Map<String, String> _explicitAliases = {
    'openai/o1': 'o1',
    'openai/o1-2024-12-17': 'o1-2024-12-17',
    'openai/o3-mini': 'o3-mini',
    'openai/o3-mini-2025-01-31': 'o3-mini-2025-01-31',
    'openai/o3': 'o3',
    'openai/gpt-5.6-sol': 'gpt-5.6-sol',
    'openai/gpt-6-astra': 'gpt-6-astra',
  };

  static bool isEvidencedModel(
    String modelId, {
    Map<String, Object?>? metadata,
  }) {
    final parsed = CodexNativeReasoningSchema.tryParse(
      metadata,
      expectedModelId: modelId,
    );
    if (parsed != null) {
      return true;
    }
    final canonical = _canonicalize(modelId);
    return _exactModelTiers.containsKey(canonical);
  }

  static bool supportsReasoningControls(ThinkingPolicyContext context) {
    // Reasoning output and user-selectable thinking controls are independent
    // facts (Task 43 Gate B).
    return isEvidencedModel(context.modelId, metadata: context.modelMetadata);
  }

  static List<String> effortOptionIdsForModel(
    String modelId, {
    Map<String, Object?>? metadata,
  }) {
    final parsed = CodexNativeReasoningSchema.tryParse(
      metadata,
      expectedModelId: modelId,
    );
    if (parsed != null) {
      return parsed.supportedEfforts;
    }
    final canonical = _canonicalize(modelId);
    return _exactModelTiers[canonical] ?? const [];
  }

  static String? defaultEffortIdForModel(
    String modelId, {
    Map<String, Object?>? metadata,
  }) {
    final parsed = CodexNativeReasoningSchema.tryParse(
      metadata,
      expectedModelId: modelId,
    );
    if (parsed != null) {
      return parsed.defaultEffort;
    }
    final canonical = _canonicalize(modelId);
    return _exactModelDefaults[canonical];
  }

  static String labelForEffortId(String effortId) {
    return openAiEffortTierLabels[effortId] ?? effortId;
  }

  static bool allowsEffortId(
    String modelId,
    String effortId, {
    Map<String, Object?>? metadata,
  }) {
    return effortOptionIdsForModel(
      modelId,
      metadata: metadata,
    ).contains(effortId);
  }

  static String _canonicalize(String modelId) {
    final trimmed = modelId.trim();
    return _explicitAliases[trimmed] ?? trimmed;
  }
}
