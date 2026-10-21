/// Fail-closed thinking policy resolution for provider routes (Task 43 Gate A).
library;

import '../provider_runtime/provider_instance.dart';
import '../provider_runtime/provider_protocol_constants.dart';
import '../../engine/adapters/provider_profile.dart';
import 'thinking_wire_dialect.dart';

class ThinkingRoutePolicy {
  ThinkingRoutePolicy._();

  static const unknownPolicyId = 'unknown';

  /// Resolves the thinking policy id for [instance].
  ///
  /// The id is a property of the route (template and actual API mode), never of
  /// the model name: it labels the request wire dialect and, for the
  /// provider-reported policies, the item schema that may carry capability.
  /// [modelId] is accepted for call-site compatibility and is not consulted.
  static String policyIdFor(ProviderInstance instance, {String? modelId}) {
    final template = resolveTemplate(instance);
    if (instance.isCustom) {
      return switch (apiModeFor(instance, template)) {
        'anthropic_messages' => 'anthropic_thinking',
        _ => 'openai_chat_effort',
      };
    }
    final templatePolicyId = template.effectiveThinkingPolicyId;
    return templatePolicyId.isEmpty ? unknownPolicyId : templatePolicyId;
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

  /// Classifies the actual wire dialect for [instance].
  static ThinkingWireDialect wireDialectFor(ProviderInstance instance) {
    final template = resolveTemplate(instance);
    return ThinkingWireDialectFacts.forTemplate(
      template.name,
      isCustom: instance.isCustom,
      apiMode: apiModeFor(instance, template),
    );
  }

  /// The documented OpenAI-compatible Chat predicate shared by every Chat wire.
  static bool _isOpenAiCompatibleChat(String protocol, String apiMode) {
    final p = protocol.trim().toLowerCase();
    final m = apiMode.trim().toLowerCase();
    final isOpenAi =
        p == ProviderProtocol.openaiCompatible.toLowerCase() ||
        p == 'openai' ||
        p == 'openai_compatible';
    final isChat = m == 'chat_completions' || m == 'chat';
    return isOpenAi && isChat;
  }

  static bool isWireCompatible({
    required String wire,
    required String protocol,
    required String apiMode,
    String? templateId,
    bool isCustom = false,
  }) {
    final p = protocol.trim().toLowerCase();
    final m = apiMode.trim().toLowerCase();
    // The aggregator owns one nested `reasoning` envelope that carries every
    // typed effort, level, budget and disable directive, so any typed wire
    // except the template-kwargs serializers is admissible there.
    final isAggregatorChat =
        !isCustom &&
        ThinkingWireDialectFacts.aggregatorTemplateIds.contains(
          (templateId ?? '').trim(),
        ) &&
        _isOpenAiCompatibleChat(protocol, apiMode);
    if (isAggregatorChat &&
        wire != 'nim_kimi_thinking' &&
        wire != 'nim_qwen_thinking') {
      return const {
        'openai_chat_effort',
        'codex_responses_effort',
        'toggle_effort',
        'native_toggle_effort',
        'anthropic_adaptive',
        'anthropic_budget',
        'google_thinking',
      }.contains(wire);
    }
    switch (wire) {
      case 'native_toggle_effort':
        // The native `thinking.type` envelope is evidenced only on first-party
        // and verified partner Chat dialects.
        if (!_isOpenAiCompatibleChat(protocol, apiMode)) return false;
        return ThinkingWireDialectFacts.forTemplate(
          templateId ?? '',
          isCustom: isCustom,
          apiMode: apiMode,
        ).allowsFirstPartyNativeEnvelope;
      case 'nim_kimi_thinking':
      case 'nim_qwen_thinking':
        // These wires are serialized by the template-kwargs codec, which the
        // adapter selects only for the generic Chat codec and the hosted NIM
        // catalog. Compatibility therefore requires the normalized
        // OpenAI-compatible Chat protocol *and* an eligible serializer dialect:
        // an Anthropic or native-Ollama protocol never qualifies merely because
        // its configured API-mode string says chat, and an aggregator
        // envelope, Responses body or Messages body cannot carry them either.
        if (!_isOpenAiCompatibleChat(protocol, apiMode)) {
          return false;
        }
        final dialect = ThinkingWireDialectFacts.forTemplate(
          templateId ?? '',
          isCustom: isCustom,
          apiMode: apiMode,
        );
        return dialect == ThinkingWireDialect.nimChat ||
            dialect == ThinkingWireDialect.compatibleChat;
      case 'openai_chat_effort':
      case 'toggle_effort':
      case 'kimi_thinking':
      case 'deepseek_thinking':
      case 'zai_thinking':
      case 'nim_thinking':
        return _isOpenAiCompatibleChat(protocol, apiMode);
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
      case 'anthropic_thinking':
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
