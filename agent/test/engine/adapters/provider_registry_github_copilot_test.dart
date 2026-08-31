import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

void main() {
  group('github-copilot ProviderRegistry template', () {
    final profile = ProviderRegistry.findByNameOrAlias('github-copilot');

    test('registers under github-copilot and copilot aliases', () {
      expect(profile, isNotNull);
      expect(profile!.name, equals(kGithubCopilotTemplateId));
      expect(
        ProviderRegistry.findByNameOrAlias('copilot')?.name,
        equals(kGithubCopilotTemplateId),
      );
      expect(
        ProviderRegistry.findByNameOrAlias('github-copilot')?.name,
        equals(kGithubCopilotTemplateId),
      );
    });

    test('advertises device-code OAuth over chat completions', () {
      expect(profile!.authType, equals('oauth_external'));
      expect(profile.authFlow, equals('device_code'));
      expect(profile.effectiveAuthFlow, equals('device_code'));
      expect(profile.apiMode, equals('chat_completions'));
      expect(
        profile.effectiveProtocol,
        equals(ProviderProtocol.openaiCompatible),
      );
      expect(profile.apiKeyRequirement, equals(ApiKeyRequirement.optional));
      expect(profile.authMethods, equals([ProviderAuthMethod.deviceCode]));
      expect(
        profile.effectiveAuthMethods,
        equals([ProviderAuthMethod.deviceCode]),
      );
      expect(profile.isOAuth, isTrue);
    });

    test('uses Copilot default endpoint, headers, and fallback models', () {
      expect(
        profile!.defaultBaseUrl,
        equals(GithubCopilotProtocol.defaultApiBaseUrl),
      );
      expect(profile.envApiKeyName, isNull);
      expect(profile.envModelName, equals('GITHUB_COPILOT_MODEL'));
      expect(profile.envBaseUrlName, equals('GITHUB_COPILOT_API_BASE'));
      expect(
        profile.defaultHeaders,
        equals(GithubCopilotProtocol.staticRequestHeaders),
      );
      expect(
        profile.fallbackModels,
        equals(['claude-sonnet-4.6', 'claude-haiku-4.6', 'gpt-5.4', 'gpt-4o']),
      );
      expect(profile.docsUrl, equals(GithubCopilotProtocol.verificationUri));
      expect(profile.supportsModelFetch, isTrue);
      expect(profile.supportsMultipleInstances, isTrue);
    });

    test('public map never includes secrets and keeps device_code only', () {
      final map = profile!.toPublicMap();
      expect(map['id'], equals(kGithubCopilotTemplateId));
      expect(map['auth_type'], equals('oauth_external'));
      expect(map['auth_flow'], equals('device_code'));
      expect(map['api_mode'], equals('chat_completions'));
      expect(map['auth_methods'], equals(['device_code']));
      expect(map.containsKey('client_id'), isFalse);
      expect(map.containsKey('access_token'), isFalse);
      expect(map['default_base_url'], equals('https://api.githubcopilot.com'));
    });

    test('is visible in the setup catalog once device-code is implemented', () {
      final catalog = ProviderCatalogService();
      expect(
        catalog.findById('copilot')?.name,
        equals(kGithubCopilotTemplateId),
      );
      expect(catalog.isVisible(profile!), isTrue);
      expect(
        catalog.visibleProfiles.any((p) => p.name == kGithubCopilotTemplateId),
        isTrue,
      );
    });
  });

  group('GithubCopilotProtocol constants', () {
    test('centralizes the public client id, exchange URL, and headers', () {
      expect(GithubCopilotProtocol.clientId, equals('Iv1.b507a08c87ecfe98'));
      expect(GithubCopilotProtocol.oauthScope, equals('read:user'));
      expect(
        GithubCopilotProtocol.tokenExchangeUrl,
        equals('https://api.github.com/copilot_internal/v2/token'),
      );
      expect(
        GithubCopilotProtocol.staticRequestHeaders,
        equals({
          'Copilot-Integration-Id': 'vscode-chat',
          'Openai-Intent': 'conversation-edits',
          'Editor-Version': 'vscode/1.104.1',
        }),
      );
      expect(
        GithubCopilotProtocol.refreshSafetyMargin,
        equals(const Duration(seconds: 120)),
      );
    });

    test('rejects classic personal access tokens', () {
      expect(
        GithubCopilotProtocol.isClassicPersonalAccessToken('ghp_secret'),
        isTrue,
      );
      expect(
        GithubCopilotProtocol.isClassicPersonalAccessToken('ghu_user'),
        isFalse,
      );
      expect(
        GithubCopilotProtocol.classicPatRejectionMessage,
        contains('ghp_*'),
      );
      expect(
        GithubCopilotProtocol.classicPatRejectionMessage,
        isNot(contains('ghp_secret')),
      );
    });
  });
}
