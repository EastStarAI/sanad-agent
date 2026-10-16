/// Shared OpenAI-family effort policy logic (Task 43 Gate E).
///
/// The policy owns the Chat/Responses effort *wire family*; the exact model
/// facts it publishes come from model-owned authorities:
/// * the exact OpenAI reasoning catalog and validated native Codex metadata,
/// * exact grounded xAI Grok facts on Chat-compatible modes,
/// * exact grounded `gpt-oss` facts on the compatible Chat reasoning-effort
///   mode (intrinsic model facts, no provider-kind allowlist).
library;

import 'compatible_chat_effort_facts.dart';
import 'gpt_oss_model_catalog.dart';
import 'native_thinking_directive.dart';
import 'openai_reasoning_models.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';
import 'thinking_wire_dialect.dart';
import 'xai_model_catalog.dart';

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

  /// Resolves the exact finite effort facts for the active route, or `null` when
  /// no authority evidences a selectable effort for this model/route.
  static EffortAuthority? resolveEffortAuthority(
    ThinkingPolicyContext context,
  ) {
    // Exact xAI Grok facts are Chat-wire facts; the documented xAI parameter is
    // the Chat `reasoning_effort` field.
    if (isChatMode(context.apiMode) &&
        XaiModelCatalog.supportsEffort(context.modelId)) {
      return EffortAuthority(
        optionIds: XaiModelCatalog.effortOptionIdsForModel(context.modelId),
        defaultOptionId: XaiModelCatalog.defaultEffortIdForModel(
          context.modelId,
        ),
      );
    }

    // Exact `gpt-oss` facts are intrinsic model facts; the compatible Chat
    // reasoning-effort mode is the only wire on which they are advertised.
    final gptOssOptions = isChatMode(context.apiMode)
        ? GptOssModelCatalog.effortOptionIdsForModel(context.modelId)
        : const <String>[];
    if (gptOssOptions.isNotEmpty) {
      return EffortAuthority(
        optionIds: gptOssOptions,
        defaultOptionId: GptOssModelCatalog.defaultEffortIdForModel(
          context.modelId,
        ),
      );
    }

    // Documented standard-effort facts on the compatible wire: the family's
    // effective effort ladder without its native envelope, without a fabricated
    // disable and without an invented family default.
    if (ThinkingWireDialectFacts.forTemplate(
          context.templateId,
          apiMode: context.apiMode,
        ) ==
        ThinkingWireDialect.compatibleChat) {
      final compatible = CompatibleChatEffortFacts.effortOptionIdsForModel(
        context.modelId,
      );
      if (compatible.isNotEmpty) {
        return EffortAuthority(
          optionIds: compatible,
          defaultOptionId: CompatibleChatEffortFacts.defaultEffortIdForModel(
            context.modelId,
          ),
        );
      }
    }

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
    final openAiLabel = openAiEffortTierLabels[effortId];
    if (openAiLabel != null) return openAiLabel;
    return XaiModelCatalog.labelForEffortId(effortId);
  }

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final authority = resolveEffortAuthority(context);
    if (authority == null || !authority.hasOptions) {
      return ThinkingControlDescriptor.unsupported(
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
