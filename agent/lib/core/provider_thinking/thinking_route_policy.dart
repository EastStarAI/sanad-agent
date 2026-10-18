/// Fail-closed thinking policy resolution for provider routes (Task 43 Gate A).
library;

import '../provider_runtime/provider_instance.dart';
import '../provider_runtime/provider_protocol_constants.dart';
import '../../engine/adapters/provider_profile.dart';
import 'anthropic_model_catalog.dart';
import 'anthropic_thinking_policy.dart';
import 'codex_responses_effort_thinking_policy.dart';
import 'deepseek_model_catalog.dart';
import 'deepseek_thinking_policy.dart';
import 'gpt_oss_model_catalog.dart';
import 'compatible_chat_effort_facts.dart';
import 'thinking_wire_dialect.dart';
import 'kimi_thinking_policy.dart';
import 'nim_thinking_policy.dart';
import 'openai_chat_effort_thinking_policy.dart';
import 'openai_reasoning_models.dart';
import 'xai_model_catalog.dart';
import 'zai_model_catalog.dart';
import 'zai_thinking_policy.dart';

class ThinkingRoutePolicy {
  ThinkingRoutePolicy._();

  static const unknownPolicyId = 'unknown';

  /// Resolves the thinking policy id for [instance] and optional [modelId].
  ///
  /// Aggregators retain their dedicated upstream policy.
  /// Exact evidenced model knowledge takes precedence on compatible API modes
  /// across factory kinds, custom instances, and local routes (model-only contract).
  ///
  /// For custom instances or templates without a dedicated thinking policy
  /// (effectiveThinkingPolicyId == 'unknown'), exact evidenced model knowledge
  /// is resolved when the route's API mode is compatible.
  ///
  /// Chat Claude on chat_completions is preserved as NOT native Anthropic wire
  /// unless an explicit compatible declaration is configured.
  ///
  /// Unknown routes fail closed to [unknownPolicyId] per Plan 29 §3.10.
  static String policyIdFor(ProviderInstance instance, {String? modelId}) {
    final template = resolveTemplate(instance);
    final apiMode = apiModeFor(instance, template);

    // Dedicated upstream aggregators retain their aggregator policy so that
    // aggregator wire serialization is not bypassed.
    final templatePolicyId = template.effectiveThinkingPolicyId;
    if (!instance.isCustom && templatePolicyId == 'aggregator_upstream') {
      return 'aggregator_upstream';
    }

    // Exact evidenced model knowledge takes precedence on compatible API modes (model-only contract).
    if (modelId != null) {
      if (apiMode == 'chat_completions' || apiMode == 'chat') {
        final dialect = wireDialectFor(instance);
        // The hosted NIM catalog owns its own documented per-model contracts;
        // they are selected before any first-party extension can leak onto it.
        if (dialect == ThinkingWireDialect.nimChat &&
            NimThinkingPolicy.isEvidencedModel(modelId)) {
          return NimThinkingPolicy.policyIdentifier;
        }
        // First-party native envelopes only on evidenced native dialects.
        if (dialect.allowsFirstPartyNativeEnvelope) {
          if (KimiThinkingPolicy.isEvidencedModel(modelId)) {
            return KimiThinkingPolicy.policyIdentifier;
          }
          if (DeepSeekModelCatalog.isEvidencedModel(modelId)) {
            return DeepSeekThinkingPolicy.policyIdentifier;
          }
          if (ZaiModelCatalog.isEvidencedModel(modelId)) {
            return ZaiThinkingPolicy.policyIdentifier;
          }
        }
        // Documented standard-effort facts remain available on the compatible
        // wire, without the family's native envelope or disable.
        if (dialect == ThinkingWireDialect.compatibleChat &&
            CompatibleChatEffortFacts.isEvidencedModel(modelId)) {
          return OpenAiChatEffortThinkingPolicy.policyIdentifier;
        }
        if (OpenAiReasoningModels.isEvidencedModel(modelId)) {
          return OpenAiChatEffortThinkingPolicy.policyIdentifier;
        }
        // Exact xAI Grok facts use the documented Chat `reasoning_effort` field.
        if (XaiModelCatalog.supportsEffort(modelId)) {
          return OpenAiChatEffortThinkingPolicy.policyIdentifier;
        }
        // Exact `gpt-oss` facts are intrinsic model facts on the compatible
        // Chat reasoning-effort mode.
        if (GptOssModelCatalog.isGroundedModelId(modelId)) {
          return OpenAiChatEffortThinkingPolicy.policyIdentifier;
        }
      } else if (apiMode == 'anthropic_messages' || apiMode == 'messages') {
        if (AnthropicModelCatalog.isEvidencedModel(modelId)) {
          return AnthropicThinkingPolicy.policyIdentifier;
        }
      } else if (apiMode == 'codex_responses' || apiMode == 'responses') {
        if (OpenAiReasoningModels.isEvidencedModel(modelId)) {
          return CodexResponsesEffortThinkingPolicy.policyIdentifier;
        }
      }
    }

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
    switch (wire) {
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
