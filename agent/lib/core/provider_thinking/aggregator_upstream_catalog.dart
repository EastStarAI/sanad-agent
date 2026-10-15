/// Upstream vendor resolution for aggregator model ids (Task 43 Gate G).
library;

class AggregatorUpstreamCatalog {
  AggregatorUpstreamCatalog._();

  static String? vendorPrefix(String modelId) {
    final trimmed = modelId.trim();
    if (!trimmed.contains('/')) {
      return null;
    }
    return trimmed.split('/').first.toLowerCase();
  }

  /// Resolves the upstream thinking policy id for an aggregator model id.
  ///
  /// Unprefixed ids fall back to OpenAI-compatible effort heuristics because
  /// many aggregator catalogs expose bare model names.
  static String upstreamPolicyIdForModel(String modelId) {
    return switch (vendorPrefix(modelId)) {
      'anthropic' => 'anthropic_thinking',
      'google' => 'google_thinking',
      'deepseek' => 'deepseek_thinking',
      'openai' ||
      'qwen' ||
      'meta-llama' ||
      'mistralai' ||
      'cohere' ||
      'nvidia' ||
      'minimax' ||
      'nex-agi' ||
      'z-ai' => 'openai_chat_effort',
      // Kimi/Moonshot stays fail-closed until a dedicated XOR policy+fixture.
      'moonshotai' => 'unknown',
      _ => 'openai_chat_effort',
    };
  }
}
