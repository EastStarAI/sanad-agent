/// DeepSeek thinking policy with fail-closed unknown routes (Task 43 Gate G).
library;

import 'deepseek_model_catalog.dart';
import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

class DeepSeekThinkingPolicy implements ProviderThinkingPolicy {
  const DeepSeekThinkingPolicy();

  @override
  String get policyId => 'deepseek_thinking';

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final kind = DeepSeekModelCatalog.thinkingKindForModel(context.modelId);
    return switch (kind) {
      DeepSeekRouteThinkingKind.unknown => ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      DeepSeekRouteThinkingKind.unsupported =>
        ThinkingControlDescriptor.unsupported(
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        ),
      DeepSeekRouteThinkingKind.toggleEffort => ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.toggle,
        options: DeepSeekModelCatalog.optionIdsForModel(context.modelId)
            .map(
              (id) => ThinkingControlOption(
                id: id,
                label: DeepSeekModelCatalog.labelForOptionId(id),
                isOff: id == 'off',
              ),
            )
            .toList(growable: false),
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

    final kind = DeepSeekModelCatalog.thinkingKindForModel(context.modelId);
    if (kind != DeepSeekRouteThinkingKind.toggleEffort) {
      return const UseProviderDefault();
    }
    if (!DeepSeekModelCatalog.allowsSelectionId(
      modelId: context.modelId,
      selectionId: trimmed,
    )) {
      return const UseProviderDefault();
    }
    if (trimmed == 'off') {
      return const ThinkingToggleDirective(enabled: false);
    }
    return OpenAiEffortDirective(trimmed);
  }
}
