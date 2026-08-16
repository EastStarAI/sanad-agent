import '../core/models/agent_response.dart';
import '../core/models/llm_usage_snapshot.dart';

class MetricsTracker {
  String? activeModel;
  String? activeProvider;
  final DateTime runStartTime;

  final Map<String, int> accumulatedUsage = {
    'input': 0,
    'input_tokens': 0,
    'prompt_tokens': 0,
    'output': 0,
    'output_tokens': 0,
    'completion_tokens': 0,
    'total': 0,
    'total_tokens': 0,
  };

  /// Normalized values from the latest provider response only.
  ///
  /// This map is replaced for every response carrying usage. Missing values
  /// are not retained from an older invocation and totals are never inferred.
  final Map<String, int> lastUsage = {};

  MetricsTracker({DateTime? startTime})
    : runStartTime = startTime ?? DateTime.now();

  int get runtimeMs {
    final elapsed = DateTime.now().difference(runStartTime).inMilliseconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  void beginInvocation() => lastUsage.clear();

  void updateMetrics(AgentResponse response) {
    if (response.model != null) activeModel = response.model;
    if (response.provider != null) activeProvider = response.provider;
    final providerUsage = response.usage;
    if (providerUsage == null) return;

    final snapshot = LlmUsageSnapshot.fromProviderUsage(providerUsage);
    lastUsage
      ..clear()
      ..addAll(_expandedUsage(snapshot));

    _addAccumulated('input', snapshot.inputTokens);
    _addAccumulated('input_tokens', snapshot.inputTokens);
    _addAccumulated('prompt_tokens', snapshot.inputTokens);
    _addAccumulated('output', snapshot.outputTokens);
    _addAccumulated('output_tokens', snapshot.outputTokens);
    _addAccumulated('completion_tokens', snapshot.outputTokens);
    final accumulatedTotal =
        snapshot.totalTokens ??
        (snapshot.inputTokens != null || snapshot.outputTokens != null
            ? (snapshot.inputTokens ?? 0) + (snapshot.outputTokens ?? 0)
            : null);
    _addAccumulated('total', accumulatedTotal);
    _addAccumulated('total_tokens', accumulatedTotal);
    _addAccumulated('cache_read', snapshot.cachedTokens);
    _addAccumulated('cache_read_input_tokens', snapshot.cachedTokens);
    _addAccumulated('cached_tokens', snapshot.cachedTokens);
    _addAccumulated('cache_write', snapshot.cacheWriteTokens);
    _addAccumulated('cache_write_tokens', snapshot.cacheWriteTokens);
    _addAccumulated('cache_creation_input_tokens', snapshot.cacheWriteTokens);
    _addAccumulated('reasoning_tokens', snapshot.reasoningTokens);
  }

  Map<String, int> _expandedUsage(LlmUsageSnapshot snapshot) => {
    if (snapshot.inputTokens != null) ...{
      'input': snapshot.inputTokens!,
      'input_tokens': snapshot.inputTokens!,
      'prompt_tokens': snapshot.inputTokens!,
    },
    if (snapshot.outputTokens != null) ...{
      'output': snapshot.outputTokens!,
      'output_tokens': snapshot.outputTokens!,
      'completion_tokens': snapshot.outputTokens!,
    },
    if (snapshot.totalTokens != null) ...{
      'total': snapshot.totalTokens!,
      'total_tokens': snapshot.totalTokens!,
    },
    if (snapshot.cachedTokens != null) ...{
      'cache_read': snapshot.cachedTokens!,
      'cache_read_input_tokens': snapshot.cachedTokens!,
      'cached_tokens': snapshot.cachedTokens!,
    },
    if (snapshot.cacheWriteTokens != null) ...{
      'cache_write': snapshot.cacheWriteTokens!,
      'cache_write_tokens': snapshot.cacheWriteTokens!,
      'cache_creation_input_tokens': snapshot.cacheWriteTokens!,
    },
    if (snapshot.reasoningTokens != null)
      'reasoning_tokens': snapshot.reasoningTokens!,
  };

  void _addAccumulated(String key, int? value) {
    if (value == null) return;
    accumulatedUsage[key] = (accumulatedUsage[key] ?? 0) + value;
  }

  String? formatActiveModelDisplay() {
    if (activeModel == null) return null;
    final name = activeModel!;

    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';

    if (activeProvider == 'ollama') {
      final parts = name.split(':');
      final mainName = parts[0];
      final tag = parts.length > 1 ? parts[1] : '';
      final mainCapitalized = mainName.split('-').map(capitalize).join(' ');
      if (tag.isNotEmpty && tag != 'latest') {
        return '$mainCapitalized (${capitalize(tag)})';
      }
      return mainCapitalized;
    } else {
      final displaySource = name.contains('/') ? name.split('/').last : name;
      return displaySource
          .split('-')
          .map((part) {
            if (part.startsWith('gpt')) {
              return 'GPT${part.substring(3)}';
            }
            if (part.toLowerCase() == 'glm') {
              return 'GLM';
            }
            return capitalize(part);
          })
          .join(' ');
    }
  }
}
