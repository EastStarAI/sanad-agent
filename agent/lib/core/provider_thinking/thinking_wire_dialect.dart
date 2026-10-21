/// The actual wire dialect an agent route speaks.
///
/// This is a *transport* property, not intrinsic model knowledge: it decides
/// which serialization dialect may carry a control, while model identity keeps
/// owning which controls exist. A first-party native envelope (for example
/// DeepSeek/Kimi/ZAI `thinking.type`) is never inferred for an arbitrary
/// generic, local or custom Chat route merely because the model id matches.
library;

/// The actual wire dialect an agent route speaks.
enum ThinkingWireDialect {
  /// The provider's own documented native envelope (first-party templates).
  nativeFirstParty,

  /// A documented first-party-compatible partner Chat route.
  nativePartner,

  /// The NVIDIA NIM Chat catalog with its own documented per-model contracts.
  nimChat,

  /// Generic compatible Chat: documented standard `reasoning_effort` facts
  /// only, with no native envelope and no invented disable.
  compatibleChat,

  /// Non-Chat dialects (Anthropic Messages, Responses, aggregator envelope,
  /// Google, native Ollama) whose owners are unchanged.
  other;

  /// Whether this dialect may carry a first-party native thinking envelope.
  bool get allowsFirstPartyNativeEnvelope =>
      this == ThinkingWireDialect.nativeFirstParty ||
      this == ThinkingWireDialect.nativePartner;
}

/// Registered-route classification for [ThinkingWireDialect].
///
/// The template ids below describe *transport* dialects that ship with the
/// product (first-party APIs, the documented partner Chat route and the hosted
/// NVIDIA NIM catalog). They never gate intrinsic model knowledge: model facts
/// stay model-only, and only the native *wire extension* is dialect-gated.
class ThinkingWireDialectFacts {
  ThinkingWireDialectFacts._();

  /// Templates whose own API documents the native extension envelope.
  static const nativeFirstPartyTemplateIds = {
    'deepseek',
    'kimi',
    'zai',
    'zai-coding',
  };

  /// Templates documented as first-party-compatible Chat partners.
  static const nativePartnerTemplateIds = {'opencode-go'};

  /// The one template that ships the hosted NVIDIA NIM catalog.
  static const nimChatTemplateId = 'nvidia';

  /// Templates whose route owns its own nested envelope serializer instead of
  /// the generic Chat codec (the aggregator).
  static const aggregatorTemplateIds = {'openrouter'};

  static ThinkingWireDialect forTemplate(
    String templateId, {
    bool isCustom = false,
    String? apiMode,
  }) {
    final mode = apiMode?.trim().toLowerCase();
    if (mode != null && mode != 'chat_completions' && mode != 'chat') {
      return ThinkingWireDialect.other;
    }
    if (isCustom) {
      return ThinkingWireDialect.compatibleChat;
    }
    final template = templateId.trim();
    if (nativeFirstPartyTemplateIds.contains(template)) {
      return ThinkingWireDialect.nativeFirstParty;
    }
    if (nativePartnerTemplateIds.contains(template)) {
      return ThinkingWireDialect.nativePartner;
    }
    if (template == nimChatTemplateId) {
      return ThinkingWireDialect.nimChat;
    }
    if (aggregatorTemplateIds.contains(template)) {
      return ThinkingWireDialect.other;
    }
    return ThinkingWireDialect.compatibleChat;
  }
}
