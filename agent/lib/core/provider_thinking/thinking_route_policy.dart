/// Fail-closed thinking policy resolution for provider routes (Task 43 Gate A).
library;

import '../provider_runtime/provider_instance.dart';
import '../provider_runtime/provider_protocol_constants.dart';
import '../../engine/adapters/provider_profile.dart';
import 'kimi_thinking_policy.dart';

class ThinkingRoutePolicy {
  ThinkingRoutePolicy._();

  static const unknownPolicyId = 'unknown';

  /// Resolves the thinking policy id for [instance] and optional [modelId].
  ///
  /// For templates with an explicit thinking policy, that policy is preferred.
  /// For custom instances or templates without a dedicated thinking policy
  /// (effectiveThinkingPolicyId == 'unknown'), exact evidenced model knowledge
  /// is resolved when the route's API mode is compatible.
  ///
  /// Unknown routes fail closed to [unknownPolicyId] per Plan 29 §3.10.
  static String policyIdFor(ProviderInstance instance, {String? modelId}) {
    final template = resolveTemplate(instance);
    final apiMode = apiModeFor(instance, template);

    // Exact evidenced model knowledge takes precedence on compatible API modes (model-only contract).
    if (modelId != null && apiMode == 'chat_completions') {
      if (KimiThinkingPolicy.isEvidencedModel(modelId)) {
        return KimiThinkingPolicy.policyIdentifier;
      }
    }

    final templatePolicyId = template.effectiveThinkingPolicyId;
    if (!instance.isCustom && templatePolicyId != unknownPolicyId) {
      return templatePolicyId;
    }

    return unknownPolicyId;
  }

  /// Resolves the effective provider template for thinking policy lookup.
  static ProviderProfile resolveTemplate(ProviderInstance instance) {
    return instance.template ?? _unknownTemplate(instance);
  }

  /// Effective wire api mode for thinking policy context.
  static String apiModeFor(
    ProviderInstance instance,
    ProviderProfile template,
  ) {
    if (instance.isCustom) {
      return instance.protocol == ProviderProtocol.anthropicCompatible
          ? 'anthropic_messages'
          : 'chat_completions';
    }
    return template.apiMode;
  }

  static ProviderProfile _unknownTemplate(ProviderInstance instance) {
    return ProviderProfile(
      name: instance.templateId,
      protocol: instance.protocol,
      thinkingPolicyId: unknownPolicyId,
    );
  }

  /// Validates declared wire against route protocol and apiMode.
  static bool isWireCompatible({
    required String wire,
    required String protocol,
    required String apiMode,
  }) {
    final p = protocol.trim().toLowerCase();
    final m = apiMode.trim().toLowerCase();
    switch (wire) {
      case 'openai_chat_effort':
      case 'toggle_effort':
        final isOpenAi =
            p == ProviderProtocol.openaiCompatible.toLowerCase() ||
            p == 'openai' ||
            p == 'openai_compatible';
        final isChat = m == 'chat_completions' || m == 'chat';
        return isOpenAi && isChat;
      case 'codex_responses_effort':
        final isOpenAi =
            p == ProviderProtocol.openaiCompatible.toLowerCase() ||
            p == 'openai' ||
            p == 'openai_compatible' ||
            p == 'openai-codex' ||
            p == 'codex';
        final isResponses = m == 'responses' || m == 'codex_responses';
        return isOpenAi && isResponses;
      case 'anthropic_adaptive':
      case 'anthropic_budget':
        final isAnthropic =
            p == ProviderProtocol.anthropicCompatible.toLowerCase() ||
            p == 'anthropic' ||
            p == 'anthropic_compatible';
        final isMessages = m == 'anthropic_messages' || m == 'messages';
        return isAnthropic && isMessages;
      case 'google_thinking':
        final isOpenAi =
            p == ProviderProtocol.openaiCompatible.toLowerCase() ||
            p == 'openai' ||
            p == 'openai_compatible';
        final isChat = m == 'chat_completions' || m == 'chat';
        return m == 'google_thinking' ||
            p == 'google_thinking' ||
            p == 'gemini' ||
            (isOpenAi && isChat);
      default:
        return false;
    }
  }
}
