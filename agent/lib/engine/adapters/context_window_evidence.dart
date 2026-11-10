import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/model_metadata.dart';
import 'package:sanad_agent/core/provider_runtime/local_provider_routes.dart';

import 'provider_profile.dart';

/// Provider evidence for an adapter's context window.
///
/// Adapters own only what the provider itself reports. User overrides, shipped
/// defaults and the global cap belong to [Config.resolveContextWindow], so every
/// adapter family shares this plumbing instead of re-deriving the boundary.
abstract final class ContextWindowEvidence {
  const ContextWindowEvidence._();

  /// Provider catalog evidence (models.dev, live model discovery).
  static ProviderContextWindow? catalog(int? tokens) => _positive(
    tokens,
    ContextWindowSource.providerCatalog,
  );

  /// Provider metadata evidence (local probes, model metadata tables).
  static ProviderContextWindow? metadata(int? tokens) => _positive(
    tokens,
    ContextWindowSource.providerMetadata,
  );

  /// Known static metadata for [modelId] as provider evidence.
  static ProviderContextWindow? knownMetadata(String modelId) =>
      metadata(ModelMetadata.getLimitForModel(modelId));

  /// Whether this route serves a model the user runs locally.
  static bool isLocalRoute(ProviderProfile profile, String baseUrl) =>
      LocalProviderRoutes.isLocalRoute(
        templateId: profile.name,
        baseUrl: baseUrl,
      );

  /// The effective window for [modelId]: [evidence] when known, otherwise the
  /// policy's local or unknown fallback, never above the global cap.
  static int resolve({
    required Config config,
    required String modelId,
    required ProviderProfile profile,
    required String baseUrl,
    required int unknownCloudFallback,
    ProviderContextWindow? evidence,
  }) => config
      .resolveContextWindow(
        modelId: modelId,
        providerEvidence: evidence,
        localProvider: isLocalRoute(profile, baseUrl),
        unknownCloudFallback: unknownCloudFallback,
      )
      .tokens;

  static ProviderContextWindow? _positive(
    int? tokens,
    ContextWindowSource source,
  ) => tokens != null && tokens > 0
      ? ProviderContextWindow(tokens: tokens, source: source)
      : null;
}
