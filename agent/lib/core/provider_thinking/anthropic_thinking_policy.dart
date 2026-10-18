/// Anthropic Messages thinking policy (Task 43 Gate F).
library;

import 'anthropic_model_catalog.dart';
import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

class AnthropicThinkingPolicy implements ProviderThinkingPolicy {
  const AnthropicThinkingPolicy();

  static const policyIdentifier = 'anthropic_thinking';

  @override
  String get policyId => policyIdentifier;

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final kind = AnthropicModelCatalog.thinkingKindForModel(context.modelId);
    if (kind == AnthropicRouteThinkingKind.unsupported) {
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      );
    }

    final options = <ThinkingControlOption>[];
    if (AnthropicModelCatalog.supportsExplicitOff(context.modelId)) {
      options.add(
        const ThinkingControlOption(id: 'off', label: 'Off', isOff: true),
      );
    }

    switch (kind) {
      case AnthropicRouteThinkingKind.manualBudget:
        options.addAll(
          AnthropicModelCatalog.budgetOptionIdsForModel(context.modelId)
              .map(
                (id) => ThinkingControlOption(
                  id: id,
                  label: AnthropicModelCatalog.labelForOptionId(id),
                  // Disclose the exact token count this route resolves for the
                  // option, from the catalog's own budget authority.
                  budgetTokens: AnthropicModelCatalog.budgetTokensForSelection(
                    modelId: context.modelId,
                    selectionId: id,
                  ),
                ),
              )
              .toList(growable: false),
        );
        return ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.tokenBudget,
          options: options,
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
      case AnthropicRouteThinkingKind.adaptive:
        options.addAll(
          AnthropicModelCatalog.adaptiveEffortOptionIdsForModel(context.modelId)
              .map(
                (id) => ThinkingControlOption(
                  id: id,
                  label: AnthropicModelCatalog.labelForOptionId(id),
                ),
              )
              .toList(growable: false),
        );
        return ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.adaptive,
          options: options,
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
      case AnthropicRouteThinkingKind.unsupported:
        return ThinkingControlDescriptor.unsupported(
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
    }
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

    if (trimmed == 'off') {
      if (!AnthropicModelCatalog.supportsExplicitOff(context.modelId)) {
        return const UseProviderDefault();
      }
      return const ThinkingToggleDirective(enabled: false);
    }

    final kind = AnthropicModelCatalog.thinkingKindForModel(context.modelId);
    switch (kind) {
      case AnthropicRouteThinkingKind.manualBudget:
        final budget = AnthropicModelCatalog.budgetTokensForSelection(
          modelId: context.modelId,
          selectionId: trimmed,
        );
        if (budget == null) {
          return const UseProviderDefault();
        }
        return AnthropicBudgetDirective(budget);
      case AnthropicRouteThinkingKind.adaptive:
        if (!AnthropicModelCatalog.allowsAdaptiveEffortId(
          modelId: context.modelId,
          effortId: trimmed,
        )) {
          return const UseProviderDefault();
        }
        return AnthropicAdaptiveDirective(trimmed);
      case AnthropicRouteThinkingKind.unsupported:
        return const UseProviderDefault();
    }
  }
}
