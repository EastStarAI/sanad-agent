import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  test('stores and reads thinking route preference in session metadata', () {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    final state = AgentStateDatabase.inMemory();
    addTearDown(() {
      GetIt.I.reset();
      SessionManager.resetForTesting();
      state.dispose();
    });
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    final sessions = SessionManager();
    final store = ThinkingRoutePreferenceStore(sessions);
    final session = sessions.createSession('gpt-test');

    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'medium',
        providerInstanceId: 'inst-1',
        modelId: 'gpt-test',
        capabilityRevision: 'rev-1',
      ),
    );

    final read = store.read(session.sessionId);
    expect(read?.selectionId, 'medium');
    expect(read?.capabilityRevision, 'rev-1');
  });

  test('records correction and clears preference binding', () {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    final state = AgentStateDatabase.inMemory();
    addTearDown(() {
      GetIt.I.reset();
      SessionManager.resetForTesting();
      state.dispose();
    });
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    final sessions = SessionManager();
    final store = ThinkingRoutePreferenceStore(sessions);
    final session = sessions.createSession('gpt-test');

    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'deep',
        providerInstanceId: 'inst-1',
        modelId: 'gpt-test',
        capabilityRevision: 'rev-old',
      ),
    );
    store.recordCorrection(
      sessionId: session.sessionId,
      reason: 'thinking_option_unavailable_for_route',
      previousSelectionId: 'deep',
    );

    expect(store.read(session.sessionId), isNull);
    expect(store.readCorrection(session.sessionId)?.previousSelectionId, 'deep');
  });

  test('preserves distinct route preferences across different provider/model routes', () {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    final state = AgentStateDatabase.inMemory();
    addTearDown(() {
      GetIt.I.reset();
      SessionManager.resetForTesting();
      state.dispose();
    });
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    final sessions = SessionManager();
    final store = ThinkingRoutePreferenceStore(sessions);
    final session = sessions.createSession('o3');

    // Route A: inst-1, o3 => high
    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'high',
        providerInstanceId: 'inst-1',
        modelId: 'o3',
        capabilityRevision: 'rev-o3',
      ),
    );

    // Route B: inst-codex, gpt-6-luna => medium
    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'medium',
        providerInstanceId: 'inst-codex',
        modelId: 'gpt-6-luna',
        capabilityRevision: 'rev-codex',
      ),
    );

    // Active preference is Route B
    expect(store.read(session.sessionId)?.selectionId, 'medium');

    // But Route A is preserved independently
    final routeAPref = store.readForRoute(
      session.sessionId,
      providerInstanceId: 'inst-1',
      modelId: 'o3',
    );
    expect(routeAPref?.selectionId, 'high');
    expect(routeAPref?.modelId, 'o3');

    // And Route B is preserved
    final routeBPref = store.readForRoute(
      session.sessionId,
      providerInstanceId: 'inst-codex',
      modelId: 'gpt-6-luna',
    );
    expect(routeBPref?.selectionId, 'medium');

    // Correcting Route B does not erase Route A
    store.recordCorrection(
      sessionId: session.sessionId,
      reason: 'unsupported',
      providerInstanceId: 'inst-codex',
      modelId: 'gpt-6-luna',
    );
    expect(
      store.readForRoute(
        session.sessionId,
        providerInstanceId: 'inst-codex',
        modelId: 'gpt-6-luna',
      ),
      isNull,
    );
    expect(
      store.readForRoute(
        session.sessionId,
        providerInstanceId: 'inst-1',
        modelId: 'o3',
      )?.selectionId,
      'high',
    );
  });

  test('recordCorrection without route args removes active route preference from routePreferences map', () {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    final state = AgentStateDatabase.inMemory();
    addTearDown(() {
      GetIt.I.reset();
      SessionManager.resetForTesting();
      state.dispose();
    });
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    final sessions = SessionManager();
    final store = ThinkingRoutePreferenceStore(sessions);
    final session = sessions.createSession('o3');

    store.savePreference(
      sessionId: session.sessionId,
      preference: const ThinkingRoutePreference(
        selectionId: 'high',
        providerInstanceId: 'inst-1',
        modelId: 'o3',
        capabilityRevision: 'rev-1',
      ),
    );

    expect(store.read(session.sessionId)?.selectionId, 'high');
    expect(
      store.readForRoute(session.sessionId, providerInstanceId: 'inst-1', modelId: 'o3')?.selectionId,
      'high',
    );

    store.recordCorrection(
      sessionId: session.sessionId,
      reason: 'option_unavailable',
      previousSelectionId: 'high',
    );

    expect(store.read(session.sessionId), isNull);
    expect(
      store.readForRoute(session.sessionId, providerInstanceId: 'inst-1', modelId: 'o3'),
      isNull,
    );
  });
}
