/// Ollama local thinking policy (Task 43 Gate G/B).
library;

import 'native_thinking_directive.dart';
import 'ollama_thinking_probe.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';

class OllamaLiveThinkingPolicy implements ProviderThinkingPolicy {
  const OllamaLiveThinkingPolicy();

  @override
  String get policyId => 'ollama_live';

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    final probeResult = OllamaThinkingProbe.hasThinkingCapability(
      context.modelMetadata,
    );
    if (probeResult == null) {
      return ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'live',
      );
    }
    if (!probeResult) {
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: context.capabilityRevision,
        source: 'live',
      );
    }

    final optionIds = _optionIdsForModel(context);
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: optionIds
          .map(
            (id) => ThinkingControlOption(
              id: id,
              label: _labelForOptionId(id),
              isOff: id == 'off',
            ),
          )
          .toList(growable: false),
      capabilityRevision: context.capabilityRevision,
      source: 'live',
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
    if (trimmed == 'off') {
      return const ThinkingToggleDirective(enabled: false);
    }
    if (!_optionIdsForModel(context).contains(trimmed)) {
      return const UseProviderDefault();
    }
    return OllamaThinkLevelDirective(trimmed);
  }

  List<String> _optionIdsForModel(ThinkingPolicyContext context) {
    if (OllamaThinkingProbe.requiresLevelOnly(
      context.modelMetadata,
      context.modelId,
    )) {
      return const ['low', 'medium', 'high'];
    }
    return const ['off', 'low', 'medium', 'high', 'max'];
  }

  String _labelForOptionId(String optionId) {
    return switch (optionId) {
      'off' => 'Off',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'max' => 'Max',
      _ => optionId,
    };
  }
}
