import 'anthropic_model_catalog.dart';
import 'deepseek_model_catalog.dart';
import 'google_model_catalog.dart';
import 'kimi_thinking_policy.dart';
import 'openai_reasoning_models.dart';
import 'zai_model_catalog.dart';

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
  static String upstreamPolicyIdForModel(String modelId) {
    final prefix = vendorPrefix(modelId);
    if (prefix != null) {
      return switch (prefix) {
        'anthropic' => 'anthropic_thinking',
        'google' => 'google_thinking',
        'deepseek' || 'deepseek-ai' => 'deepseek_thinking',
        'moonshotai' => 'kimi_thinking',
        'z-ai' || 'zai' => 'zai_thinking',
        'openai' ||
        'qwen' ||
        'meta-llama' ||
        'mistralai' ||
        'cohere' ||
        'nvidia' ||
        'minimax' ||
        'nex-agi' => 'openai_chat_effort',
        _ => 'openai_chat_effort',
      };
    }

    if (AnthropicModelCatalog.isEvidencedModel(modelId)) {
      return 'anthropic_thinking';
    }
    if (DeepSeekModelCatalog.isEvidencedModel(modelId)) {
      return 'deepseek_thinking';
    }
    if (GoogleModelCatalog.isEvidencedModel(modelId)) {
      return 'google_thinking';
    }
    if (KimiThinkingPolicy.isEvidencedModel(modelId)) {
      return 'kimi_thinking';
    }
    if (ZaiModelCatalog.isEvidencedModel(modelId)) {
      return 'zai_thinking';
    }
    if (OpenAiReasoningModels.isEvidencedModel(modelId)) {
      return 'openai_chat_effort';
    }

    return 'openai_chat_effort';
  }
}
