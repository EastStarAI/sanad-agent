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
}
