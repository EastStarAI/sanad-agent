/// Task 106b R4 defect 2: an explicit thinking pick survives an agent restart.
///
/// glm-5.2 on OpenCode Go resolves from its serving models.dev entry (high/max)
/// with the shipped `max` as a filled default. The user explicitly picks `max`;
/// the agent restarts on the same on-disk state database while the cached
/// model catalog still carries a descriptor built under an older capability
/// revision, and the models.dev catalog may not be hydrated yet. The stored
/// pick must survive startup recovery and every later revalidation, and the
/// next turn must dispatch it.
library;

import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/models_dev_thinking_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:test/test.dart';
import '../../support/isolated_sanad_test_home.dart';

const _instanceId = 'inst-go';
const _model = 'glm-5.2';

/// The exact Test Home `opencode-go` glm-5.2 entry.
const _goGlm52 = {
  'reasoning': true,
  'reasoning_options': [
    {
      'type': 'effort',
      'values': ['high', 'max'],
    },
  ],
  'canonical_model_id': 'zhipuai/glm-5.2',
};

/// One agent process: its own DI, session manager and thinking authority over
/// the shared on-disk state database.
class _Runtime {
  final AgentStateDatabase state;
  final ProviderInstanceRepository repo;
  final SessionManager sessions;
  final ThinkingRoutePreferenceStore store;
  final ThinkingSelectionResolver resolver;
  final ThinkingRouteSessionSync sync;

  _Runtime._(
    this.state,
    this.repo,
    this.sessions,
    this.store,
    this.resolver,
    this.sync,
  );

  factory _Runtime.start(String stateHome, {required bool catalogHydrated}) {
    _unregisterState();
    SessionManager.resetForTesting();
    final state = AgentStateDatabase.atPath(stateHome);
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    final sessions = SessionManager();
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    final registry = buildProviderThinkingRegistry();
    final assembler = ThinkingCapabilityAssembler(
      registry,
      null,
      (vendor, model) =>
          catalogHydrated && vendor == 'opencode-go' && model == _model
          ? Map<String, dynamic>.from(_goGlm52)
          : null,
    );
    final resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
    final store = ThinkingRoutePreferenceStore(sessions);
    final sync = ThinkingRouteSessionSync(
      revalidator: ThinkingRouteRevalidator(resolver: resolver, store: store),
      store: store,
      sessions: sessions,
    );
    return _Runtime._(state, repo, sessions, store, resolver, sync);
  }

  void stop() {
    _unregisterState();
    SessionManager.resetForTesting();
    state.dispose();
  }
}

void _unregisterState() {
  if (GetIt.I.isRegistered<AgentStateDatabase>()) {
    GetIt.I.unregister<AgentStateDatabase>();
  }
}

void main() {
  useIsolatedSanadStateRoot();
  late Directory stateHome;

  setUp(() {
    stateHome = Directory.systemTemp.createTempSync('sanad_pick_restart_');
  });

  tearDown(() {
    _unregisterState();
    SessionManager.resetForTesting();
    if (stateHome.existsSync()) stateHome.deleteSync(recursive: true);
  });

  test('glm-5.2 explicit max survives a restart, a capability-revision '
      'change and a catalog reload, and the next turn sends it', () {
    // Process 1: the route resolves; the user explicitly picks `max`.
    var runtime = _Runtime.start(stateHome.path, catalogHydrated: true);
    final instance = ProviderInstance(
      id: _instanceId,
      templateId: 'opencode-go',
      displayName: 'Go',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      defaultModel: _model,
      status: InstanceStatus.ready,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    runtime.repo.createInstance(instance);
    final descriptor = runtime.resolver
        .resolve(
          providerInstanceId: _instanceId,
          modelId: _model,
          selectionId: null,
        )
        .descriptor;
    expect(descriptor.source, ModelsDevThinkingEvidence.sourceId);
    expect(descriptor.defaultOptionId, 'max');

    // The catalog cache persists the descriptor under an *older* capability
    // revision (built before the default fill), as an upgraded Home would.
    final stale = descriptor.copyWith(
      capabilityRevision: descriptor.capabilityRevision.split('+').first,
    );
    expect(stale.capabilityRevision, isNot(descriptor.capabilityRevision));
    runtime.repo.upsertModelCache(
      instanceId: _instanceId,
      cacheKey: 'models',
      models: [
        {'value': _model, 'label': _model, 'thinking_control': stale.toMap()},
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );

    final sessionId = runtime.sessions
        .createSession(_model, providerId: _instanceId)
        .sessionId;
    // `update_session_preferences` with an explicit choice.
    final picked = runtime.sync.revalidateAndApplySession(
      sessionId: sessionId,
      providerInstanceId: _instanceId,
      modelId: _model,
      selectionId: 'max',
      restorePreserved: false,
    );
    expect(picked.selectionId, 'max');
    runtime.stop();

    // Process 2: restart before the models.dev catalog is hydrated (the
    // route is momentarily `unknown`); startup recovery revalidates.
    runtime = _Runtime.start(stateHome.path, catalogHydrated: false);
    final recovered = runtime.sync.revalidateAndApplySession(
      sessionId: sessionId,
      providerInstanceId: _instanceId,
      modelId: _model,
    );
    expect(recovered.selectionId, 'max');
    expect(recovered.corrected, isFalse);
    expect(runtime.sessions.getSession(sessionId)?.thinkingMode, 'max');
    expect(runtime.store.readCorrection(sessionId), isNull);
    runtime.stop();

    // Process 3: restart with the catalog hydrated; the fresh descriptor's
    // revision differs from the cached one.
    runtime = _Runtime.start(stateHome.path, catalogHydrated: true);
    final again = runtime.sync.revalidateAndApplySession(
      sessionId: sessionId,
      providerInstanceId: _instanceId,
      modelId: _model,
    );
    expect(again.selectionId, 'max');
    expect(runtime.sessions.getSession(sessionId)?.thinkingMode, 'max');

    // The reloaded Client carries the stored pick (a carried value): it is
    // admitted unchanged and dispatched as `reasoning_effort: max`.
    final carried = runtime.sync.revalidateCarriedTurnSelection(
      AgentTurnRequest(
        sessionId: sessionId,
        message: 'next',
        providerInstanceId: _instanceId,
        model: _model,
        thinkingMode: 'max',
      ),
      persistedSelection: runtime.sessions.getSession(sessionId)?.thinkingMode,
      sessionProviderInstanceId: _instanceId,
      sessionModelId: _model,
    );
    expect(carried.thinkingMode, 'max');
    // A turn sent without a value restores the stored pick, not a default.
    final restored = runtime.sync.revalidateTurnRequest(
      AgentTurnRequest(
        sessionId: sessionId,
        message: 'next',
        providerInstanceId: _instanceId,
        model: _model,
      ),
    );
    expect(restored.thinkingMode, 'max');
    final dispatched = runtime.resolver.resolve(
      providerInstanceId: _instanceId,
      modelId: _model,
      selectionId: restored.thinkingMode,
    );
    expect(dispatched.directive, isA<OpenAiEffortDirective>());
    expect((dispatched.directive as OpenAiEffortDirective).effort, 'max');
    expect(runtime.sessions.getSession(sessionId)?.thinkingMode, 'max');
    runtime.stop();
  });
}
