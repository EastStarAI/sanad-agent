/// NVIDIA NIM Chat thinking policy (hosted catalog contracts).
///
/// The shipped `nvidia` template is the hosted NIM catalog
/// (`https://integrate.api.nvidia.com/v1`, OpenAI-compatible Chat). Its
/// per-model contracts are mode-owned and differ from the first-party vendor
/// APIs, so this policy is selected before any first-party extension can leak
/// onto the NIM transport.
///
/// Official per-model evidence (hosted NIM reference pages):
/// * `deepseek-ai/deepseek-v4-flash` / `deepseek-ai/deepseek-v4-pro` —
///   `reasoning_effort` accepts `none`/`high`/`max` (default `high`); `none`
///   disables thinking. No `thinking.type` envelope is documented.
/// * `moonshotai/kimi-k3` — `reasoning_effort` accepts `low`/`high`/`max`
///   (default `max`), a per-request override of the serve-time default.
/// * `moonshotai/kimi-k2.6` — `chat_template_kwargs: {"thinking": bool}`; no
///   `reasoning_effort` and no documented default.
/// * `qwen/qwen3.5-122b-a10b` — `chat_template_kwargs:
///   {"enable_thinking": bool}`; no effort tiers and no documented default.
///
/// Everything else on this route stays `unknown`: models whose hosted page
/// documents no request-time control (`deepseek-ai/deepseek-v4.1-flash`,
/// `moonshotai/kimi-k2-thinking`, `qwen/qwen3-next-80b-a3b-thinking`) and ids
/// that are only documented for a self-hosted container (`qwen/qwen3.8-27b`)
/// never inherit another transport's facts.
library;

import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

/// One documented hosted-NIM per-model contract.
class NimThinkingContract {
  final ThinkingControlKind kind;
  final List<String> optionIds;
  final String? defaultOptionId;
  final String? offOptionId;

  /// `chat_template_kwargs` key when the contract toggles via a template
  /// Boolean instead of an effort field.
  final String? templateKwargsKey;

  const NimThinkingContract({
    required this.kind,
    required this.optionIds,
    this.defaultOptionId,
    this.offOptionId,
    this.templateKwargsKey,
  });
}

class NimThinkingPolicy implements ProviderThinkingPolicy {
  const NimThinkingPolicy();

  static const policyIdentifier = 'nim_thinking';

  /// Exact documented hosted ids. Never namespaces, prefixes or families.
  static const contracts = <String, NimThinkingContract>{
    'deepseek-ai/deepseek-v4-flash': NimThinkingContract(
      kind: ThinkingControlKind.effort,
      optionIds: ['none', 'high', 'max'],
      defaultOptionId: 'high',
      offOptionId: 'none',
    ),
    'deepseek-ai/deepseek-v4-pro': NimThinkingContract(
      kind: ThinkingControlKind.effort,
      optionIds: ['none', 'high', 'max'],
      defaultOptionId: 'high',
      offOptionId: 'none',
    ),
    'moonshotai/kimi-k3': NimThinkingContract(
      kind: ThinkingControlKind.effort,
      optionIds: ['low', 'high', 'max'],
      defaultOptionId: 'max',
    ),
    'moonshotai/kimi-k2.6': NimThinkingContract(
      kind: ThinkingControlKind.toggle,
      optionIds: ['on', 'off'],
      offOptionId: 'off',
      templateKwargsKey: 'thinking',
    ),
    'qwen/qwen3.5-122b-a10b': NimThinkingContract(
      kind: ThinkingControlKind.toggle,
      optionIds: ['on', 'off'],
      offOptionId: 'off',
      templateKwargsKey: 'enable_thinking',
    ),
  };

  static bool isEvidencedModel(String modelId) =>
      contracts.containsKey(modelId.trim());

  static NimThinkingContract? contractForModel(String modelId) =>
      contracts[modelId.trim()];

  @override
  String get policyId => policyIdentifier;

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final contract = contractForModel(context.modelId);
    if (contract == null) {
      return ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'profile',
      );
    }

    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: contract.kind,
      options: contract.optionIds
          .map(
            (id) => ThinkingControlOption(
              id: id,
              label: _labelFor(id),
              isOff: contract.offOptionId != null && id == contract.offOptionId,
              isProviderDefault: contract.defaultOptionId == id,
            ),
          )
          .toList(growable: false),
      defaultOptionId: contract.defaultOptionId,
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

    final contract = contractForModel(context.modelId);
    if (contract == null || !contract.optionIds.contains(trimmed)) {
      return const UseProviderDefault();
    }

    final kwargsKey = contract.templateKwargsKey;
    if (kwargsKey != null) {
      return ChatTemplateBooleanDirective(
        key: kwargsKey,
        value: trimmed == 'on',
      );
    }
    return OpenAiEffortDirective(trimmed);
  }

  static String _labelFor(String optionId) {
    return switch (optionId) {
      'none' => 'None',
      'low' => 'Low',
      'high' => 'High',
      'max' => 'Max',
      'on' => 'On',
      'off' => 'Off',
      _ => optionId,
    };
  }
}
