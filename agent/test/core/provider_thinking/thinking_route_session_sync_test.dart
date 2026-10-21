import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late SessionManager sessions;
  late ThinkingRouteSessionSync sync;
  late ThinkingRoutePreferenceStore store;
  late ThinkingSelectionResolver selectionResolver;
  late ThinkingRouteRevalidator revalidator;

  setUp(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    final registry = buildProviderThinkingRegistry();
    final assembler = ThinkingCapabilityAssembler(registry);
    selectionResolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
    store = ThinkingRoutePreferenceStore(sessions);
    revalidator = ThinkingRouteRevalidator(
      resolver: selectionResolver,
      store: store,
    );
    sync = ThinkingRouteSessionSync(
      revalidator: revalidator,
      store: store,
      sessions: sessions,
    );

    for (final id in ['inst-1', 'inst-2']) {
      repo.createInstance(
        ProviderInstance(
          id: id,
          templateId: 'openai',
          displayName: id,
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gpt-test',
          status: InstanceStatus.ready,
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
    }
  });

  tearDown(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state.dispose();
  });

  test('switch from valid to unsupported route clears selection with correction', () {
    repo.upsertModelCache(
      instanceId: 'inst-2',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          // Provider-reported: the endpoint declares no request-time control.
          'model_metadata': {
            'thinking_control': {'status': 'unsupported'},
          },
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': '1:1:openai_chat_effort:gpt-test',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final session = sessions.createSession(
      'o3',
      providerId: 'inst-1',
      thinkingMode: 'high',
    );

    final result = sync.revalidateAndApplySession(
      sessionId: session.sessionId,
      providerInstanceId: 'inst-2',
      modelId: 'gpt-test',
      selectionId: 'high',
    );

    expect(result.corrected, isTrue);
    expect(result.selectionId, isNull);
    expect(sessions.getSession(session.sessionId)?.thinkingMode, isNull);
    expect(
      store.readCorrection(session.sessionId)?.reason,
      ThinkingSelectionErrorCode.capabilityUnsupported,
    );
    expect(
      sync.correctionPayloadFor(session.sessionId)?['previous_selection_id'],
      'high',
    );
  });

  test('restore revalidates when capability revision removes prior option', () {
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o1',
          // Provider-reported Codex-style native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'default_reasoning_level': 'medium',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': '1:1:openai_chat_effort:o1',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final session = sessions.createSession(
      'o1',
      providerId: 'inst-1',
      thinkingMode: 'low',
    );
    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'low',
        providerInstanceId: 'inst-1',
        modelId: 'o1',
        capabilityRevision: 'rev-stale',
      ),
    );

    final result = sync.revalidateAndApplySession(
      sessionId: session.sessionId,
      providerInstanceId: 'inst-1',
      modelId: 'o1',
    );

    expect(result.corrected, isTrue);
    expect(result.selectionId, isNull);
    expect(
      store.readCorrection(session.sessionId)?.reason,
      ThinkingSelectionErrorCode.optionUnavailable,
    );
  });

  test('revalidateTurnRequest clears unsupported failover selection', () {
    repo.upsertModelCache(
      instanceId: 'inst-2',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          // Provider-reported: the endpoint declares no request-time control.
          'model_metadata': {
            'thinking_control': {'status': 'unsupported'},
          },
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': '1:1:openai_chat_effort:gpt-test',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final rewritten = sync.revalidateTurnRequest(
      const AgentTurnRequest(
        sessionId: 'session-1',
        message: 'queued',
        providerInstanceId: 'inst-2',
        model: 'gpt-test',
        thinkingMode: 'high',
      ),
    );

    expect(rewritten.thinkingMode, isNull);
  });

  test('switching to unsupported route and back restores valid choice without choice clearing', () {
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          // Provider-reported Codex-style native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'default_reasoning_level': 'medium',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': '1:1:openai_chat_effort:o3',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    repo.upsertModelCache(
      instanceId: 'inst-2',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          // Provider-reported: the endpoint declares no request-time control.
          'model_metadata': {
            'thinking_control': {'status': 'unsupported'},
          },
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': '1:1:openai_chat_effort:gpt-test',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final session = sessions.createSession(
      'o3',
      providerId: 'inst-1',
      thinkingMode: 'high',
    );
    // Explicit valid preference saved for o3
    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'high',
        providerInstanceId: 'inst-1',
        modelId: 'o3',
        capabilityRevision: '1:1:openai_chat_effort:o3',
      ),
    );

    // Switch to inst-2 / gpt-test (unsupported)
    final resSwitch = sync.revalidateAndApplySession(
      sessionId: session.sessionId,
      providerInstanceId: 'inst-2',
      modelId: 'gpt-test',
      selectionId: 'high',
    );
    expect(resSwitch.selectionId, isNull);
    expect(sessions.getSession(session.sessionId)?.thinkingMode, isNull);

    // Switch back to inst-1 / o3: restores 'high' from stored route preference
    final resBack = sync.revalidateAndApplySession(
      sessionId: session.sessionId,
      providerInstanceId: 'inst-1',
      modelId: 'o3',
    );
    expect(resBack.selectionId, 'high');
    expect(sessions.getSession(session.sessionId)?.thinkingMode, 'high');
    expect(
      store.readForRoute(session.sessionId, providerInstanceId: 'inst-1', modelId: 'o3')?.selectionId,
      'high',
    );
  });

  test('revalidateForRoute with selectionId: null sets provider-default and does not resurrect preserved preference when restorePreserved is false', () {
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          // Provider-reported Codex-style native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'default_reasoning_level': 'medium',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': '1:1:openai_chat_effort:o3',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final session = sessions.createSession(
      'o3',
      providerId: 'inst-1',
      thinkingMode: 'high',
    );
    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'high',
        providerInstanceId: 'inst-1',
        modelId: 'o3',
        capabilityRevision: '1:1:openai_chat_effort:o3',
      ),
    );

    // Caller deliberately sets provider-default by passing selectionId: null (restorePreserved: false)
    final result = revalidator.revalidateForRoute(
      sessionId: session.sessionId,
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: null,
      restorePreserved: false,
    );

    expect(result.selectionId, isNull);
    expect(
      store.readForRoute(session.sessionId, providerInstanceId: 'inst-1', modelId: 'o3')?.selectionId,
      isNull,
    );
  });

  test('public revalidateAndApplySession with selectionId: null and restorePreserved: false resets persisted mode and stored preference', () {
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          // Provider-reported Codex-style native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'default_reasoning_level': 'medium',
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': '1:1:openai_chat_effort:o3',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final session = sessions.createSession(
      'o3',
      providerId: 'inst-1',
      thinkingMode: 'high',
    );
    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'high',
        providerInstanceId: 'inst-1',
        modelId: 'o3',
        capabilityRevision: '1:1:openai_chat_effort:o3',
      ),
    );

    // Call public sync path with deliberate default intent (selectionId: null, restorePreserved: false)
    final result = sync.revalidateAndApplySession(
      sessionId: session.sessionId,
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: null,
      restorePreserved: false,
    );

    // 1. Returned selection must be null
    expect(result.selectionId, isNull);
    // 2. PERSISTED session mode in SessionManager/database must be null
    expect(sessions.getSession(session.sessionId)?.thinkingMode, isNull);
    // 3. Stored route preference must be null
    expect(
      store.readForRoute(session.sessionId, providerInstanceId: 'inst-1', modelId: 'o3')?.selectionId,
      isNull,
    );
  });

  group('auto-failover sync path (after route mutation) through same-route legacy branch', () {
    test('supported inherited choice survives onto candidate route', () {
      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
            'value': 'o1',
            // Provider-reported Codex-style native levels (capability authority).
            'supported_reasoning_levels': [
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
            'default_reasoning_level': 'medium',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
              ],
              'capability_revision': 'rev-inst-1',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      repo.upsertModelCache(
        instanceId: 'inst-2',
        cacheKey: 'models',
        models: [
          {
            'value': 'o1',
            // Provider-reported Codex-style native levels (capability authority).
            'supported_reasoning_levels': [
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
            'default_reasoning_level': 'medium',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
              ],
              'capability_revision': 'rev-inst-2',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      // Session starts on inst-1 with medium thinkingMode
      final session = sessions.createSession('o1', providerId: 'inst-1', thinkingMode: 'medium');
      store.savePreference(
        sessionId: session.sessionId,
        preference: const ThinkingRoutePreference(
          selectionId: 'medium',
          providerInstanceId: 'inst-1',
          modelId: 'o1',
          capabilityRevision: 'rev-inst-1',
        ),
      );

      // Failover occurs: routeCoordinator/sessionManager updates session provider to candidate (inst-2)
      sessions.updateSessionProviderId(session.sessionId, 'inst-2');

      // Then AgentRunner calls revalidateAndApplySession(sessionId, 'inst-2', 'o1')
      final result = sync.revalidateAndApplySession(
        sessionId: session.sessionId,
        providerInstanceId: 'inst-2',
        modelId: 'o1',
      );

      // 1. Result selection survives as 'medium'
      expect(result.selectionId, 'medium');
      expect(result.corrected, isFalse);

      // 2. Persisted session mode in database remains 'medium'
      expect(sessions.getSession(session.sessionId)?.thinkingMode, 'medium');
      expect(sessions.getSession(session.sessionId)?.providerId, 'inst-2');

      // 3. Stored route preference for candidate is 'medium'
      expect(
        store.readForRoute(session.sessionId, providerInstanceId: 'inst-2', modelId: 'o1')?.selectionId,
        'medium',
      );

      // 4. Wire directive matches
      final resolution = selectionResolver.resolve(
        providerInstanceId: 'inst-2',
        modelId: 'o1',
        selectionId: result.selectionId,
      );
      expect(resolution.directive, isA<OpenAiEffortDirective>());
      expect((resolution.directive as OpenAiEffortDirective).effort, 'medium');
    });

    test('unsupported candidate becomes default without spurious correction', () {
      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
            'value': 'gpt-test',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
              ],
              'capability_revision': '1:1:openai_chat_effort:gpt-test',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      repo.upsertModelCache(
        instanceId: 'inst-2',
        cacheKey: 'models',
        models: [
          {
            'value': 'gpt-test',
            // Provider-reported: the endpoint declares no request-time control.
            'model_metadata': {
              'thinking_control': {'status': 'unsupported'},
            },
            'thinking_control': {
              'status': 'unsupported',
              'capability_revision': '1:1:openai_chat_effort:gpt-test',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      // Session starts on inst-1 with medium thinkingMode
      final session = sessions.createSession('gpt-test', providerId: 'inst-1', thinkingMode: 'medium');
      store.savePreference(
        sessionId: session.sessionId,
        preference: const ThinkingRoutePreference(
          selectionId: 'medium',
          providerInstanceId: 'inst-1',
          modelId: 'gpt-test',
          capabilityRevision: '1:1:openai_chat_effort:gpt-test',
        ),
      );

      // Failover occurs: route mutation updates session provider to candidate (inst-2)
      sessions.updateSessionProviderId(session.sessionId, 'inst-2');

      // AgentRunner calls revalidateAndApplySession(sessionId, 'inst-2', 'gpt-test')
      final result = sync.revalidateAndApplySession(
        sessionId: session.sessionId,
        providerInstanceId: 'inst-2',
        modelId: 'gpt-test',
      );

      // 1. Result selection is null (default) without spurious correction
      expect(result.selectionId, isNull);
      expect(result.corrected, isFalse);
      expect(store.readCorrection(session.sessionId), isNull);

      // 2. Persisted session mode in database is cleared to null
      expect(sessions.getSession(session.sessionId)?.thinkingMode, isNull);

      // 3. Stored route preference for candidate is provider-default (null)
      expect(
        store.readForRoute(session.sessionId, providerInstanceId: 'inst-2', modelId: 'gpt-test')?.selectionId,
        isNull,
      );

      // 4. Wire directive is UseProviderDefault
      final resolution = selectionResolver.resolve(
        providerInstanceId: 'inst-2',
        modelId: 'gpt-test',
        selectionId: result.selectionId,
      );
      expect(resolution.directive, isA<UseProviderDefault>());
    });

    test('stored candidate-route preference wins over inherited mode', () {
      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
            'value': 'o3',
            // Provider-reported Codex-style native levels (capability authority).
            'supported_reasoning_levels': [
              {'effort': 'low'},
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
            'default_reasoning_level': 'medium',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
                {'id': 'high', 'label': 'High'},
              ],
              'capability_revision': 'rev-inst-1',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      repo.upsertModelCache(
        instanceId: 'inst-2',
        cacheKey: 'models',
        models: [
          {
            'value': 'o3',
            // Provider-reported Codex-style native levels (capability authority).
            'supported_reasoning_levels': [
              {'effort': 'low'},
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
            'default_reasoning_level': 'medium',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
                {'id': 'high', 'label': 'High'},
              ],
              'capability_revision': 'rev-inst-2',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final session = sessions.createSession('o3', providerId: 'inst-1', thinkingMode: 'medium');

      // Candidate inst-2 has stored preference 'low'
      store.savePreference(
        sessionId: session.sessionId,
        preference: const ThinkingRoutePreference(
          selectionId: 'low',
          providerInstanceId: 'inst-2',
          modelId: 'o3',
          capabilityRevision: 'rev-inst-2',
        ),
      );

      // Active preference was on inst-1 with 'medium'
      store.savePreference(
        sessionId: session.sessionId,
        preference: const ThinkingRoutePreference(
          selectionId: 'medium',
          providerInstanceId: 'inst-1',
          modelId: 'o3',
          capabilityRevision: 'rev-inst-1',
        ),
      );

      // Failover occurs: route mutation updates session provider to candidate (inst-2)
      sessions.updateSessionProviderId(session.sessionId, 'inst-2');

      // AgentRunner calls revalidateAndApplySession(sessionId, 'inst-2', 'o3')
      final result = sync.revalidateAndApplySession(
        sessionId: session.sessionId,
        providerInstanceId: 'inst-2',
        modelId: 'o3',
      );

      // 1. Result selection is 'low' (candidate stored preference wins over inherited 'medium')
      expect(result.selectionId, 'low');
      expect(result.corrected, isFalse);

      // 2. Persisted session mode in database is 'low'
      expect(sessions.getSession(session.sessionId)?.thinkingMode, 'low');

      // 3. Stored route preference remains 'low'
      expect(
        store.readForRoute(session.sessionId, providerInstanceId: 'inst-2', modelId: 'o3')?.selectionId,
        'low',
      );

      // 4. Wire directive is OpenAiEffortDirective('low')
      final resolution = selectionResolver.resolve(
        providerInstanceId: 'inst-2',
        modelId: 'o3',
        selectionId: result.selectionId,
      );
      expect(resolution.directive, isA<OpenAiEffortDirective>());
      expect((resolution.directive as OpenAiEffortDirective).effort, 'low');
    });

    test('stored candidate-route provider-default wins over inherited mode', () {
      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {
            'value': 'o1',
            // Provider-reported Codex-style native levels (capability authority).
            'supported_reasoning_levels': [
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
            'default_reasoning_level': 'medium',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
              ],
              'capability_revision': 'rev-inst-1',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      repo.upsertModelCache(
        instanceId: 'inst-2',
        cacheKey: 'models',
        models: [
          {
            'value': 'o1',
            // Provider-reported Codex-style native levels (capability authority).
            'supported_reasoning_levels': [
              {'effort': 'medium'},
              {'effort': 'high'},
            ],
            'default_reasoning_level': 'medium',
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
              ],
              'capability_revision': 'rev-inst-2',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final session = sessions.createSession('o1', providerId: 'inst-1', thinkingMode: 'medium');

      // Candidate inst-2 has stored preference for provider-default (selectionId: null)
      store.savePreference(
        sessionId: session.sessionId,
        preference: const ThinkingRoutePreference(
          selectionId: null,
          providerInstanceId: 'inst-2',
          modelId: 'o1',
          capabilityRevision: 'provider-default',
        ),
      );

      // Active preference was on inst-1 with 'medium'
      store.savePreference(
        sessionId: session.sessionId,
        preference: const ThinkingRoutePreference(
          selectionId: 'medium',
          providerInstanceId: 'inst-1',
          modelId: 'o1',
          capabilityRevision: 'rev-inst-1',
        ),
      );

      // Failover occurs: route mutation updates session provider to candidate (inst-2)
      sessions.updateSessionProviderId(session.sessionId, 'inst-2');

      // AgentRunner calls revalidateAndApplySession(sessionId, 'inst-2', 'o1')
      final result = sync.revalidateAndApplySession(
        sessionId: session.sessionId,
        providerInstanceId: 'inst-2',
        modelId: 'o1',
      );

      // 1. Result selection is null (stored provider-default wins over inherited 'medium')
      expect(result.selectionId, isNull);
      expect(result.corrected, isFalse);

      // 2. Persisted session mode in database is null
      expect(sessions.getSession(session.sessionId)?.thinkingMode, isNull);

      // 3. Stored route preference is null
      expect(
        store.readForRoute(session.sessionId, providerInstanceId: 'inst-2', modelId: 'o1')?.selectionId,
        isNull,
      );

      // 4. Wire directive is UseProviderDefault
      final resolution = selectionResolver.resolve(
        providerInstanceId: 'inst-2',
        modelId: 'o1',
        selectionId: result.selectionId,
      );
      expect(resolution.directive, isA<UseProviderDefault>());
    });
  });
}
