class ModelMetadata {
  /// Fail-closed limit used only when configuration, the provider catalog,
  /// provider metadata, and known model metadata cannot resolve a model.
  static const int unknownContextLimit = 4000;

  static const Map<String, int> defaultContextLimits = {
    // OpenAI
    'gpt-6-astra': 1050000,
    'gpt-6-sol': 1050000,
    'gpt-6-luna': 1050000,
    'gpt-5.6': 1050000,
    'gpt-5.5': 1050000,
    'gpt-5.4': 1050000,
    'gpt-5': 400000,
    'gpt-4.1': 1047576,
    'gpt-4o': 128000,
    'gpt-4-turbo': 128000,
    'gpt-4': 128000,
    'gpt-3.5-turbo': 16385,

    // Claude
    'claude-opus-4.7': 1000000,
    'claude-sonnet-4.6': 1000000,
    'claude-3-5-sonnet': 200000,
    'claude-3-opus': 200000,
    'claude-3-sonnet': 200000,
    'claude-3-haiku': 200000,
    'claude': 200000,

    // Gemini
    'gemini': 1048576,

    // Gemma
    'gemma-4': 256000,
    'gemma4': 256000,
    'gemma-3': 131072,
    'gemma3': 131072,
    'gemma-2': 8192,
    'gemma2': 8192,
    'gemma': 8192,

    // DeepSeek
    'deepseek-v4-pro': 1000000,
    'deepseek-v4-flash': 1000000,
    'deepseek-v3': 128000,
    'deepseek-chat': 1000000,
    'deepseek-reasoner': 1000000,
    'deepseek': 128000,

    // Llama
    'llama-3': 131072,
    'llama3': 131072,
    'llama-2': 4096,
    'llama2': 4096,
    'llama': 131072,

    // Qwen
    'qwen3.6-plus': 1048576,
    'qwen3-coder-plus': 1000000,
    'qwen3-coder': 262144,
    'qwen3': 131072,
    'qwen-3': 131072,
    'qwen2.5': 131072,
    'qwen2': 131072,
    'qwen': 131072,

    // Mistral
    'mistral': 32768,
    'mixtral': 32768,

    // MiniMax
    'minimax': 204800,

    // GLM
    'glm': 202752,

    // Grok
    'grok-4-fast': 2000000,
    'grok-4.20': 2000000,
    'grok-4.3': 1000000,
    'grok-4': 256000,
    'grok-3': 131072,
    'grok-2': 131072,
    'grok': 131072,

    // Kimi
    'kimi': 262144,

    // Nemotron
    'nemotron': 131072,
  };

  static int? getLimitForModel(String modelName) {
    final lowerName = modelName.toLowerCase();

    // 1. Try exact match first
    if (defaultContextLimits.containsKey(lowerName)) {
      return defaultContextLimits[lowerName];
    }

    // 2. Normalized alphanumeric substring match sorted by normalized length descending.
    // This ensures specific models (e.g. "gemma-4", "gemma4", length 6) always match
    // before broad prefixes (e.g. "gemma", length 5), regardless of whether the input
    // uses hyphens, underscores, dots, or colons.
    final normalizedModel = lowerName.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final sortedKeys = defaultContextLimits.keys.toList()
      ..sort((a, b) {
        final normA = a.replaceAll(RegExp(r'[^a-z0-9]'), '');
        final normB = b.replaceAll(RegExp(r'[^a-z0-9]'), '');
        final cmp = normB.length.compareTo(normA.length);
        if (cmp != 0) return cmp;
        return b.length.compareTo(a.length);
      });

    for (final key in sortedKeys) {
      final normKey = key.replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (normKey.isNotEmpty && normalizedModel.contains(normKey)) {
        return defaultContextLimits[key];
      }
      if (lowerName.contains(key)) {
        return defaultContextLimits[key];
      }
    }

    return null;
  }
}
