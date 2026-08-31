import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';

/// Builds the catalog of supported LLM providers from `ProviderRegistry`.
///
/// This is the single source of truth for which providers exist, their display
/// metadata, and their auth flow. Both the CLI setup wizard and the Flutter
/// onboarding/settings UI consume this catalog so neither hardcodes a provider
/// list.
class ProviderCatalogService {
  static const _hiddenUntilImplemented = {'xai-oauth'};

  List<ProviderProfile> get allProfiles =>
      List<ProviderProfile>.from(ProviderRegistry.profiles);

  /// Profiles safe to expose in user-facing setup surfaces right now.
  /// Templates with unimplemented auth/runtime flows stay in the registry for
  /// internal compatibility, but must not be presented by CLI or client.
  List<ProviderProfile> get visibleProfiles =>
      allProfiles.where(isVisible).toList(growable: false);

  ProviderProfile? findById(String id) =>
      ProviderRegistry.findByNameOrAlias(id);

  bool isVisible(ProviderProfile profile) {
    // Hide account-auth templates whose runtime flow is not implemented yet.
    return !_hiddenUntilImplemented.contains(profile.name);
  }

  /// Returns transport-safe public maps for every supported provider.
  /// Secrets are never included.
  List<Map<String, dynamic>> catalogMaps() =>
      visibleProfiles.map((p) => p.toPublicMap()).toList();

  /// Groups providers by auth flow for UI rendering (e.g. "API Key" vs
  /// "Sign in with browser"). The grouping is a presentation hint only and
  /// must not become a second source of truth.
  Map<String, List<ProviderProfile>> groupedByFlow() {
    final groups = <String, List<ProviderProfile>>{};
    for (final profile in visibleProfiles) {
      final flow = profile.effectiveAuthFlow;
      groups.putIfAbsent(flow, () => []).add(profile);
    }
    return groups;
  }
}
