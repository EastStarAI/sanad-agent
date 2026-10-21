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
        if (rawSlug != expectedModelId) {
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

/// Provider-reported OpenAI/Codex reasoning facts.
///
/// Capability comes only from the exact model's own discovery item
/// ([CodexNativeReasoningSchema]); there is no model-name table.
class OpenAiReasoningModels {
  OpenAiReasoningModels._();

  static CodexNativeReasoningSchema? _schema(
    String modelId,
    Map<String, Object?>? metadata,
  ) => CodexNativeReasoningSchema.tryParse(metadata, expectedModelId: modelId);

  static bool isEvidencedModel(
    String modelId, {
    Map<String, Object?>? metadata,
  }) => _schema(modelId, metadata) != null;

  static bool supportsReasoningControls(ThinkingPolicyContext context) {
    // Reasoning output and user-selectable thinking controls are independent
    // facts (Task 43 Gate B).
    return isEvidencedModel(context.modelId, metadata: context.modelMetadata);
  }

  static List<String> effortOptionIdsForModel(
    String modelId, {
    Map<String, Object?>? metadata,
  }) => _schema(modelId, metadata)?.supportedEfforts ?? const [];

  static String? defaultEffortIdForModel(
    String modelId, {
    Map<String, Object?>? metadata,
  }) => _schema(modelId, metadata)?.defaultEffort;

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
}
