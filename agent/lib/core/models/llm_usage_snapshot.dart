/// Provider-reported token usage for one LLM response.
///
/// Values are normalized to canonical names, but never inferred, summed, or
/// combined. A missing provider value remains absent.
class LlmUsageSnapshot {
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final int? cachedTokens;
  final int? cacheWriteTokens;
  final int? reasoningTokens;

  const LlmUsageSnapshot({
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.cachedTokens,
    this.cacheWriteTokens,
    this.reasoningTokens,
  });

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      totalTokens == null &&
      cachedTokens == null &&
      cacheWriteTokens == null &&
      reasoningTokens == null;

  factory LlmUsageSnapshot.fromProviderUsage(Map<String, dynamic> usage) {
    int? firstNumeric(Map<dynamic, dynamic> data, List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is num && value >= 0) return value.toInt();
      }
      return null;
    }

    int? nestedNumeric(String container, List<String> keys) {
      final value = usage[container];
      return value is Map ? firstNumeric(value, keys) : null;
    }

    return LlmUsageSnapshot(
      inputTokens: firstNumeric(usage, const [
        'input',
        'input_tokens',
        'inputTokens',
        'prompt_tokens',
        'promptTokens',
        'prompt_eval_count',
      ]),
      outputTokens: firstNumeric(usage, const [
        'output',
        'output_tokens',
        'outputTokens',
        'completion_tokens',
        'completionTokens',
        'eval_count',
      ]),
      totalTokens: firstNumeric(usage, const [
        'total',
        'total_tokens',
        'totalTokens',
      ]),
      cachedTokens:
          firstNumeric(usage, const [
            'cache_read',
            'cacheRead',
            'cache_read_input_tokens',
            'cacheReadInputTokens',
            'cached_tokens',
            'cached_input_tokens',
          ]) ??
          nestedNumeric('prompt_tokens_details', const [
            'cached_tokens',
            'cache_read',
            'cacheRead',
          ]) ??
          nestedNumeric('input_token_details', const [
            'cache_read',
            'cacheRead',
            'cached_tokens',
          ]) ??
          nestedNumeric('input_tokens_details', const [
            'cache_read',
            'cacheRead',
            'cached_tokens',
          ]),
      cacheWriteTokens:
          firstNumeric(usage, const [
            'cache_write',
            'cacheWrite',
            'cache_write_tokens',
            'cacheWriteTokens',
            'cache_creation_input_tokens',
          ]) ??
          nestedNumeric('prompt_tokens_details', const [
            'cache_write_tokens',
            'cache_creation_input_tokens',
          ]),
      reasoningTokens:
          firstNumeric(usage, const ['reasoning_tokens', 'reasoningTokens']) ??
          nestedNumeric('completion_tokens_details', const [
            'reasoning_tokens',
            'reasoningTokens',
          ]) ??
          nestedNumeric('output_token_details', const [
            'reasoning',
            'reasoning_tokens',
            'reasoningTokens',
          ]) ??
          nestedNumeric('output_tokens_details', const [
            'reasoning',
            'reasoning_tokens',
            'reasoningTokens',
          ]),
    );
  }

  Map<String, int> toUsageMap() => {
    'input_tokens': ?inputTokens,
    'output_tokens': ?outputTokens,
    'total_tokens': ?totalTokens,
    'cached_tokens': ?cachedTokens,
    'cache_write_tokens': ?cacheWriteTokens,
    'reasoning_tokens': ?reasoningTokens,
  };
}
