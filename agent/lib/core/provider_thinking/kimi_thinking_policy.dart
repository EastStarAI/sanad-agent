/// Kimi thinking policy grounded in official documentation.
///
/// Grounding: https://platform.kimi.ai/docs/guide/use-thinking-models
library;

import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

enum KimiRouteThinkingKind {
  unknown,
  unsupported,
  effort,
  toggle,
}

class KimiThinkingPolicy implements ProviderThinkingPolicy {
  const KimiThinkingPolicy();

  static const policyIdentifier = 'kimi_thinking';

  @override
  String get policyId => policyIdentifier;

  static const exactK3Models = {
    'kimi-k3',
  };

  static const exactK26Models = {
    'kimi-k2.6',
  };

  static const exactK27Models = {
    'kimi-k2.7-code',
    'kimi-k2.7-code-highspeed',
  };

  static const exactLegacyMoonshotModels = {
    'moonshot-v1-8k',
    'moonshot-v1-32k',
    'moonshot-v1-128k',
  };

  static const effortOptionIds = ['low', 'high', 'max'];
  static const toggleOptionIds = ['on', 'off'];

  /// Exact case-preserving match for evidenced Kimi models.
  /// Negatives such as `KIMI-K3`, `unknown-vendor/kimi-k3`, `kimi-k3-custom`,
  /// or `unknown/moonshot-v1-8k` must NOT match.
  static bool isEvidencedModel(String modelId) {
    final trimmed = modelId.trim();
    return exactK3Models.contains(trimmed) ||
        exactK26Models.contains(trimmed) ||
        exactK27Models.contains(trimmed) ||
        exactLegacyMoonshotModels.contains(trimmed);
  }

  static KimiRouteThinkingKind thinkingKindForModel(String modelId) {
    final trimmed = modelId.trim();
    if (exactK3Models.contains(trimmed)) {
      return KimiRouteThinkingKind.effort;
    }
    if (exactK26Models.contains(trimmed)) {
      return KimiRouteThinkingKind.toggle;
    }
    if (exactK27Models.contains(trimmed)) {
      // Documented always-on reasoning with disabled thinking error upstream;
      // status unsupported for runtime adjustment.
      return KimiRouteThinkingKind.unsupported;
    }
    if (exactLegacyMoonshotModels.contains(trimmed)) {
      // Legacy Moonshot models do not support thinking controls.
      return KimiRouteThinkingKind.unsupported;
    }
    return KimiRouteThinkingKind.unknown;
  }

  static List<String> optionIdsForModel(String modelId) {
    final kind = thinkingKindForModel(modelId);
    return switch (kind) {
      KimiRouteThinkingKind.effort => effortOptionIds,
      KimiRouteThinkingKind.toggle => toggleOptionIds,
      _ => const [],
    };
  }

  static String? defaultOptionIdForModel(String modelId) {
    final kind = thinkingKindForModel(modelId);
    return switch (kind) {
      KimiRouteThinkingKind.effort => 'max',
      KimiRouteThinkingKind.toggle => 'on',
      _ => null,
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
      'low' => 'Low',
      'high' => 'High',
      'max' => 'Max',
      'on' => 'On',
      'off' => 'Off',
      _ => optionId,
    };
  }

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final kind = thinkingKindForModel(context.modelId);
    return switch (kind) {
      KimiRouteThinkingKind.unknown => ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      KimiRouteThinkingKind.unsupported =>
        ThinkingControlDescriptor.unsupported(
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        ),
      KimiRouteThinkingKind.effort => ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: optionIdsForModel(context.modelId)
            .map(
              (id) => ThinkingControlOption(
                id: id,
                label: labelForOptionId(id),
                isOff: false,
                isProviderDefault:
                    id == defaultOptionIdForModel(context.modelId),
              ),
            )
            .toList(growable: false),
        defaultOptionId: defaultOptionIdForModel(context.modelId),
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      KimiRouteThinkingKind.toggle => ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.toggle,
        options: optionIdsForModel(context.modelId)
            .map(
              (id) => ThinkingControlOption(
                id: id,
                label: labelForOptionId(id),
                isOff: id == 'off',
                isProviderDefault:
                    id == defaultOptionIdForModel(context.modelId),
              ),
            )
            .toList(growable: false),
        defaultOptionId: defaultOptionIdForModel(context.modelId),
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
    };
  }

  @override
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  ) {
    final trimmed = selectionId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return const UseProviderDefault();
    }

    final kind = thinkingKindForModel(context.modelId);
    if (!allowsSelectionId(
      modelId: context.modelId,
      selectionId: trimmed,
    )) {
      return const UseProviderDefault();
    }

    if (kind == KimiRouteThinkingKind.effort) {
      return OpenAiEffortDirective(trimmed);
    }

    if (kind == KimiRouteThinkingKind.toggle) {
      if (trimmed == 'off') {
        return const ThinkingToggleDirective(enabled: false);
      }
      return const ThinkingToggleDirective(enabled: true);
    }

    return const UseProviderDefault();
  }
}
