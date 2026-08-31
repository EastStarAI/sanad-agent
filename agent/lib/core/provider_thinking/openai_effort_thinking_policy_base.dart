/// Shared OpenAI-family effort policy logic (Task 43 Gate E).
library;

import 'native_thinking_directive.dart';
import 'openai_reasoning_models.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

abstract class OpenAiEffortThinkingPolicyBase implements ProviderThinkingPolicy {
  const OpenAiEffortThinkingPolicyBase();

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    if (!OpenAiReasoningModels.supportsReasoningControls(context)) {
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      );
    }

    final optionIds = OpenAiReasoningModels.effortOptionIdsForModel(
      context.modelId,
    );
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: optionIds
          .map(
            (id) => ThinkingControlOption(
              id: id,
              label: OpenAiReasoningModels.labelForEffortId(id),
            ),
          )
          .toList(growable: false),
      capabilityRevision: context.capabilityRevision,
      source: 'profile',
    );
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
    if (!OpenAiReasoningModels.allowsEffortId(context.modelId, trimmed)) {
      return const UseProviderDefault();
    }
    return buildDirective(trimmed);
  }

  NativeThinkingDirective buildDirective(String effort);
}
