import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_config_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/setup/cli_provider_setup.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempWorkDir;
  late Directory tempSanadHome;

  setUp(() async {
    tempWorkDir = await Directory.systemTemp.createTemp('sanad-cli-setup');
    tempSanadHome = await Directory.systemTemp.createTemp('sanad-cli-home');
    setSanadHomeOverride(tempSanadHome.path);
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    if (tempWorkDir.existsSync()) await tempWorkDir.delete(recursive: true);
    if (tempSanadHome.existsSync()) await tempSanadHome.delete(recursive: true);
  });

  EnvFileService envWith(String content) {
    final file = File('${tempWorkDir.path}/.env');
    file.writeAsStringSync(content);
    return EnvFileService(envPath: file.path);
  }

  CliProviderServices servicesWith(EnvFileService env) {
    final credStore = ProviderCredentialStore(
      storePath: '${tempSanadHome.path}/provider_auth.json',
    );
    final catalog = ProviderCatalogService();
    final state = ProviderStateService(env, credStore);
    final resolver = ProviderCredentialResolver(env, credStore);
    final auth = ProviderAuthSessionService(credStore);
    final providerConfig = ProviderConfigService(env, credStore);
    final repo = ProviderInstanceRepository.inMemory();
    final secretStore = SecureFileSecretStore();
    final readiness = ProviderReadinessService(repo, secretStore);
    final modelOptions = ModelOptionsService(env, resolver);
    final modelSelection = ModelSelectionService(env);
    final runtime = AgentRuntimeService(
      Config(),
      repo,
      credentialResolver: resolver,
    );
    final modelCache = ProviderModelCacheService(
      repo,
      runtime,
      buildDefaultThinkingCapabilityAssembler(),
    );
    final recentSelection = RecentModelSelectionService(repo);
    return CliProviderServices.from(
      env: env,
      credStore: credStore,
      catalog: catalog,
      state: state,
      resolver: resolver,
      auth: auth,
      config: providerConfig,
      readiness: readiness,
      modelOptions: modelOptions,
      modelSelection: modelSelection,
      instanceRepo: repo,
      modelCache: modelCache,
      recentSelection: recentSelection,
      secretStore: secretStore,
    );
  }

  test('listProviders reports the configured instances source of truth', () {
    final env = envWith('''
ACTIVE_PROVIDER=openai
OPENAI_API_KEY=sk-test
OPENAI_MODEL=gpt-4o
''');
    final services = servicesWith(env);
    final cli = CliProviderSetup(services);

    services.instanceRepo.createInstance(
      ProviderInstance(
        id: 'openai-inst',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        status: InstanceStatus.ready,
        isDefault: true,
        defaultModel: 'gpt-4o',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    cli.listProviders();
    expect(services.instanceService.findDefault()?.id, equals('openai-inst'));
  });

  group('rejected credential surfaces', () {
    const secret = 'sk-rejected-credential-000123456789';

    ProviderDiscoveryError rejectedCredential() =>
        ProviderDiscoveryError.capture(
          LlmHttpException.fromResponse(
            http.Response(
              '{"error":{"message":"Invalid credential for $secret"}}',
              401,
              headers: {'x-api-key': secret},
            ),
            operation: 'getAvailableModels',
          ),
          endpoint: Uri.parse('https://opencode.ai/zen/go/v1/models'),
        );

    void seedRejectedInstance(CliProviderServices services) {
      const instanceId = 'opencode-inst';
      final instance = ProviderInstance(
        id: instanceId,
        templateId: 'opencode-go',
        displayName: 'OpenCode Go',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://opencode.ai/zen/go/v1',
        defaultModel: 'gpt-4o',
        status: InstanceStatus.draft,
        isDefault: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      services.instanceRepo.createInstance(instance);
      final error = rejectedCredential();
      services.instanceRepo.upsertModelCache(
        instanceId: instanceId,
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o'},
        ],
        fetchedAt: DateTime.utc(2026, 1, 2),
        source: 'fallback',
        configRevision: instance.configRevision,
        credentialRevision: instance.credentialRevision,
        lastError: error.summary,
        lastErrorDetail: error.toJson(),
      );
    }

    test('sanad providers names the cause instead of only DRAFT', () {
      final env = envWith('ACTIVE_PROVIDER=opencode-go\n');
      final services = servicesWith(env);
      seedRejectedInstance(services);

      final out = StringBuffer();
      CliProviderSetup(services).listProviders(out: out);

      final text = out.toString();
      expect(text, contains('DRAFT'));
      expect(
        text,
        contains(
          'Discovery error: Invalid credential (HTTP 401) from '
          'https://opencode.ai/zen/go/v1/models',
        ),
      );
      expect(text, contains('Models: unverified fallback list'));
      // The provider body and the credential never reach the CLI.
      expect(text, isNot(contains(secret)));
      expect(text, isNot(contains('Invalid credential for')));
    });

    test('sanad providers --json exposes the structured cause', () {
      final env = envWith('ACTIVE_PROVIDER=opencode-go\n');
      final services = servicesWith(env);
      seedRejectedInstance(services);

      final out = StringBuffer();
      CliProviderSetup(services).listProviders(out: out, json: true);

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      final providers = decoded['providers'] as List;
      expect(providers, hasLength(1));
      final provider = providers.single as Map<String, dynamic>;
      expect(provider['id'], 'opencode-inst');
      expect(provider['display_name'], 'OpenCode Go');
      expect(provider['status'], InstanceStatus.draft);
      expect(provider['model_cache'], {'source': 'fallback', 'verified': false});
      final error = provider['discovery_error'] as Map<String, dynamic>;
      expect(error['kind'], ProviderFailureCategory.invalidCredential);
      expect(error['status_code'], 401);
      expect(error['message'], 'Invalid credential (HTTP 401)');
      expect(error['endpoint'], 'https://opencode.ai/zen/go/v1/models');
      expect(decoded['default_provider_id'], 'opencode-inst');
      expect(out.toString(), isNot(contains(secret)));
    });

    test('sanad providers demotes a legacy ready row on the same read', () {
      final env = envWith('ACTIVE_PROVIDER=opencode-go\n');
      final services = servicesWith(env);
      final instance = ProviderInstance(
        id: 'legacy-ready',
        templateId: 'opencode-go',
        displayName: 'Legacy Ready',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://opencode.ai/zen/go/v1',
        defaultModel: 'gpt-4o',
        status: InstanceStatus.ready,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      services.instanceRepo.createInstance(instance);
      // A row written before structured causes existed: raw text only, current
      // revisions, and a stored status that still says ready (issue 339 review
      // 3).
      services.instanceRepo.upsertModelCache(
        instanceId: instance.id,
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o'},
        ],
        fetchedAt: DateTime.utc(2026, 1, 2),
        source: 'fallback',
        configRevision: instance.configRevision,
        credentialRevision: instance.credentialRevision,
        lastError: 'HTTP 401',
      );

      final json = StringBuffer();
      CliProviderSetup(services).listProviders(out: json, json: true);

      final entry =
          ((jsonDecode(json.toString()) as Map<String, dynamic>)['providers']
                  as List)
              .single
              as Map<String, dynamic>;
      expect(entry['status'], InstanceStatus.needsAuth);
      expect(
        (entry['discovery_error'] as Map<String, dynamic>)['kind'],
        ProviderFailureCategory.invalidCredential,
      );
      expect(
        services.instanceRepo.findById(instance.id)!.status,
        InstanceStatus.needsAuth,
      );

      // The human form reads the same effective status, on a later read of the
      // already-repaired row.
      final text = StringBuffer();
      CliProviderSetup(services).listProviders(out: text);
      expect(text.toString(), contains('NEEDS_AUTH'));
      expect(text.toString(), isNot(contains('READY')));
    });

    test('sanad setup status reconciles a legacy ready default on the same read', () {
      final env = envWith('ACTIVE_PROVIDER=opencode-go\n');
      final services = servicesWith(env);
      final instance = ProviderInstance(
        id: 'legacy-default',
        templateId: 'opencode-go',
        displayName: 'Legacy Default',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://opencode.ai/zen/go/v1',
        defaultModel: 'gpt-4o',
        status: InstanceStatus.ready,
        isDefault: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      services.instanceRepo.createInstance(instance);
      services.instanceRepo.upsertModelCache(
        instanceId: instance.id,
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o'},
        ],
        fetchedAt: DateTime.utc(2026, 1, 2),
        source: 'fallback',
        configRevision: instance.configRevision,
        credentialRevision: instance.credentialRevision,
        lastError: 'HTTP 401',
      );

      final out = StringBuffer();
      CliProviderSetup(services).status(out: out);

      final text = out.toString();
      // Readiness is never true beside a definitive cause: the repaired status
      // takes the sign-in branch instead of reporting a ready default.
      expect(text, contains('runtime_ready:   false'));
      expect(text, contains('reason:          Credential missing or expired.'));
      final json = StringBuffer();
      CliProviderSetup(services).status(out: json, json: true);
      final decoded = jsonDecode(json.toString()) as Map<String, dynamic>;
      expect(decoded['active_provider_status'], InstanceStatus.needsAuth);
      expect(services.instanceRepo.findById(instance.id)!.status,
          InstanceStatus.needsAuth);
    });

    test('sanad setup status reports the cause as the readiness reason', () {
      final env = envWith('ACTIVE_PROVIDER=opencode-go\n');
      final services = servicesWith(env);
      seedRejectedInstance(services);

      final out = StringBuffer();
      CliProviderSetup(services).status(out: out);

      final text = out.toString();
      expect(text, contains('runtime_ready:   false'));
      expect(
        text,
        contains(
          'reason:          Invalid credential (HTTP 401) from '
          'https://opencode.ai/zen/go/v1/models',
        ),
      );
      expect(text, isNot(contains(secret)));
    });

    test('sanad providers --json emits every nullable field as null', () {
      final env = envWith('ACTIVE_PROVIDER=openai\n');
      final services = servicesWith(env);
      // An instance with no base URL and no selected model still has a stable
      // shape: a consumer must never see a missing key (issue 339 review 2).
      services.instanceRepo.createInstance(
        ProviderInstance(
          id: 'model-less',
          templateId: 'custom',
          displayName: 'Local',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          status: InstanceStatus.draft,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final out = StringBuffer();
      CliProviderSetup(services).listProviders(out: out, json: true);

      final provider =
          ((jsonDecode(out.toString()) as Map<String, dynamic>)['providers']
                  as List)
              .single
              as Map<String, dynamic>;
      expect(provider.containsKey('base_url'), isTrue);
      expect(provider['base_url'], isNull);
      expect(provider.containsKey('default_model'), isTrue);
      expect(provider['default_model'], isNull);
      // The discovery projection is always present, as null when healthy.
      expect(provider.containsKey('discovery_error'), isTrue);
      expect(provider['discovery_error'], isNull);
      expect(provider.containsKey('model_cache'), isTrue);
    });

    test('sanad setup status --json carries the structured cause', () {
      final env = envWith('ACTIVE_PROVIDER=opencode-go\n');
      final services = servicesWith(env);
      seedRejectedInstance(services);

      final out = StringBuffer();
      CliProviderSetup(services).status(out: out, json: true);

      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['has_provider'], isTrue);
      expect(decoded['runtime_ready'], isFalse);
      expect(decoded['active_provider'], 'opencode-inst');
      expect(decoded['active_provider_status'], InstanceStatus.draft);
      final error = decoded['discovery_error'] as Map<String, dynamic>;
      expect(error['kind'], ProviderFailureCategory.invalidCredential);
      expect(error['status_code'], 401);
      expect(out.toString(), isNot(contains(secret)));
    });
  });

  test('removeProvider clears only matching provider instances', () async {
    final env = envWith('''
ACTIVE_PROVIDER=openai
OPENAI_API_KEY=sk-openai
OPENAI_MODEL=gpt-4o
OPENROUTER_API_KEY=sk-or
OPENROUTER_MODEL=mistralai/mistral-large
''');
    final services = servicesWith(env);
    final cli = CliProviderSetup(services);

    final openaiInst = ProviderInstance(
      id: 'openai-inst',
      templateId: 'openai',
      displayName: 'OpenAI',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      status: InstanceStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final openrouterInst = ProviderInstance(
      id: 'openrouter-inst',
      templateId: 'openrouter',
      displayName: 'OpenRouter',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      status: InstanceStatus.ready,
      isDefault: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    services.instanceRepo.createInstance(openaiInst);
    services.instanceRepo.createInstance(openrouterInst);
    await services.secretStore.write(
      'openai-inst',
      SecretRecord(
        instanceId: 'openai-inst',
        apiKey: 'sk-openai',
        authMethod: ProviderAuthMethod.apiKey,
      ),
    );
    await services.secretStore.write(
      'openrouter-inst',
      SecretRecord(
        instanceId: 'openrouter-inst',
        apiKey: 'sk-or',
        authMethod: ProviderAuthMethod.apiKey,
      ),
    );

    await cli.removeProvider('openai');

    expect(services.instanceRepo.findById('openai-inst'), isNull);
    expect(services.instanceRepo.findById('openrouter-inst'), isNotNull);
  });

  test('status reports runtime readiness for a configured provider', () async {
    final env = envWith('''
ACTIVE_PROVIDER=openai
OPENAI_API_KEY=sk-test
OPENAI_MODEL=gpt-4o
LLM_BASE_URL=https://api.openai.com/v1
''');
    final services = servicesWith(env);
    final cli = CliProviderSetup(services);

    // Create an instance in the repository for the readiness service.
    services.instanceRepo.createInstance(
      ProviderInstance(
        id: 'openai-inst',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o',
        status: InstanceStatus.ready,
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await services.secretStore.write(
      'openai-inst',
      SecretRecord(
        instanceId: 'openai-inst',
        apiKey: 'sk-test',
        authMethod: ProviderAuthMethod.apiKey,
      ),
    );

    cli.status();

    final readiness = services.readiness.runtimeCheck();
    expect(readiness.hasProvider, isTrue);
    expect(readiness.runtimeReady, isTrue);
    expect(readiness.activeProvider, equals('openai-inst'));
    expect(readiness.activeModel, equals('gpt-4o'));
  });

  test('CLI and services share the same source of truth (D3)', () {
    final env = envWith('''
ACTIVE_PROVIDER=ollama
LLM_BASE_URL=http://localhost:11434
LLM_MODEL=llama3.1
''');
    final services = servicesWith(env);

    // The catalog is the ProviderRegistry (same as the UI sees via socket).
    expect(services.catalog.visibleProfiles.length, greaterThan(5));
    expect(
      services.catalog.visibleProfiles.any((p) => p.name == 'xai-oauth'),
      isFalse,
    );
    final active = services.state.resolveActiveProviderId();
    expect(active, equals('ollama'));
  });
}
