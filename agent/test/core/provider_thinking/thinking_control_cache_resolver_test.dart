import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  test('resolve returns thinking_control for matching cached model', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    repo.createInstance(
      ProviderInstance(
        id: 'inst-1',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        configRevision: 2,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          'label': 'GPT Test',
          'thinking_control': {
            'status': 'unknown',
            'capability_revision': 'rev-1',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 2,
      credentialRevision: 1,
    );

    final resolver = ThinkingControlCacheResolver(repo);
    final resolved = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'gpt-test',
      templateId: 'openai',
      protocol: ProviderProtocol.openaiCompatible,
      configRevision: 2,
      credentialRevision: 1,
    );

    expect(resolved, isNotNull);
    expect(resolved!['status'], 'unknown');
  });

  test('resolve returns null when cache revision mismatches', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    repo.createInstance(
      ProviderInstance(
        id: 'inst-1',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        configRevision: 3,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          'thinking_control': {'status': 'unknown'},
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 2,
      credentialRevision: 1,
    );

    final resolver = ThinkingControlCacheResolver(repo);
    final resolved = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'gpt-test',
      templateId: 'openai',
      protocol: ProviderProtocol.openaiCompatible,
      configRevision: 3,
      credentialRevision: 1,
    );

    expect(resolved, isNull);
  });

  test('resolve returns null when credential revision mismatches', () {
    final state = AgentStateDatabase.inMemory();
    addTearDown(state.dispose);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    repo.createInstance(
      ProviderInstance(
        id: 'inst-1',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        configRevision: 2,
        credentialRevision: 2,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          'thinking_control': {'status': 'unknown'},
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 2,
      credentialRevision: 1,
    );

    final resolver = ThinkingControlCacheResolver(repo);
    final resolved = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'gpt-test',
      templateId: 'openai',
      protocol: ProviderProtocol.openaiCompatible,
      configRevision: 2,
      credentialRevision: 2,
    );

    expect(resolved, isNull);
  });
}
