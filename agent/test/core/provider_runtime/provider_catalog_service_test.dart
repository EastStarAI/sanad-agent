import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:test/test.dart';

/// Pins the presentation order of provider setup surfaces.
///
/// `ProviderCatalogService` is the single source of truth for the provider list
/// the CLI setup wizard and the Client onboarding/settings pickers render, and
/// it preserves `ProviderRegistry.profiles` declaration order. OpenCode Go is
/// declared first on purpose (owner request); every other provider keeps its
/// previous relative order.
void main() {
  final catalog = ProviderCatalogService();

  // Registry order before OpenCode Go was promoted to first place. Only the
  // opencode-go entry moved; this tail must stay stable.
  const expectedOrder = [
    'opencode-go',
    'openai-codex',
    'kimi',
    'anthropic',
    'nvidia',
    'openai',
    'openrouter',
    'gemini',
    'deepseek',
    'ollama',
    'lm-studio',
    'llama-cpp',
    'xai',
    'zai',
    'zai-coding',
    kCustomProviderTemplateId,
  ];

  test('visible setup profiles start with opencode-go', () {
    final visible = catalog.visibleProfiles;

    expect(visible, isNotEmpty);
    expect(visible.first.name, 'opencode-go');
    expect(visible.first.displayName, 'OpenCode Go');
  });

  test('visible setup profiles keep every other provider in order', () {
    expect(
      catalog.visibleProfiles.map((profile) => profile.name).toList(),
      expectedOrder,
    );
  });

  test('catalog payload keeps the setup order for the client picker', () {
    final maps = catalog.catalogMaps();

    expect(maps.first['name'], 'opencode-go');
    expect(maps.map((raw) => raw['name']).toList(), expectedOrder);
    expect(
      maps.any((raw) => raw['name'] == 'xai-oauth'),
      isFalse,
      reason: 'templates without a runtime auth flow stay hidden',
    );
  });

  test('grouping by auth flow cannot place another group above opencode-go', () {
    final groups = catalog.groupedByFlow();

    // Grouping only buckets the ordered list, so the promoted template owns the
    // first bucket and no other flow group can be rendered above it.
    expect(groups.keys.first, ProviderAuthMethod.apiKey);
    expect(groups[ProviderAuthMethod.apiKey]!.first.name, 'opencode-go');
  });

  test('custom template stays last so it never leads the setup list', () {
    expect(catalog.visibleProfiles.last.name, kCustomProviderTemplateId);
  });
}
