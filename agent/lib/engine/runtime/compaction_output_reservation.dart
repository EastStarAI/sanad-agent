/// Where the model's output reservation for the pre-send fit check of a
/// full compaction pass comes from (Task 118b). Settings
/// (`LLMRequestOptions.maxOutputTokens`) are applied by the engine first;
/// this resolves the next two capability layers.
abstract final class CompactionOutputReservation {
  CompactionOutputReservation._();

  static const providerMetadataSource = 'provider_metadata';
  static const modelsDevSource = 'models_dev';

  /// Output-limit keys in cached provider `/models` metadata, flat or under
  /// `top_provider`/`limit`. Provider-neutral wire field names, never model
  /// names.
  static const _metadataKeys = [
    'max_output_tokens',
    'max_completion_tokens',
    'output_token_limit',
    'max_tokens_output',
  ];

  /// The model's declared maximum output: provider metadata first, then the
  /// models.dev entry (`limit.output`). Returns `null` when neither declares
  /// one, so the engine applies its documented fallback.
  static (int, String)? resolve({
    Map<String, Object?>? providerModelMetadata,
    Map<String, dynamic>? modelsDevEntry,
  }) {
    final fromProvider = _fromMetadata(providerModelMetadata);
    if (fromProvider != null) return (fromProvider, providerMetadataSource);
    final limit = modelsDevEntry?['limit'];
    final output = limit is Map ? limit['output'] : null;
    if (output is num && output > 0) return (output.toInt(), modelsDevSource);
    return null;
  }

  static int? _fromMetadata(Map<dynamic, dynamic>? metadata) {
    if (metadata == null) return null;
    for (final key in _metadataKeys) {
      final value = metadata[key];
      if (value is num && value > 0) return value.toInt();
    }
    for (final nested in ['top_provider', 'limit']) {
      final inner = metadata[nested];
      if (inner is Map) {
        final value = _fromMetadata(inner);
        if (value != null) return value;
        final output = inner['output'];
        if (output is num && output > 0) return output.toInt();
      }
    }
    return null;
  }
}
