import 'dart:io';

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
