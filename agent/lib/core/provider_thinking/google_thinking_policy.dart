/// Google Gemini thinking policy (Task 43 Gate G).
library;

import 'google_model_catalog.dart';
import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

class GoogleThinkingPolicy implements ProviderThinkingPolicy {
  const GoogleThinkingPolicy();

  @override
  String get policyId => 'google_thinking';

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final kind = GoogleModelCatalog.thinkingKindForModel(context.modelId);
    if (kind == GoogleRouteThinkingKind.unsupported) {
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      );
    }

    final options = <ThinkingControlOption>[];
    switch (kind) {
      case GoogleRouteThinkingKind.tokenBudget:
        options.addAll(
          GoogleModelCatalog.budgetOptionIdsForModel(context.modelId)
              .map(
                (id) => ThinkingControlOption(
                  id: id,
                  label: GoogleModelCatalog.labelForOptionId(id),
                  isOff: id == 'off',
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
      case GoogleRouteThinkingKind.level:
        options.addAll(
          GoogleModelCatalog.levelOptionIdsForModel(context.modelId)
              .map(
                (id) => ThinkingControlOption(
                  id: id,
                  label: GoogleModelCatalog.labelForOptionId(id),
                ),
              )
              .toList(growable: false),
        );
        return ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.level,
          options: options,
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
      case GoogleRouteThinkingKind.unsupported:
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

    final kind = GoogleModelCatalog.thinkingKindForModel(context.modelId);
    switch (kind) {
      case GoogleRouteThinkingKind.tokenBudget:
        if (trimmed == 'off') {
          return const GoogleBudgetDirective(0);
        }
        final budget = GoogleModelCatalog.budgetTokensForSelection(
          modelId: context.modelId,
          selectionId: trimmed,
        );
        if (budget == null) {
          return const UseProviderDefault();
        }
        return GoogleBudgetDirective(budget);
      case GoogleRouteThinkingKind.level:
        if (!GoogleModelCatalog.allowsLevelSelectionId(
          modelId: context.modelId,
          levelId: trimmed,
        )) {
          return const UseProviderDefault();
        }
        return GoogleLevelDirective(trimmed);
      case GoogleRouteThinkingKind.unsupported:
        return const UseProviderDefault();
    }
  }
}
