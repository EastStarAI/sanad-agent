/// Standard-effort facts for exact model families on a generic compatible wire.
///
/// A family whose native control is a provider envelope (`thinking.type`, a
/// template kwarg or a budget) does not automatically expose that envelope on
/// an arbitrary compatible Chat route. What *is* documented for these exact
/// models is their effective effort ladder, and the standard
/// OpenAI-compatible `reasoning_effort` field already carries it.
///
/// This authority owns **no inventory of its own**: it derives the compatible
/// subset from the existing exact model-owned authorities
/// ([DeepSeekModelCatalog] and [KimiThinkingPolicy]), so exact ids, verified
/// aliases, case/namespace negatives and future corrections stay in one place.
/// It exposes positive effort values only — the native-only `off` disable and
/// the family default stay owned by the first-party envelope or the serving
/// channel, never invented here.
library;

import 'deepseek_model_catalog.dart';
import 'kimi_thinking_policy.dart';

class CompatibleChatEffortFacts {
  CompatibleChatEffortFacts._();

  /// The documented positive effort ladder for [modelId], derived from the
  /// existing exact authorities, or an empty list when no exact family fact
  /// evidences a standard effort on this wire.
  static List<String> effortOptionIdsForModel(String modelId) {
    final deepSeekKind = DeepSeekModelCatalog.thinkingKindForModel(modelId);
    if (deepSeekKind == DeepSeekRouteThinkingKind.toggleEffort) {
      return DeepSeekModelCatalog.optionIdsForModel(
        modelId,
      ).where((id) => id != 'off').toList(growable: false);
    }
    if (KimiThinkingPolicy.thinkingKindForModel(modelId) ==
        KimiRouteThinkingKind.effort) {
      return KimiThinkingPolicy.optionIdsForModel(modelId);
    }
    return const [];
  }

  static bool isEvidencedModel(String modelId) =>
      effortOptionIdsForModel(modelId).isNotEmpty;

  static bool allowsEffortId({
    required String modelId,
    required String effortId,
  }) => effortOptionIdsForModel(modelId).contains(effortId.trim());

  /// The compatible wire never advertises a family default; omission stays
  /// provider-managed.
  static String? defaultEffortIdForModel(String modelId) => null;

  static String labelForEffortId(String effortId) {
    return switch (effortId) {
      'minimal' => 'Minimal',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'xhigh' => 'Extra High',
      'max' => 'Max',
      _ => effortId,
    };
  }
}
