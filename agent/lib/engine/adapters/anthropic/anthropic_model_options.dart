import '../../../core/config.dart';
import '../../../core/models/model_metadata.dart';
import '../../../core/provider_runtime/provider_model_id.dart';
import '../../../interfaces/platforms/sanad_gateway/capabilities.dart';
import '../context_window_evidence.dart';
import '../llm_adapter.dart';
import '../provider_profile.dart';

/// One Anthropic-compatible route and the policy inputs its model list needs.
class AnthropicModelRoute {
  const AnthropicModelRoute({
    required this.config,
    required this.profile,
    required this.baseUrl,
    this.catalog,
  });

  final Config config;
  final ProviderProfile profile;
  final String baseUrl;

  /// Provider catalog lookup (models.dev or an injected test catalog).
  final ModelContextLimitLookup? catalog;

  /// The conservative pre-cap fallback this adapter family has always used when
  /// the cap is disabled and nothing is known about an Anthropic model.
  static const int unknownContextFallback = 200000;

  String normalize(String rawModelId) => ProviderModelId.normalize(
    templateId: profile.name,
    protocol: profile.effectiveProtocol,
    rawModelId: rawModelId,
  );

  /// The effective window for [modelId] under the installed policy.
  int effectiveWindow(String modelId) => ContextWindowEvidence.resolve(
    config: config,
    modelId: modelId,
    evidence:
        ContextWindowEvidence.catalog(catalog?.call(modelId)) ??
        ContextWindowEvidence.knownMetadata(modelId),
    profile: profile,
    baseUrl: baseUrl,
    unknownCloudFallback: unknownContextFallback,
  );

  /// A catalog option carrying the one effective window its readers will see.
  ModelOption option({
    required String modelId,
    required String label,
    Map<String, Object?> metadata = const {},
  }) => ModelOption(
    value: modelId,
    label: label,
    provider: 'anthropic',
    contextWindow: effectiveWindow(modelId),
    contextWindowRaw: ModelMetadata.getLimitForModel(modelId),
    supportsReasoning: false,
    modelMetadata: metadata,
  );
}

/// Anthropic model-list construction, kept beside the adapter it serves.
abstract final class AnthropicModelOptions {
  const AnthropicModelOptions._();

  /// Options for the packaged fallback ids, in their configured order.
  static List<ModelOption> fallback(
    List<String> rawModelIds,
    AnthropicModelRoute route,
  ) => [
    for (final rawModelId in rawModelIds)
      route.option(
        modelId: route.normalize(rawModelId),
        label: formatLabel(rawModelId),
      ),
  ];

  /// Options for the `/v1/models` payload entries.
  static List<ModelOption> fromLiveEntries(
    Iterable<Map> entries,
    AnthropicModelRoute route,
  ) {
    ModelOption? toOption(Map entry) {
      final modelId = route.normalize(entry['id']?.toString() ?? '');
      if (modelId.isEmpty) return null;
      return route.option(
        modelId: modelId,
        label: formatLabel(modelId),
        metadata: Map<String, Object?>.from(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      );
    }

    return entries
        .map(toOption)
        .whereType<ModelOption>()
        .toList(growable: false);
  }

  /// `claude-3-5-sonnet-latest` renders as `Claude 3 5 Sonnet Latest`.
  static String formatLabel(String name) {
    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';
    return name.split('-').map(capitalize).join(' ');
  }
}
