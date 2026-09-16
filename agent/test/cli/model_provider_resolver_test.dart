import 'package:sanad_agent/cli/models/model_provider_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();
  group('ModelProviderResolver', () {
    late ProviderInstanceRepository repo;

    final defaultProvider = ProviderInstance(
      id: 'prov-opencode-1',
      templateId: 'opencode-go',
      displayName: 'OpenCode Go',
      protocol: 'openai',
      authMethod: 'api_key',
      defaultModel: 'deepseek-v4-flash',
      status: 'active',
      isDefault: true,
      configRevision: 1,
      credentialRevision: 1,
      requestsPerMinute: 60,
      allowAutoFailover: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final chatGptProvider = ProviderInstance(
      id: 'prov-chatgpt-2',
      templateId: 'openai-codex',
      displayName: 'ChatGPT',
      protocol: 'openai',
      authMethod: 'oauth',
      defaultModel: 'gpt-5.6-sol',
      status: 'active',
      isDefault: false,
      configRevision: 1,
      credentialRevision: 1,
      requestsPerMinute: 60,
      allowAutoFailover: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    setUp(() {
      repo = ProviderInstanceRepository.inMemory();
      repo.createInstance(defaultProvider);
      repo.createInstance(chatGptProvider);

      // Populate model cache
      repo.upsertModelCache(
        instanceId: defaultProvider.id,
        cacheKey: 'models',
        models: [
          {'value': 'deepseek-v4-flash', 'label': 'DeepSeek Flash'},
          {'value': 'deepseek-r1', 'label': 'DeepSeek R1'},
        ],
        fetchedAt: DateTime.now(),
        source: 'test',
        configRevision: 1,
        credentialRevision: 1,
      );

      repo.upsertModelCache(
        instanceId: chatGptProvider.id,
        cacheKey: 'models',
        models: [
          {'value': 'gpt-5.6-sol', 'label': 'GPT 5.6 Sol'},
          {'value': 'gpt-5.4', 'label': 'GPT 5.4 Standard'},
          {'value': 'gpt-4o', 'label': 'GPT 4o'},
        ],
        fetchedAt: DateTime.now(),
        source: 'test',
        configRevision: 1,
        credentialRevision: 1,
      );
    });

    test(
      'resolves default provider and default model when no flags are given',
      () {
        final resolver = ModelProviderResolver(repositoryOverride: repo);
        final res = resolver.resolve();

        expect(res.isSuccess, isTrue);
        expect(res.resolved!.providerId, equals('prov-opencode-1'));
        expect(res.resolved!.providerName, equals('OpenCode Go'));
        expect(res.resolved!.modelName, equals('deepseek-v4-flash'));
      },
    );

    test('resolves provider by human-friendly name (case-insensitive)', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(requestedProvider: 'chatgpt');

      expect(res.isSuccess, isTrue);
      expect(res.resolved!.providerId, equals('prov-chatgpt-2'));
      expect(res.resolved!.providerName, equals('ChatGPT'));
      expect(res.resolved!.modelName, equals('gpt-5.6-sol'));
    });

    test('resolves provider by templateId', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(requestedProvider: 'openai-codex');

      expect(res.isSuccess, isTrue);
      expect(res.resolved!.providerId, equals('prov-chatgpt-2'));
      expect(res.resolved!.modelName, equals('gpt-5.6-sol'));
    });

    test('resolves provider by UUID', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(requestedProvider: 'prov-chatgpt-2');

      expect(res.isSuccess, isTrue);
      expect(res.resolved!.providerId, equals('prov-chatgpt-2'));
    });

    test('resolves model when available on default provider', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(requestedModel: 'deepseek-r1');

      expect(res.isSuccess, isTrue);
      expect(res.resolved!.providerId, equals('prov-opencode-1'));
      expect(res.resolved!.modelName, equals('deepseek-r1'));
    });

    test('resolves model when explicitly pairing provider and valid model', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(
        requestedProvider: 'ChatGPT',
        requestedModel: 'gpt-5.4',
      );

      expect(res.isSuccess, isTrue);
      expect(res.resolved!.providerId, equals('prov-chatgpt-2'));
      expect(res.resolved!.modelName, equals('gpt-5.4'));
    });

    test(
      'rejects model not on default provider and hints at provider where it exists',
      () {
        final resolver = ModelProviderResolver(repositoryOverride: repo);
        final res = resolver.resolve(requestedModel: 'gpt-5.4');

        expect(res.isSuccess, isFalse);
        expect(
          res.errorMessage,
          contains(
            'Model "gpt-5.4" is not available under provider "OpenCode Go"',
          ),
        );
        expect(
          res.hintMessage,
          contains('--provider "ChatGPT" --model "gpt-5.4"'),
        );
      },
    );

    test('rejects model not found in any provider with models listing hint', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(requestedModel: 'claude-non-existent');

      expect(res.isSuccess, isFalse);
      expect(
        res.errorMessage,
        contains(
          'Model "claude-non-existent" was not found in any configured provider',
        ),
      );
      expect(res.hintMessage, contains('Run "sanad models"'));
    });

    test('rejects unknown provider name with list of configured providers', () {
      final resolver = ModelProviderResolver(repositoryOverride: repo);
      final res = resolver.resolve(requestedProvider: 'Anthropic');

      expect(res.isSuccess, isFalse);
      expect(res.errorMessage, contains('Provider "Anthropic" not found'));
      expect(res.hintMessage, contains('"OpenCode Go"'));
      expect(res.hintMessage, contains('"ChatGPT"'));
    });
  });
}
