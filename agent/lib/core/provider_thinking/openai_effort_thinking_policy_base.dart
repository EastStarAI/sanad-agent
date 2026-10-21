/// Shared OpenAI-family effort policy logic (Task 43 Gate E).
///
/// The policy owns the Chat/Responses effort *wire family*. The only facts it
/// publishes are provider-reported: the exact model's validated native Codex
/// discovery metadata. Without it the route stays `unknown` so the settings and
/// models.dev authority layers decide; no model-name table is consulted.
library;

import 'native_thinking_directive.dart';
import 'openai_reasoning_models.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

/// Exact finite effort facts for one route/model pair.
class EffortAuthority {
  final List<String> optionIds;
  final String? defaultOptionId;

  const EffortAuthority({required this.optionIds, this.defaultOptionId});

  bool get hasOptions => optionIds.isNotEmpty;

  bool allows(String effortId) => optionIds.contains(effortId);
}

abstract class OpenAiEffortThinkingPolicyBase
    implements ProviderThinkingPolicy {
  const OpenAiEffortThinkingPolicyBase();

  /// Whether [apiMode] carries the Chat Completions reasoning-effort field.
  static bool isChatMode(String apiMode) {
    final mode = apiMode.trim().toLowerCase();
    return mode == 'chat_completions' || mode == 'chat';
  }

  /// Resolves the provider-reported finite effort facts for the active route,
  /// or `null` when the exact model's discovery item reports none.
  static EffortAuthority? resolveEffortAuthority(
    ThinkingPolicyContext context,
  ) {
    if (!OpenAiReasoningModels.supportsReasoningControls(context)) {
      return null;
    }
    return EffortAuthority(
      optionIds: OpenAiReasoningModels.effortOptionIdsForModel(
        context.modelId,
        metadata: context.modelMetadata,
      ),
      defaultOptionId: OpenAiReasoningModels.defaultEffortIdForModel(
        context.modelId,
        metadata: context.modelMetadata,
      ),
    );
  }

  static String labelForEffortId(String effortId) {
    return openAiEffortTierLabels[effortId] ?? effortId;
  }

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final authority = resolveEffortAuthority(context);
    if (authority == null || !authority.hasOptions) {
      // No provider-reported facts is absence of evidence, never a positive
      // `unsupported` claim; later authority layers may still resolve it.
      return ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      );
    }

    final defaultOptionId = authority.defaultOptionId;
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: authority.optionIds
          .map(
            (id) => ThinkingControlOption(
              id: id,
              label: labelForEffortId(id),
              isOff: id == 'none',
              isProviderDefault: id == defaultOptionId,
            ),
          )
          .toList(growable: false),
      defaultOptionId: defaultOptionId,
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
    final authority = resolveEffortAuthority(context);
    if (authority == null || !authority.allows(trimmed)) {
      return const UseProviderDefault();
    }
    return buildDirective(trimmed);
  }

  NativeThinkingDirective buildDirective(String effort);
}
