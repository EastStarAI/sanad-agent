import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/utils/provider_search_filter.dart';

ProviderDto _provider({
  required String id,
  required String displayName,
  List<String> aliases = const [],
}) => ProviderDto(
  id: id,
  name: id,
  displayName: displayName,
  description: '',
  authType: 'api_key',
  authFlow: 'api_key',
  apiMode: 'chat_completions',
  supportsModelFetch: false,
  disconnectable: true,
  fallbackModels: const [],
  aliases: aliases,
  configured: false,
  authenticated: false,
  isCurrent: false,
  models: const [],
  authStatus: 'missing',
);

List<String> _ids(List<ProviderDto> providers) => providers.map((p) => p.id).toList();

void main() {
  final openAi = _provider(id: 'openai', displayName: 'OpenAI', aliases: const ['gpt', 'chatgpt']);
  final anthropic = _provider(id: 'anthropic', displayName: 'Anthropic', aliases: const ['claude']);
  final local = _provider(id: 'ollama-local', displayName: 'Local Ollama');

  List<ProviderDto> catalog() => [openAi, anthropic, local];

  group('ProviderSearchFilter.apply', () {
    test('returns the full catalog unchanged for an empty query', () {
      final providers = catalog();
      final result = ProviderSearchFilter.apply(providers, '');

      expect(_ids(result), ['openai', 'anthropic', 'ollama-local']);
      expect(identical(result, providers), isTrue, reason: 'empty queries must not copy or rebuild the catalog');
    });

    test('treats a whitespace-only query as empty', () {
      expect(_ids(ProviderSearchFilter.apply(catalog(), '   ')), ['openai', 'anthropic', 'ollama-local']);
      expect(ProviderSearchFilter.apply(catalog(), '\t\n '), hasLength(3));
    });

    test('matches the display name', () {
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'Anthropic')), ['anthropic']);
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'ollama')), ['ollama-local']);
    });

    test('matches the template id', () {
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'ollama-local')), ['ollama-local']);
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'local')), ['ollama-local']);
    });

    test('matches any template alias', () {
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'claude')), ['anthropic']);
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'gpt')), ['openai']);
    });

    test('is case-insensitive and trims the query', () {
      expect(_ids(ProviderSearchFilter.apply(catalog(), '  oPeNaI  ')), ['openai']);
      expect(_ids(ProviderSearchFilter.apply(catalog(), 'CLAUDE')), ['anthropic']);
    });

    test('preserves the original catalog order', () {
      final providers = [
        _provider(id: 'zeta', displayName: 'Zeta Cloud', aliases: const ['llm']),
        _provider(id: 'alpha', displayName: 'Alpha Cloud', aliases: const ['llm']),
        _provider(id: 'mike', displayName: 'Mike Cloud', aliases: const ['llm']),
      ];

      expect(_ids(ProviderSearchFilter.apply(providers, 'cloud')), ['zeta', 'alpha', 'mike']);
    });

    test('returns an empty list when nothing matches', () {
      expect(ProviderSearchFilter.apply(catalog(), 'does-not-exist'), isEmpty);
    });

    test('matches Arabic queries and does not throw', () {
      final arabic = _provider(id: 'arabic-vendor', displayName: 'Arabic Vendor', aliases: const ['مزوّد']);
      final providers = [openAi, arabic];

      expect(_ids(ProviderSearchFilter.apply(providers, 'مزوّد')), ['arabic-vendor']);
      expect(_ids(ProviderSearchFilter.apply(providers, '  مزوّد  ')), ['arabic-vendor']);
      expect(ProviderSearchFilter.apply(providers, 'غير موجود'), isEmpty);
    });

    test('never mutates the source catalog', () {
      final providers = catalog();
      ProviderSearchFilter.apply(providers, 'openai');

      expect(_ids(providers), ['openai', 'anthropic', 'ollama-local']);
    });
  });

  group('ProviderSearchFilter.matches', () {
    test('treats a blank query as matching everything', () {
      expect(ProviderSearchFilter.matches(openAi, ''), isTrue);
      expect(ProviderSearchFilter.matches(openAi, '   '), isTrue);
    });

    test('reports a miss for unrelated text', () {
      expect(ProviderSearchFilter.matches(openAi, 'anthropic'), isFalse);
    });

    test('ignores providers with no aliases', () {
      expect(ProviderSearchFilter.matches(local, 'ollama'), isTrue);
      expect(ProviderSearchFilter.matches(local, 'claude'), isFalse);
    });
  });
}
