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

    final declaration = OllamaThinkingProbe.parseThinkingDeclaration(
      context.modelMetadata,
    );
    if (declaration == null) {
      // Absent or malformed native thinking declaration => fail closed to unknown.
      return ThinkingControlDescriptor.unknown(
        capabilityRevision: context.capabilityRevision,
        source: 'live',
      );
    }

    return switch (declaration) {
      OllamaBooleanThinkingDeclaration(:final values, :final defaultValue) =>
        ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.toggle,
          options: [
            if (values.contains(false))
              ThinkingControlOption(
                id: 'off',
                label: 'Off',
                isOff: true,
                isProviderDefault: !defaultValue,
              ),
            if (values.contains(true))
              ThinkingControlOption(
                id: 'on',
                label: 'On',
                isOff: false,
                isProviderDefault: defaultValue,
              ),
          ],
          defaultOptionId: defaultValue ? 'on' : 'off',
          capabilityRevision: context.capabilityRevision,
          source: 'live',
        ),
      OllamaLevelThinkingDeclaration(:final values, :final defaultValue) =>
        ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          options: values
              .map(
                (val) => ThinkingControlOption(
                  id: val,
                  label: _labelForOptionId(val),
                  isOff: val == 'off' || val == 'none',
                  isProviderDefault:
                      defaultValue != null && val == defaultValue,
                ),
              )
              .toList(growable: false),
          defaultOptionId: defaultValue,
          capabilityRevision: context.capabilityRevision,
          source: 'live',
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

    final declaration = OllamaThinkingProbe.parseThinkingDeclaration(
      context.modelMetadata,
    );
    if (declaration == null) {
      return const UseProviderDefault();
    }

    switch (declaration) {
      case OllamaBooleanThinkingDeclaration(:final values):
        if ((trimmed == 'off' || trimmed == 'false') &&
            values.contains(false)) {
          return const ThinkingToggleDirective(enabled: false);
        }
        if ((trimmed == 'on' || trimmed == 'true') && values.contains(true)) {
          return const ThinkingToggleDirective(enabled: true);
        }
        return const UseProviderDefault();

      case OllamaLevelThinkingDeclaration(:final values):
        if (!values.contains(trimmed)) {
          return const UseProviderDefault();
        }
        return OllamaThinkLevelDirective(trimmed);
    }
  }

  String _labelForOptionId(String optionId) {
    return switch (optionId.toLowerCase()) {
      'off' => 'Off',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'max' => 'Max',
      _ =>
        optionId.isEmpty
            ? optionId
            : optionId[0].toUpperCase() + optionId.substring(1),
    };
  }
}
