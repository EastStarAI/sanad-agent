import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

import 'interfaces_test.mocks.dart';

/// Lightweight fake platform that records every delivered response. Avoids
/// Mockito `throwOnMissingStub` churn for the descriptor getter.
class _FakePlatform implements BasePlatform {
  @override
  final String platformId;
  @override
  final PlatformDescriptor descriptor;
  @override
  final bool shouldReceiveUserEcho;

  final delivered = <GatewayResponse>[];
  final _controller = StreamController<GatewayEvent>.broadcast();

  _FakePlatform({
    required this.platformId,
    required this.descriptor,
    this.shouldReceiveUserEcho = false,
  });

  @override
  bool get receivesMirroredResponses => false;

  @override
  Stream<GatewayEvent> get eventStream => _controller.stream;

  void emit(GatewayEvent e) => _controller.add(e);

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    delivered.add(response);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async => _controller.close();

  bool got(GatewayResponse r) => delivered.any((d) => d.eventId == r.eventId);
}

void main() {
  late GatewayManager gatewayManager;
  late MockAgentRunner mockAgentRunner;
  late MockSessionManager mockSessionManager;

  setUp(() {
    getIt.allowReassignment = true;
    gatewayManager = GatewayManager();
    mockAgentRunner = MockAgentRunner();
    mockSessionManager = MockSessionManager();

    when(mockAgentRunner.accumulatedUsage).thenReturn({
      'prompt_tokens': 0,
      'completion_tokens': 0,
      'total_tokens': 0,
    });
    when(mockAgentRunner.lastUsage).thenReturn({
      'prompt_tokens': 0,
      'completion_tokens': 0,
      'total_tokens': 0,
    });
    when(mockAgentRunner.runtimeMs).thenReturn(100);
    when(mockAgentRunner.activeModel).thenReturn('mock/gpt');
    when(mockAgentRunner.activeModelDisplay).thenReturn('Mock');
    when(mockAgentRunner.activeProvider).thenReturn('mock');
    when(mockAgentRunner.currentModelStepId).thenReturn('step-1');
    when(mockAgentRunner.getContextTokens()).thenAnswer((_) async => 4000);
    when(
      mockAgentRunner.attachMetadataToLastAssistantMessage(any),
    ).thenReturn(null);
    when(mockAgentRunner.registry).thenReturn(ToolsRegistry());
    when(mockAgentRunner.requestStop()).thenReturn(null);
    when(mockAgentRunner.beginAuthoritativeRun(any)).thenReturn(null);
    when(mockAgentRunner.endAuthoritativeRun(any)).thenReturn(null);
    when(
      mockAgentRunner.attachCancellationScope(
        argThat(isA<RunCancellationScope>()),
      ),
    ).thenReturn(null);
    when(
      mockAgentRunner.detachCancellationScope(
        argThat(isA<RunCancellationScope>()),
      ),
    ).thenReturn(null);
    when(mockAgentRunner.canPublishRunEvents).thenReturn(true);

    final mockSessionDb = MockSessionDB();
    when(mockSessionManager.db).thenReturn(mockSessionDb);
    when(mockSessionDb.saveSession(any)).thenReturn(null);
    when(mockSessionDb.getStoredWorkspaces()).thenReturn(const []);
    when(mockSessionManager.getSession(any)).thenAnswer((inv) {
      final id = inv.positionalArguments[0] as String;
      return SessionState(
        sessionId: id,
        model: 'sanad-agent',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    });
    when(mockSessionManager.getMessages(any)).thenReturn(const []);
    when(mockSessionManager.saveSessionMetadata(any, any)).thenReturn(null);
    when(mockSessionManager.getSessionMetadata(any)).thenReturn(null);
    when(mockSessionManager.getInFlightSnapshot(any)).thenReturn(null);
    when(mockSessionManager.saveInFlightSnapshot(any, any)).thenReturn(null);
    when(mockSessionManager.clearInFlightSnapshot(any)).thenReturn(null);
    when(mockSessionManager.updateSessionTitle(any, any)).thenReturn(null);
    when(
      mockSessionManager.updateSessionTitleIfCurrent(
        any,
        expectedTitle: anyNamed('expectedTitle'),
        title: anyNamed('title'),
      ),
    ).thenReturn(true);

    final mockTitleService = MockTitleService();
    when(
      mockTitleService.generateTitle(
        sessionId: anyNamed('sessionId'),
        userMessage: anyNamed('userMessage'),
        assistantResponse: anyNamed('assistantResponse'),
        modelOverride: anyNamed('modelOverride'),
      ),
    ).thenAnswer((_) async => 'Title');

    getIt.registerSingleton<SessionManager>(mockSessionManager);
    getIt.registerSingleton<TitleService>(mockTitleService);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      LocalWorkspaceRuntimeService(
        sanadHomePath: '/tmp/sanad-test',
        currentWorkingDirectory: '/tmp/sanad-test',
      ),
    );
    getIt.registerSingleton<LocalRuntimeCatalog>(
      LocalRuntimeCatalog(
        workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      ),
    );
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(
        getIt<LocalWorkspaceRuntimeService>(),
        getIt<LocalRuntimeCatalog>(),
      ),
    );
    getIt.registerSingleton<SessionRunOrchestrator>(SessionRunOrchestrator());
    final stateDb = AgentStateDatabase.inMemory();
    final repo = ProviderInstanceRepository.fromDatabase(stateDb.db);
    getIt.registerSingleton<AgentStateDatabase>(stateDb);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<ProviderRateLimiter>(ProviderRateLimiter());
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(repo, getIt<ProviderRateLimiter>()),
    );
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (sessionId, _) => mockAgentRunner,
    );
  });

  Future<void> pump() => Future.delayed(const Duration(milliseconds: 300));

  test(
    'execution state change keeps one event id across sanad_client fan-out',
    () async {
      getIt.registerSingleton<PersistedRuntimeStateRepository>(
        PersistedRuntimeStateRepository.fromState(getIt<AgentStateDatabase>()),
      );
      addTearDown(() async {
        if (getIt.isRegistered<PersistedRuntimeStateRepository>()) {
          await getIt.unregister<PersistedRuntimeStateRepository>();
        }
      });
      final local = _FakePlatform(
        platformId: 'local_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.local,
        ),
      );
      final cloud = _FakePlatform(
        platformId: 'sanad_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.cloud,
        ),
      );
      gatewayManager.registerPlatform(local);
      gatewayManager.registerPlatform(cloud);
      await gatewayManager.start();

      final state = getIt<AgentStateDatabase>();
      state.db.execute(
        '''
        INSERT INTO sessions (session_id, model, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ''',
        ['execution-session', 'model-a', '2026-07-15', '2026-07-15'],
      );
      getIt<PersistedRuntimeStateRepository>().executionState.enqueueWorkItem(
        workItemId: 'execution-work',
        sessionId: 'execution-session',
        requestId: 'execution-request',
      );
      await pump();

      GatewayResponse executionEvent(_FakePlatform platform) =>
          platform.delivered.singleWhere(
            (response) =>
                response.message.metadata?['canonical_event_type'] ==
                'session.execution_state_changed',
          );
      final localEvent = executionEvent(local);
      final cloudEvent = executionEvent(cloud);
      expect(localEvent.eventId, cloudEvent.eventId);
      expect(localEvent.delivery.scope, DeliveryScope.platformFamily);
      expect(localEvent.delivery.platformFamily, PlatformFamily.sanadClient);
      expect(
        localEvent.message.metadata?['canonical_payload'],
        cloudEvent.message.metadata?['canonical_payload'],
      );
      await gatewayManager.stop();
    },
  );

  test(
    'auto-failover route keeps its durable event id across sanad_client fan-out',
    () async {
      final state = getIt<AgentStateDatabase>();
      final persisted = PersistedRuntimeStateRepository.fromState(state);
      final transitions = SessionRouteTransitionRepository(state);
      final routeCoordinator = SessionRouteMutationCoordinator(
        state: state,
        workItems: persisted.workItems,
        transitions: transitions,
        providerInstances: getIt<ProviderInstanceRepository>(),
      );
      getIt.registerSingleton<PersistedRuntimeStateRepository>(persisted);
      getIt.registerSingleton<SessionRouteMutationCoordinator>(
        routeCoordinator,
      );
      addTearDown(() async {
        if (getIt.isRegistered<SessionRouteMutationCoordinator>()) {
          await getIt.unregister<SessionRouteMutationCoordinator>();
        }
        if (getIt.isRegistered<PersistedRuntimeStateRepository>()) {
          await getIt.unregister<PersistedRuntimeStateRepository>();
        }
      });
      final local = _FakePlatform(
        platformId: 'local_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.local,
        ),
      );
      final cloud = _FakePlatform(
        platformId: 'sanad_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.cloud,
        ),
      );
      gatewayManager.registerPlatform(local);
      gatewayManager.registerPlatform(cloud);
      await gatewayManager.start();
      state.db.execute(
        '''
        INSERT INTO sessions (
          session_id, model, provider_id, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?)
        ''',
        ['route-session', 'model-a', 'provider-a', '2026-07-15', '2026-07-15'],
      );

      final route = routeCoordinator.mutate(
        sessionId: 'route-session',
        providerInstanceId: 'provider-b',
        model: 'model-a',
        source: SessionRouteSource.autoFailover,
        reason: 'rate_limit',
        publish: true,
      );
      await pump();

      GatewayResponse routeEvent(_FakePlatform platform) =>
          platform.delivered.singleWhere(
            (response) =>
                response.message.metadata?['canonical_event_type'] ==
                'session_preferences_updated',
          );
      final localEvent = routeEvent(local);
      final cloudEvent = routeEvent(cloud);
      expect(localEvent.eventId, route.eventId);
      expect(cloudEvent.eventId, route.eventId);
      expect(
        transitions
            .findByRevision('route-session', route.routeRevision)
            ?.eventId,
        route.eventId,
      );
      expect(localEvent.delivery.platformFamily, PlatformFamily.sanadClient);
      expect(
        localEvent.message.metadata?['canonical_payload'],
        cloudEvent.message.metadata?['canonical_payload'],
      );
      await gatewayManager.stop();
    },
  );

  test(
    'platform_family=sanad_client from local origin reaches local AND cloud',
    () async {
      final local = _FakePlatform(
        platformId: 'local_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.local,
        ),
        shouldReceiveUserEcho: true,
      );
      final cloud = _FakePlatform(
        platformId: 'sanad_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.cloud,
        ),
        shouldReceiveUserEcho: true,
      );
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          receivedAt: anyNamed('receivedAt'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['answer']));

      gatewayManager.registerPlatform(local);
      gatewayManager.registerPlatform(cloud);
      await gatewayManager.start();

      local.emit(
        GatewayEvent(
          sessionId: 's1',
          platformId: 'local_gateway',
          message: Message(role: MessageRole.user, content: 'hi'),
        ),
      );
      await pump();

      final localFinals = local.delivered.where(
        (r) =>
            r.message.role != MessageRole.user && r.message.content == 'answer',
      );
      final cloudFinals = cloud.delivered.where(
        (r) =>
            r.message.role != MessageRole.user && r.message.content == 'answer',
      );
      expect(
        localFinals,
        isNotEmpty,
        reason: 'local must receive its own final',
      );
      expect(cloudFinals, isNotEmpty, reason: 'cloud must mirror the final');
      await gatewayManager.stop();
    },
  );

  test(
    'platform_family=sanad_client from cloud origin reaches cloud AND local',
    () async {
      final local = _FakePlatform(
        platformId: 'local_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.local,
        ),
        shouldReceiveUserEcho: true,
      );
      final cloud = _FakePlatform(
        platformId: 'sanad_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.cloud,
        ),
        shouldReceiveUserEcho: true,
      );
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          receivedAt: anyNamed('receivedAt'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['answer']));

      gatewayManager.registerPlatform(local);
      gatewayManager.registerPlatform(cloud);
      await gatewayManager.start();

      cloud.emit(
        GatewayEvent(
          sessionId: 's2',
          platformId: 'sanad_gateway',
          message: Message(role: MessageRole.user, content: 'hi'),
        ),
      );
      await pump();

      expect(
        local.delivered.any((r) => r.message.content == 'answer'),
        isTrue,
        reason: 'local must mirror cloud-origin final',
      );
      expect(
        cloud.delivered.any((r) => r.message.content == 'answer'),
        isTrue,
        reason: 'cloud must receive its own final',
      );
      await gatewayManager.stop();
    },
  );

  test(
    'runtime stop broadcasts stopped and session.runtime_notice_cleared to every sanad_client platform',
    () async {
      final local = _FakePlatform(
        platformId: 'local_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.local,
        ),
        shouldReceiveUserEcho: true,
      );
      final cloud = _FakePlatform(
        platformId: 'sanad_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.cloud,
        ),
        shouldReceiveUserEcho: true,
      );
      final completer = Completer<String>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          receivedAt: anyNamed('receivedAt'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromFuture(completer.future));

      gatewayManager.registerPlatform(local);
      gatewayManager.registerPlatform(cloud);
      await gatewayManager.start();

      local.emit(
        GatewayEvent(
          sessionId: 'stop-session',
          platformId: 'local_gateway',
          message: Message(role: MessageRole.user, content: 'run first'),
        ),
      );
      await pump();

      getIt<RuntimeRecoveryService>().reportRateLimitWait(
        sessionId: 'stop-session',
        providerInstanceId: 'prov-1',
        retryAfter: const Duration(seconds: 30),
      );
      await pump();

      local.emit(
        GatewayEvent(
          sessionId: 'stop-session',
          platformId: 'local_gateway',
          type: 'stop',
          message: Message(role: MessageRole.user, content: ''),
        ),
      );
      await pump();

      for (final platform in [local, cloud]) {
        final eventTypes = platform.delivered
            .map((r) => r.message.metadata?['canonical_event_type']?.toString())
            .whereType<String>()
            .toList();
        expect(
          eventTypes.where(
            (event) => event == 'session.runtime_notice_cleared',
          ),
          hasLength(1),
        );
        expect(eventTypes.where((event) => event == 'stopped'), hasLength(1));
      }

      await gatewayManager.stop();
    },
  );

  test(
    'a new platform family requires no new GatewayManager branch (telegram adapter)',
    () async {
      final telegram = _FakePlatform(
        platformId: 'telegram-bot',
        descriptor: const PlatformDescriptor(
          platformFamily: PlatformFamily.telegram,
          transport: PlatformTransport.telegramApi,
        ),
        shouldReceiveUserEcho: true,
      );
      final local = _FakePlatform(
        platformId: 'local_gateway',
        descriptor: const PlatformDescriptor.sanadClient(
          transport: PlatformTransport.local,
        ),
        shouldReceiveUserEcho: true,
      );
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          receivedAt: anyNamed('receivedAt'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['reply']));

      gatewayManager.registerPlatform(telegram);
      gatewayManager.registerPlatform(local);
      await gatewayManager.start();

      telegram.emit(
        GatewayEvent(
          sessionId: 's-tg',
          platformId: 'telegram-bot',
          message: Message(role: MessageRole.user, content: 'hi'),
          turnRequest: AgentTurnRequest(sessionId: 's-tg', message: 'hi'),
        ),
      );
      await pump();

      // Telegram origin receives its own response (it is the origin AND in
      // the sanad_client delivery family default). The sanad_client local
      // platform must NOT receive the telegram-originated timeline because
      // the default family is sanad_client and telegram is not sanad_client.
      //
      // NOTE: the orchestrator default delivery is platform_family=sanad_client,
      // so a telegram-origin event fans out to sanad_client platforms only,
      // NOT back to telegram. This verifies the isolation rule: external
      // families do not receive sanad_client-family broadcasts.
      expect(
        local.delivered.any((r) => r.message.content == 'reply'),
        isTrue,
        reason: 'sanad_client family receives the canonical timeline',
      );
      expect(
        telegram.delivered.any((r) => r.message.content == 'reply'),
        isFalse,
        reason: 'telegram family is isolated from sanad_client broadcasts',
      );
      await gatewayManager.stop();
    },
  );
}

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  _NoopMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async {
    return const [];
  }
}
