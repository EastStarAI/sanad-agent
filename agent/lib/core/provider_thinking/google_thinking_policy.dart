/// Google Gemini thinking policy (Task 43 Gate G).
///
/// The descriptor is built from the exact per-model documented facts in
/// [GoogleModelCatalog]; no option set or default is shared across models.
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
    final defaultOptionId = GoogleModelCatalog.defaultOptionIdForModel(
      context.modelId,
    );

    switch (kind) {
      case GoogleRouteThinkingKind.tokenBudget:
        return ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.tokenBudget,
          options: GoogleModelCatalog.budgetOptionIdsForModel(context.modelId)
              .map(
                (id) => ThinkingControlOption(
                  id: id,
                  label: GoogleModelCatalog.labelForOptionId(id),
                  isOff: id == 'off',
                  isProviderDefault: id == defaultOptionId,
                  // The documented disable resolves to a zero budget and is
                  // Off, not a budget: only positive counts are disclosed.
                  budgetTokens: switch (GoogleModelCatalog
                      .budgetTokensForSelection(
                        modelId: context.modelId,
                        selectionId: id,
                      )) {
                    final int tokens when tokens > 0 => tokens,
                    _ => null,
                  },
                ),
              )
              .toList(growable: false),
          defaultOptionId: defaultOptionId,
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
      case GoogleRouteThinkingKind.level:
        return ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.level,
          options: GoogleModelCatalog.levelOptionIdsForModel(context.modelId)
              .map(
                (id) => ThinkingControlOption(
                  id: id,
                  label: GoogleModelCatalog.labelForOptionId(id),
                  isProviderDefault: id == defaultOptionId,
                ),
              )
              .toList(growable: false),
          defaultOptionId: defaultOptionId,
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
      case GoogleRouteThinkingKind.unsupported:
        return ThinkingControlDescriptor.unsupported(
          capabilityRevision: context.capabilityRevision,
          source: 'profile',
        );
      case GoogleRouteThinkingKind.unknown:
        return ThinkingControlDescriptor.unknown(
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
      case GoogleRouteThinkingKind.unknown:
        return const UseProviderDefault();
    }
  }
}
