/// Z.AI / GLM thinking policy (Task 43 / Finding 6).
library;

import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';
import 'zai_model_catalog.dart';

class ZaiThinkingPolicy implements ProviderThinkingPolicy {
  const ZaiThinkingPolicy();

  static const policyIdentifier = 'zai_thinking';

  @override
  String get policyId => policyIdentifier;

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final kind = ZaiModelCatalog.thinkingKindForModel(context.modelId);
    final defaultOptionId = ZaiModelCatalog.defaultOptionIdForModel(
      context.modelId,
    );
    return switch (kind) {
      ZaiRouteThinkingKind.unknown => ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      ZaiRouteThinkingKind.unsupported => ThinkingControlDescriptor.unsupported(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      ZaiRouteThinkingKind.toggleOnly => ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.toggle,
        options: ZaiModelCatalog.optionIdsForModel(context.modelId)
            .map(
              (id) => ThinkingControlOption(
                id: id,
                label: ZaiModelCatalog.labelForOptionId(id),
                isOff: id == 'off',
                isProviderDefault:
                    defaultOptionId != null && id == defaultOptionId,
              ),
            )
            .toList(growable: false),
        defaultOptionId: defaultOptionId,
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      ZaiRouteThinkingKind.effortWithDisable => ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: ZaiModelCatalog.optionIdsForModel(context.modelId)
            .map(
              (id) => ThinkingControlOption(
                id: id,
                label: ZaiModelCatalog.labelForOptionId(id),
                isOff: id == 'off',
                isProviderDefault:
                    defaultOptionId != null && id == defaultOptionId,
              ),
            )
            .toList(growable: false),
        defaultOptionId: defaultOptionId,
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      ),
      ZaiRouteThinkingKind.forcedEffort => ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: ZaiModelCatalog.optionIdsForModel(context.modelId)
            .map(
              (id) => ThinkingControlOption(
                id: id,
                label: ZaiModelCatalog.labelForOptionId(id),
                isOff: false,
                isProviderDefault:
                    defaultOptionId != null && id == defaultOptionId,
              ),
            )
            .toList(growable: false),
        defaultOptionId: defaultOptionId,
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

    final kind = ZaiModelCatalog.thinkingKindForModel(context.modelId);
    if (kind == ZaiRouteThinkingKind.unknown ||
        kind == ZaiRouteThinkingKind.unsupported) {
      return const UseProviderDefault();
    }
    if (!ZaiModelCatalog.allowsSelectionId(
      modelId: context.modelId,
      selectionId: trimmed,
    )) {
      return const UseProviderDefault();
    }
    if (trimmed == 'off') {
      return const ThinkingToggleDirective(enabled: false);
    }
    if (trimmed == 'on') {
      return const ThinkingToggleDirective(enabled: true);
    }
    return OpenAiEffortDirective(trimmed);
  }
}
