import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_revalidator.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_turn_executor.dart';
import 'package:test/test.dart';

/// The real resolver, with a one-shot test seam that runs immediately before a
/// turn is evaluated so a durable ownership handoff can be simulated mid-turn.
class _HandoffResolver implements ThinkingSelectionResolver {
  _HandoffResolver(this._delegate);

  final ThinkingSelectionResolver _delegate;

  static void Function()? onBeforeResolve;

  @override
  ThinkingSelectionResolution resolve({
    required String providerInstanceId,
    required String modelId,
    required String? selectionId,
  }) {
    final hook = onBeforeResolve;
    onBeforeResolve = null;
    hook?.call();
    return _delegate.resolve(
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      selectionId: selectionId,
    );
  }
}

/// Lifecycle regressions for a typed thinking-selection rejection raised during
/// turn admission.
///
/// Terminal delivery requires a successful durable terminal commit for the exact
/// owner, so the rejection may only cancel the durable work item its own run
/// owns. A stale loser whose ownership already moved must stay silent rather
/// than cancel, clear, or answer for the newer owner.
void main() {
  const rejectedProviderId = 'inst-unsupported-thinking';
  const rejectedModelId = 'gpt-unsupported';
  const seededInFlight = {'in_flight_seed': 'owned-by-current-owner'};

  late Directory tempHomeDir;
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository runtime;
  late ProviderInstanceRepository providerRepo;
  late SessionManager sessions;
  late BaseOpenAIAdapter adapter;
  late List<Map<String, dynamic>> outgoingRequests;
  late String sessionId;

  /// Observes the executor's completion callback, which is the sole input to
  /// `SessionRunOrchestrator`'s per-turn closure that removes `_busySessions`
  /// and drains the next queued event.
  var turnCompletedCount = 0;

  BaseOpenAIAdapter buildAdapter() => BaseOpenAIAdapter(
    GetIt.I<Config>(),
    ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
    providerInstanceId: rejectedProviderId,
    defaultModelOverride: rejectedModelId,
    apiKeyOverride: 'test-api-key',
    baseUrlOverride: 'http://127.0.0.1:8088/v1',
    requestClientFactory: () => MockClient((request) async {
      outgoingRequests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        '{"choices":[{"message":{"role":"assistant","content":"unexpected"},'
        '"finish_reason":"stop"}]}',
        200,
      );
    }),
  );

  /// Runs one rejected turn and returns every emitted response, so each
  /// scenario states its own delivery expectation (an applied rejection
  /// answers once; a stale loser answers nothing).
  Future<List<GatewayResponse>> runRejectionTurn({
    required String? workItemId,
    bool withPersistedState = true,
  }) async {
    final emittedResponses = <GatewayResponse>[];
    final executor = SessionTurnExecutor(
      emitResponse: emittedResponses.add,
      getPersistedState: () => withPersistedState ? runtime : null,
    );
    final turnRequest = AgentTurnRequest(
      sessionId: sessionId,
      requestId: 'req-rejected-1',
      message: 'Rejected thinking selection',
      providerInstanceId: rejectedProviderId,
      model: rejectedModelId,
      thinkingMode: 'deep',
    );
    final event = GatewayEvent(
      platformId: 'test-platform',
      sessionId: sessionId,
      message: Message(
        role: MessageRole.user,
        content: 'Rejected thinking selection',
      ),
      turnRequest: turnRequest,
    );

    await executor.runTurn(
      event: event,
      turnRequest: turnRequest,
      agentRunner: AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: sessionId,
      ),
      workItemId: workItemId,
      onRecoveryRequired: (_, _, _, _) {},
      onTurnComplete: () async {
        turnCompletedCount += 1;
      },
    );

    return emittedResponses;
  }

  void admit({
    required String workItemId,
    required String requestId,
  }) {
    runtime.admitWorkItem(
      workItemId: workItemId,
      sessionId: sessionId,
      requestId: requestId,
      providerInstanceId: rejectedProviderId,
      modelId: rejectedModelId,
      payload: {'message': requestId},
    );
  }

  setUp(() async {
    await GetIt.I.reset();
    SessionManager.resetForTesting();
    _HandoffResolver.onBeforeResolve = null;

    tempHomeDir = Directory.systemTemp.createTempSync('thinking_rejection_');
    Directory('${tempHomeDir.path}/memories').createSync(recursive: true);
    File('${tempHomeDir.path}/config.yaml').writeAsStringSync(
      'model_capabilities: {}\n',
    );
    setSanadHomeOverride(tempHomeDir.path);

    state = AgentStateDatabase.inMemory();
    runtime = PersistedRuntimeStateRepository.fromState(state);
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(runtime);

    sessions = SessionManager();
    GetIt.I.registerSingleton<SessionManager>(sessions);

    final config = Config(environment: {'SANAD_HOME': tempHomeDir.path});
    GetIt.I.registerSingleton<Config>(config);

    providerRepo = ProviderInstanceRepository.fromDatabase(state.db);
    GetIt.I.registerSingleton<ProviderInstanceRepository>(providerRepo);

    final thinkingRegistry = buildProviderThinkingRegistry();
    final selectionResolver = ThinkingSelectionResolver(
      instances: providerRepo,
      cacheResolver: ThinkingControlCacheResolver(providerRepo),
      assembler: ThinkingCapabilityAssembler(thinkingRegistry),
      registry: thinkingRegistry,
    );
    final resolver = _HandoffResolver(selectionResolver);
    final preferenceStore = ThinkingRoutePreferenceStore(sessions);
    GetIt.I.registerSingleton<ThinkingSelectionResolver>(resolver);
    GetIt.I.registerSingleton<ThinkingRoutePreferenceStore>(preferenceStore);
    GetIt.I.registerSingleton<ThinkingRouteRevalidator>(
      ThinkingRouteRevalidator(resolver: resolver, store: preferenceStore),
    );

    final workspaceRuntimeService = LocalWorkspaceRuntimeService(
      sanadHomePath: tempHomeDir.path,
    );
    GetIt.I.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(
        workspaceRuntimeService,
        LocalRuntimeCatalog(workspaceRuntimeService: workspaceRuntimeService),
      ),
    );

    providerRepo.createInstance(
      ProviderInstance(
        id: rejectedProviderId,
        templateId: kCustomProviderTemplateId,
        displayName: 'Unsupported Thinking',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'http://127.0.0.1:8088/v1',
        defaultModel: rejectedModelId,
        status: InstanceStatus.ready,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    providerRepo.upsertModelCache(
      instanceId: rejectedProviderId,
      cacheKey: 'models',
      models: [
        {
          'value': rejectedModelId,
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': '1:1:unknown:$rejectedModelId',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    outgoingRequests = [];
    turnCompletedCount = 0;
    adapter = buildAdapter();

    sessionId = sessions
        .createSession(rejectedModelId, providerId: rejectedProviderId)
        .sessionId;
  });

  tearDown(() async {
    _HandoffResolver.onBeforeResolve = null;
    await GetIt.I.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempHomeDir.existsSync()) {
      tempHomeDir.deleteSync(recursive: true);
    }
  });

  test(
    'G3: an expected pre-dispatch rejection is not logged as SEVERE and '
    'carries no stack trace',
    () async {
      admit(workItemId: 'work-rejected-log', requestId: 'req-rejected-1');
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      try {
        final responses = await runRejectionTurn(
          workItemId: 'work-rejected-log',
        );
        expect(responses.single.message.metadata?['error_code'], isNotNull);
      } finally {
        await sub.cancel();
        Logger.root.level = previousLevel;
      }
      final executorRecords = records
          .where((r) => r.loggerName == 'SessionTurnExecutor')
          .toList();
      expect(
        executorRecords.where((r) => r.level >= Level.SEVERE),
        isEmpty,
        reason: executorRecords.map((r) => '${r.level} ${r.message}').join('\n'),
      );
      expect(executorRecords.where((r) => r.stackTrace != null), isEmpty);
      expect(
        executorRecords.any(
          (r) => r.message.contains(
            ThinkingSelectionErrorCode.capabilityUnsupported,
          ),
        ),
        isTrue,
        reason: 'the rejection is still recorded with its code',
      );
    },
  );

  test(
    'owned rejection terminalizes its durable item, delivers once, and never strands it',
    () async {
      // Production admission: the first accepted message becomes the durable
      // active owner and the second identical request queues behind it.
      admit(workItemId: 'work-rejected-1', requestId: 'req-rejected-1');
      admit(workItemId: 'work-queued-unrelated', requestId: 'req-unrelated-2');
      expect(
        runtime.findWorkItem('work-rejected-1')!.state,
        SessionWorkState.running,
      );
      expect(
        runtime.findWorkItem('work-queued-unrelated')!.state,
        SessionWorkState.queued,
      );
      sessions.saveInFlightSnapshot(sessionId, {...seededInFlight});

      final responses = await runRejectionTurn(workItemId: 'work-rejected-1');

      expect(responses, hasLength(1));
      final response = responses.single;
      expect(response.isComplete, isTrue);
      expect(response.message.metadata?['thinking_selection_error'], isTrue);
      expect(
        response.message.metadata?['error_code'],
        ThinkingSelectionErrorCode.capabilityUnsupported,
      );
      expect(response.runId, isNotEmpty);

      // The rejected request never reached the provider.
      expect(outgoingRequests, isEmpty);

      // Only the rejected durable owner is terminalized.
      expect(
        runtime.findWorkItem('work-rejected-1')!.state,
        SessionWorkState.cancelled,
      );
      // Unrelated queued work survives and remains drainable.
      expect(
        runtime.findWorkItem('work-queued-unrelated')!.state,
        SessionWorkState.queued,
      );
      expect(
        runtime
            .findRestorableWorkItems(sessionId)
            .map((item) => item.workItemId),
        ['work-queued-unrelated'],
      );
      expect(
        runtime.findActiveWorkItem(sessionId),
        isNull,
        reason: 'A cancelled rejection must not remain the active owner',
      );
      expect(
        sessions.getInFlightSnapshot(sessionId),
        isNull,
        reason: 'An applied terminal rejection clears the in-flight snapshot',
      );
      expect(
        turnCompletedCount,
        1,
        reason: 'An owned rejection still completes its turn exactly once',
      );
    },
  );

  test(
    'stale rejection for a non-owner work item preserves the newer owner, its in-flight state, and queued work',
    () async {
      admit(workItemId: 'work-stale-loser', requestId: 'req-rejected-1');
      admit(workItemId: 'work-newer-owner', requestId: 'req-newer-2');
      admit(workItemId: 'work-queued-behind', requestId: 'req-behind-3');
      sessions.saveInFlightSnapshot(sessionId, {...seededInFlight});

      // Mid-turn durable handoff in production order: a Stop releases the run's
      // own work item, the queue drain promotes the next queued request, and that
      // newer owner binds its own run/generation.
      _HandoffResolver.onBeforeResolve = () {
        runtime.cancelWorkItems(sessionId, ['work-stale-loser']);
        final promoted = runtime.claimNextQueuedWorkItem(
          sessionId,
          toState: SessionWorkState.running,
        );
        expect(promoted?.workItemId, 'work-newer-owner');
        expect(
          runtime.bindRunOwnership(
            sessionId: sessionId,
            workItemId: 'work-newer-owner',
            runId: 'run-newer-2',
            generation: 7,
          ),
          isTrue,
        );
      };

      final responses = await runRejectionTurn(workItemId: 'work-stale-loser');

      // A stale loser owns no durable item any more, so it must not answer.
      expect(
        responses,
        isEmpty,
        reason: 'A stale rejection must not deliver a terminal response',
      );
      expect(outgoingRequests, isEmpty);

      // The newer durable owner is untouched, including its bound identity.
      final newerOwner = runtime.findWorkItem('work-newer-owner')!;
      expect(newerOwner.state, SessionWorkState.running);
      expect(newerOwner.continuationMetadata['owner_run_id'], 'run-newer-2');
      expect(newerOwner.continuationMetadata['owner_generation'], 7);
      expect(runtime.findActiveWorkItem(sessionId)!.workItemId, 'work-newer-owner');

      // Unrelated queued work is neither claimed, cancelled, nor erased.
      expect(
        runtime.findWorkItem('work-queued-behind')!.state,
        SessionWorkState.queued,
      );
      expect(
        runtime
            .findRestorableWorkItems(sessionId)
            .map((item) => item.workItemId),
        ['work-newer-owner', 'work-queued-behind'],
      );
      // The stale loser stays terminal; it is not resurrected by its own late
      // rejection.
      expect(
        runtime.findWorkItem('work-stale-loser')!.state,
        SessionWorkState.cancelled,
      );
      // The newer owner's in-flight snapshot is preserved, not cleared.
      expect(sessions.getInFlightSnapshot(sessionId), seededInFlight);
      expect(runtime.findAllWorkItems(sessionId), hasLength(3));
      expect(
        turnCompletedCount,
        0,
        reason:
            'A stale loser must not signal completion, so the newer owner keeps '
            'busy ownership and the queue is never drained by it',
      );
    },
  );

  test(
    'rejection without durable work keeps its in-memory answer and clears only its own in-flight state',
    () async {
      // A turn has no durable work item when the queue coordinator cannot insert
      // one (`SessionQueueCoordinator._insertDurableWorkItem` returns null
      // without persisted state) and the orchestrator forwards
      // `liveWorkItem?.workItemId`, so this compatibility path is reachable in
      // production and must keep answering.
      sessions.saveInFlightSnapshot(sessionId, {...seededInFlight});

      final nullIdResponses = await runRejectionTurn(
        workItemId: null,
        withPersistedState: false,
      );
      expect(nullIdResponses, hasLength(1));
      expect(
        nullIdResponses.single.message.metadata?['error_code'],
        ThinkingSelectionErrorCode.capabilityUnsupported,
      );
      expect(sessions.getInFlightSnapshot(sessionId), isNull);
      expect(outgoingRequests, isEmpty);

      // The same holds for a non-null identity with no durable store to commit.
      sessions.saveInFlightSnapshot(sessionId, {...seededInFlight});
      final nonNullIdResponses = await runRejectionTurn(
        workItemId: 'work-without-store',
        withPersistedState: false,
      );
      expect(nonNullIdResponses, hasLength(1));
      expect(sessions.getInFlightSnapshot(sessionId), isNull);
      expect(runtime.findAllWorkItems(sessionId), isEmpty);
      expect(
        turnCompletedCount,
        2,
        reason: 'Both durable-free rejections still complete their turns',
      );
    },
  );
}
