import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

class _SupportedEffortPolicy implements ProviderThinkingPolicy {
  @override
  String get policyId => 'test_effort';

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: const [
        ThinkingControlOption(id: 'low', label: 'Low'),
        ThinkingControlOption(id: 'medium', label: 'Medium'),
      ],
      capabilityRevision: 'rev-test',
      source: 'profile',
    );
  }

  @override
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  ) {
    if (selectionId == null || selectionId.isEmpty) {
      return const UseProviderDefault();
    }
    return OpenAiEffortDirective(selectionId);
  }
}

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ThinkingSelectionResolver resolver;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    final registry = buildProviderThinkingRegistry();
    registry.register(_SupportedEffortPolicy());
    final assembler = ThinkingCapabilityAssembler(registry);
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
  });

  tearDown(() => state.dispose());

  test('null selection resolves to provider default', () {
    repo.createInstance(_instance());

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'gpt-test',
      selectionId: null,
    );

    expect(resolution.selectionId, isNull);
    expect(resolution.directive, isA<UseProviderDefault>());
  });

  test('explicit unsupported route rejects selection before adapter call', () {
    repo.createInstance(_instance());
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': 'rev-1',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'inst-1',
        modelId: 'gpt-test',
        selectionId: 'medium',
      ),
      throwsA(
        isA<ThinkingSelectionException>().having(
          (error) => error.code,
          'code',
          ThinkingSelectionErrorCode.capabilityUnsupported,
        ),
      ),
    );
  });

  test('unknown template rejects explicit selection before adapter call', () {
    repo.createInstance(
      ProviderInstance(
        id: 'inst-unknown',
        templateId: 'missing-template',
        displayName: 'Missing',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'inst-unknown',
        modelId: 'gpt-test',
        selectionId: 'medium',
      ),
      throwsA(
        isA<ThinkingSelectionException>().having(
          (error) => error.code,
          'code',
          ThinkingSelectionErrorCode.capabilityUnknown,
        ),
      ),
    );
  });

  test('stale live evidence rejects cached supported descriptor', () {
    repo.createInstance(_instance());
    final staleObservedAt = DateTime.now().toUtc().subtract(
      const Duration(minutes: 10),
    );
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': '1:1:openai_chat_effort:o3',
            'source': 'live',
            'observed_at': staleObservedAt.toIso8601String(),
          },
        },
      ],
      fetchedAt: staleObservedAt,
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: null,
    );

    expect(resolution.descriptor.status, ThinkingCapabilityStatus.unknown);
    expect(resolution.descriptor.source, 'stale_live_evidence');
  });

  test('legacy fast alias maps to low when available in cache descriptor', () {
    repo.createInstance(_instance());
    const capabilityRevision = '1:1:openai_chat_effort:o3';
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': capabilityRevision,
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: 'fast',
    );

    expect(resolution.selectionId, 'low');
    expect(resolution.descriptor.isSupported, isTrue);
  });

  test('explicit valid selection resolves a typed native directive', () {
    repo.createInstance(_instance());
    const capabilityRevision = '1:1:openai_chat_effort:o3';
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': capabilityRevision,
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: 'medium',
    );

    expect(resolution.selectionId, 'medium');
    expect(resolution.directive, isA<OpenAiEffortDirective>());
  });

  test('unavailable legacy alias is rejected instead of silently ignored', () {
    repo.createInstance(_instance());
    const capabilityRevision = '1:1:openai_chat_effort:o1';
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o1',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': capabilityRevision,
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'inst-1',
        modelId: 'o1',
        selectionId: 'fast',
      ),
      throwsA(
        isA<ThinkingSelectionException>().having(
          (error) => error.code,
          'code',
          ThinkingSelectionErrorCode.optionUnavailable,
        ),
      ),
    );
  });

  test('manual anthropic route rejects missing budget tier before adapter call', () {
    repo.createInstance(_anthropicInstance());
    repo.upsertModelCache(
      instanceId: 'anthropic-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'claude-sonnet-4-5',
          'thinking_control': {
            'status': 'supported',
            'kind': 'tokenBudget',
            'options': [
              {'id': 'off', 'label': 'Off', 'is_off': true},
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': 'rev-anthropic-manual',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'anthropic-1',
        modelId: 'claude-sonnet-4-5',
        selectionId: 'max',
      ),
      throwsA(
        isA<ThinkingSelectionException>().having(
          (error) => error.code,
          'code',
          ThinkingSelectionErrorCode.optionUnavailable,
        ),
      ),
    );
  });
}

ProviderInstance _instance() {
  return ProviderInstance(
    id: 'inst-1',
    templateId: 'openai',
    displayName: 'OpenAI',
    protocol: ProviderProtocol.openaiCompatible,
    authMethod: ProviderAuthMethod.apiKey,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

ProviderInstance _anthropicInstance() {
  return ProviderInstance(
    id: 'anthropic-1',
    templateId: 'anthropic',
    displayName: 'Anthropic',
    protocol: ProviderProtocol.anthropicCompatible,
    authMethod: ProviderAuthMethod.apiKey,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}
