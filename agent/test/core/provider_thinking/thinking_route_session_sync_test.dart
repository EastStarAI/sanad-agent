import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
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

  setUp(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    final registry = buildProviderThinkingRegistry();
    final assembler = ThinkingCapabilityAssembler(registry);
    final selectionResolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
    store = ThinkingRoutePreferenceStore(sessions);
    final revalidator = ThinkingRouteRevalidator(
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
}
