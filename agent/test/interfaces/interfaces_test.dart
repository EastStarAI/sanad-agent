import 'dart:io';

import 'dart:async';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/runtime/llm_route_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:get_it/get_it.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';

import 'interfaces_test.mocks.dart';

class _TitleRouteAdapter implements LLMAdapter {
  const _TitleRouteAdapter();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@GenerateMocks([
  BasePlatform,
  AgentRunner,
  SessionManager,
  SessionDB,
  TitleService,
])
void main() {
  late GatewayManager gatewayManager;
  late MockBasePlatform mockPlatform;
  late MockBasePlatform mirrorPlatform;
  late MockAgentRunner mockAgentRunner;
  late MockSessionManager mockSessionManager;
  late MockSessionDB mockSessionDb;
  late LLMAdapter titleRouteAdapter;
  late LLMRouteSnapshot completedTurnRoute;
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('interfaces-runtime-test');
    Directory(
      '${tempDir.path}/.sanad/skills/review',
    ).createSync(recursive: true);
    File(
      '${tempDir.path}/AGENTS.md',
    ).writeAsStringSync('Interface test instructions.');
    File('${tempDir.path}/.sanad/skills/review/SKILL.md').writeAsStringSync(
      '''---
name: review
description: Review the workspace.
---
Use the review skill.''',
    );

    // We don't reset GetIt to avoid losing other registrations if they exist,
    // but we allow reassignment to put our mocks.
    getIt.allowReassignment = true;

    gatewayManager = GatewayManager();
    mockPlatform = MockBasePlatform();
    mirrorPlatform = MockBasePlatform();
    mockAgentRunner = MockAgentRunner();
    titleRouteAdapter = const _TitleRouteAdapter();
    mockSessionManager = MockSessionManager();

    // Mock platform ID
    when(mockPlatform.platformId).thenReturn('test-platform');
    when(mockPlatform.receivesMirroredResponses).thenReturn(false);
    when(mockPlatform.shouldReceiveUserEcho).thenReturn(false);
    when(mockPlatform.descriptor).thenReturn(
      const PlatformDescriptor.sanadClient(
        transport: PlatformTransport.local,
        platformInstanceId: 'test-platform',
      ),
    );
    when(mirrorPlatform.platformId).thenReturn('mirror-platform');
    when(mirrorPlatform.receivesMirroredResponses).thenReturn(true);
    when(mirrorPlatform.shouldReceiveUserEcho).thenReturn(false);
    when(mirrorPlatform.descriptor).thenReturn(
      const PlatformDescriptor.sanadClient(
        transport: PlatformTransport.cloud,
        platformInstanceId: 'mirror-platform',
      ),
    );

    // Stub the new metrics getters on the mock AgentRunner
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
    when(mockAgentRunner.activeModel).thenReturn('mock/gpt-3.5-turbo');
    when(mockAgentRunner.activeModelDisplay).thenReturn('Mock GPT-3.5 Turbo');
    when(mockAgentRunner.activeProvider).thenReturn('mock');
    when(mockAgentRunner.adapter).thenReturn(titleRouteAdapter);
    completedTurnRoute = LLMRouteSnapshot(
      adapter: mockAgentRunner.adapter,
      providerInstanceId: 'mock-provider-instance',
      modelOverride: 'mock/gpt-3.5-turbo',
    );
    when(mockAgentRunner.lastSuccessfulLlmRoute).thenReturn(completedTurnRoute);
    when(mockAgentRunner.currentModelStepId).thenReturn('step-123');
    when(mockAgentRunner.getContextTokens()).thenAnswer((_) async => 4000);
    when(
      mockAgentRunner.getContextUsageSnapshot(),
    ).thenAnswer((_) async => null);
    when(
      mockAgentRunner.attachMetadataToLastAssistantMessage(any),
    ).thenReturn(null);
    when(mockAgentRunner.registry).thenReturn(ToolsRegistry());

    // updateTurnRoute is called by resumeSuspended when a route override is
    // supplied. Default to a no-op so individual tests don't need to stub it.
    when(mockAgentRunner.allowManualAmbiguousToolRecovery()).thenReturn(null);
    when(
      mockAgentRunner.updateTurnRoute(
        providerId: anyNamed('providerId'),
        modelId: anyNamed('modelId'),
      ),
    ).thenReturn(null);
    when(mockAgentRunner.requestStop()).thenReturn(null);
    when(mockAgentRunner.beginAuthoritativeRun(any)).thenReturn(null);
    when(mockAgentRunner.endAuthoritativeRun(any)).thenReturn(null);

    // Stub SessionManager so GatewayManager can persist metrics during tests
    mockSessionDb = MockSessionDB();
    when(mockSessionManager.db).thenReturn(mockSessionDb);
    when(mockSessionDb.saveSession(any)).thenReturn(null);
    final workspacesByPath = <String, Map<String, dynamic>>{};
    when(
      mockSessionDb.getStoredWorkspaces(),
    ).thenAnswer((_) => workspacesByPath.values.toList(growable: false));
    when(mockSessionDb.getWorkspaceById(any)).thenAnswer((invocation) {
      final id = invocation.positionalArguments.first as String;
      return workspacesByPath.values
          .where((workspace) => workspace['id'] == id)
          .firstOrNull;
    });
    when(mockSessionDb.getWorkspaceByPath(any)).thenAnswer((invocation) {
      final path = invocation.positionalArguments.first as String;
      return workspacesByPath[path];
    });
    when(
      mockSessionDb.createOrGetWorkspace(
        id: anyNamed('id'),
        displayName: anyNamed('displayName'),
        path: anyNamed('path'),
        source: anyNamed('source'),
        updatedAt: anyNamed('updatedAt'),
      ),
    ).thenAnswer((invocation) {
      final path = invocation.namedArguments[#path] as String;
      return workspacesByPath.putIfAbsent(
        path,
        () => {
          'id': 'workspace-${path.hashCode}',
          'display_name': path.split(Platform.pathSeparator).last,
          'path': path,
          'source': 'test',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
      );
    });

    // Stub getSession to return an existing session by default
    when(mockSessionManager.getSession(any)).thenAnswer((invocation) {
      final sessionId = invocation.positionalArguments[0] as String;
      return SessionState(
        sessionId: sessionId,
        model: 'sanad-agent',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    });

    when(mockSessionManager.saveSessionMetadata(any, any)).thenReturn(null);
    when(mockSessionManager.getSessionMetadata(any)).thenReturn(null);
    final inFlightSnapshots = <String, Map<String, dynamic>>{};
    when(mockSessionManager.getInFlightSnapshot(any)).thenAnswer((invocation) {
      final sessionId = invocation.positionalArguments.single as String;
      return inFlightSnapshots[sessionId];
    });
    when(mockSessionManager.saveInFlightSnapshot(any, any)).thenAnswer((
      invocation,
    ) {
      final sessionId = invocation.positionalArguments[0] as String;
      final snapshot = Map<String, dynamic>.from(
        invocation.positionalArguments[1] as Map,
      );
      inFlightSnapshots[sessionId] = snapshot;
    });
    when(mockSessionManager.clearInFlightSnapshot(any)).thenAnswer((
      invocation,
    ) {
      final sessionId = invocation.positionalArguments.single as String;
      inFlightSnapshots.remove(sessionId);
    });
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
        route: anyNamed('route'),
      ),
    ).thenAnswer((_) async => 'Intelligent Generated Title');

    getIt.registerSingleton<SessionManager>(mockSessionManager);
    getIt.registerSingleton<TitleService>(mockTitleService);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
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
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (sessionId, _) => mockAgentRunner,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('GatewayManager should register and initialize platforms', () async {
    when(mockPlatform.initialize()).thenAnswer((_) async => {});
    when(mockPlatform.eventStream).thenAnswer((_) => Stream.empty());

    gatewayManager.registerPlatform(mockPlatform);
    await gatewayManager.start();

    verify(mockPlatform.initialize()).called(1);
    verify(mockPlatform.eventStream).called(1);
  });

  test('Sanad gateway platforms opt into authoritative user echoes', () {
    expect(LocalDaemonServerPlatform().shouldReceiveUserEcho, isTrue);
    expect(ServerSanadGatewayPlatform().shouldReceiveUserEcho, isTrue);
  });

  test(
    'GatewayManager should continue starting other platforms when one initialization fails',
    () async {
      when(mockPlatform.initialize()).thenThrow(Exception('bind failed'));
      when(mirrorPlatform.initialize()).thenAnswer((_) async => {});
      when(mirrorPlatform.eventStream).thenAnswer((_) => Stream.empty());

      gatewayManager.registerPlatform(mockPlatform);
      gatewayManager.registerPlatform(mirrorPlatform);
      await gatewayManager.start();

      verify(mockPlatform.initialize()).called(1);
      verify(mirrorPlatform.initialize()).called(1);
      verify(mirrorPlatform.eventStream).called(1);
    },
  );

  test('GatewayManager should route events to AgentRunner', () async {
    final eventController = StreamController<GatewayEvent>();
    when(mockPlatform.initialize()).thenAnswer((_) async => {});
    when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
    when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

    // Mock AgentRunner response
    when(
      mockAgentRunner.streamMessage(
        any,
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        providerId: anyNamed('providerId'),
        model: anyNamed('model'),
        thinkingMode: anyNamed('thinkingMode'),
        receivedAt: anyNamed('receivedAt'),
        onToolEvent: anyNamed('onToolEvent'),
        onSteerContinuation: anyNamed('onSteerContinuation'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).thenAnswer((invocation) {
      final thoughtCallback =
          invocation.namedArguments[#onThoughtDelta] as dynamic;
      final reasoningCallback =
          invocation.namedArguments[#onReasoningDelta] as dynamic;
      thoughtCallback('I will inspect the implementation');
      reasoningCallback('Inspecting implementation');
      return Stream.fromIterable(['Hello', ' world']);
    });

    gatewayManager.registerPlatform(mockPlatform);
    await gatewayManager.start();

    // Fire an event
    final event = GatewayEvent(
      sessionId: 'session-123',
      platformId: 'test-platform',
      message: Message(role: MessageRole.user, content: 'Hi'),
    );
    eventController.add(event);

    // Wait for async processing
    await Future.delayed(Duration(milliseconds: 100));

    verify(
      mockAgentRunner.streamMessage(
        'Hi',
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        providerId: anyNamed('providerId'),
        model: anyNamed('model'),
        thinkingMode: anyNamed('thinkingMode'),
        receivedAt: anyNamed('receivedAt'),
        onToolEvent: anyNamed('onToolEvent'),
        onSteerContinuation: anyNamed('onSteerContinuation'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).called(1);

    verify(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>(
            (r) =>
                r.message.thought == 'I will inspect the implementation' &&
                !r.isComplete,
          ),
        ),
      ),
    ).called(1);
    verify(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>(
            (r) =>
                r.message.reasoning == 'Inspecting implementation' &&
                !r.isComplete,
          ),
        ),
      ),
    ).called(1);

    // Origin platforms without user echo only receive stream chunks and the final assistant answer.
    verifyNever(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>((r) => r.message.role == MessageRole.user),
        ),
      ),
    );
    verify(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>(
            (r) => r.message.content == 'Hello' && !r.isComplete,
          ),
        ),
      ),
    ).called(1);
    verify(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>(
            (r) => r.message.content == ' world' && !r.isComplete,
          ),
        ),
      ),
    ).called(1);
    verify(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>(
            (r) =>
                r.message.role == MessageRole.assistant &&
                r.isComplete &&
                !r.isSessionUpdated &&
                r.message.content == 'Hello world',
          ),
        ),
      ),
    ).called(1);
    final savedSnapshots = verify(
      mockSessionManager.saveInFlightSnapshot('session-123', captureAny),
    ).captured.cast<Map>();
    expect(
      savedSnapshots
          .where((snapshot) => snapshot['type'] == 'thought_stream')
          .map((snapshot) => snapshot['content'])
          .toList()
          .sublist(1),
      ['Hello', 'Hello world'],
    );
    expect(getIt<SessionManager>().getInFlightSnapshot('session-123'), isNull);

    await eventController.close();
  });

  test(
    'late steer emits the completed prior segment before continuation',
    () async {
      final eventController = StreamController<GatewayEvent>();
      final responses = <GatewayResponse>[];
      var currentStep = 'step-before-steer';
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((invocation) async {
        responses.add(invocation.positionalArguments.single as GatewayResponse);
      });
      when(mockAgentRunner.currentModelStepId).thenAnswer((_) => currentStep);
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((invocation) async* {
        final continueSteer =
            invocation.namedArguments[#onSteerContinuation] as void Function();
        yield 'Answer before steer';
        continueSteer();
        currentStep = 'step-after-steer';
        yield 'Adjusted answer';
      });

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();
      eventController.add(
        GatewayEvent(
          sessionId: 'late-steer-session',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Start'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final completedSegmentIndex = responses.indexWhere(
        (response) =>
            response.message.metadata?['canonical_event_type'] == 'thought',
      );
      final continuedChunkIndex = responses.indexWhere(
        (response) =>
            response.message.content == 'Adjusted answer' &&
            !response.isComplete,
      );
      expect(completedSegmentIndex, greaterThanOrEqualTo(0));
      expect(continuedChunkIndex, greaterThan(completedSegmentIndex));
      final completedPayload =
          responses[completedSegmentIndex]
                  .message
                  .metadata?['canonical_payload']
              as Map;
      expect(completedPayload['content'], 'Answer before steer');
      expect(completedPayload['status'], 'done');
      expect(completedPayload['model_step_id'], 'step-before-steer');
      final terminal = responses.lastWhere((response) => response.isComplete);
      expect(terminal.message.content, 'Adjusted answer');

      await eventController.close();
    },
  );

  test(
    'GatewayManager returns authoritative user echoes to opted-in platforms',
    () async {
      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.shouldReceiveUserEcho).thenReturn(true);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['Done']));

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'echo-session',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Hello'),
          turnRequest: AgentTurnRequest(
            sessionId: 'echo-session',
            message: 'Hello',
            requestId: 'request-echo-1',
          ),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 100));

      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (response) =>
                  response.message.role == MessageRole.user &&
                  response.message.content == 'Hello' &&
                  response.message.metadata?['request_id'] == 'request-echo-1',
            ),
          ),
        ),
      ).called(1);

      await eventController.close();
    },
  );

  test('GatewayManager should persist runtime-rich turn metadata', () async {
    final eventController = StreamController<GatewayEvent>();
    when(mockPlatform.initialize()).thenAnswer((_) async => {});
    when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
    when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});
    when(
      mockAgentRunner.streamMessage(
        any,
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        providerId: anyNamed('providerId'),
        model: anyNamed('model'),
        thinkingMode: anyNamed('thinkingMode'),
        receivedAt: anyNamed('receivedAt'),
        onToolEvent: anyNamed('onToolEvent'),
        onSteerContinuation: anyNamed('onSteerContinuation'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).thenAnswer((_) => Stream.fromIterable(['Hello']));

    gatewayManager.registerPlatform(mockPlatform);
    await gatewayManager.start();

    eventController.add(
      GatewayEvent(
        sessionId: 'runtime-session',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi'),
        turnRequest: AgentTurnRequest(
          sessionId: 'runtime-session',
          message: 'Hi',
          workspaceId: '/tmp/workspace',
          model: 'openai/gpt-5',
          thinkingMode: 'deep',
          requestId: 'req-77',
        ),
      ),
    );

    await Future.delayed(Duration(milliseconds: 100));

    verify(
      mockSessionManager.saveSessionMetadata(
        'runtime-session',
        argThat(
          allOf(
            containsPair('workspace_id', '/tmp/workspace'),
            containsPair('model', 'openai/gpt-5'),
            containsPair('thinking_mode', 'deep'),
            containsPair('request_id', 'req-77'),
          ),
        ),
      ),
    ).called(greaterThanOrEqualTo(1));

    await eventController.close();
  });

  test(
    'GatewayManager should build runtime context for each workspace turn',
    () async {
      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['Hello']));

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'runtime-context-session',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Hi'),
          turnRequest: AgentTurnRequest(
            sessionId: 'runtime-context-session',
            message: 'Hi',
            workspaceId: tempDir.path,
          ),
        ),
      );

      await untilCalled(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      );

      final capturedPrompt =
          verify(
                mockAgentRunner.streamMessage(
                  'Hi',
                  runtimeSystemPrompt: captureAnyNamed('runtimeSystemPrompt'),
                  providerId: anyNamed('providerId'),
                  model: anyNamed('model'),
                  thinkingMode: anyNamed('thinkingMode'),
                  receivedAt: anyNamed('receivedAt'),
                  onToolEvent: anyNamed('onToolEvent'),
                  onSteerContinuation: anyNamed('onSteerContinuation'),
                  onThoughtDelta: anyNamed('onThoughtDelta'),
                  onReasoningDelta: anyNamed('onReasoningDelta'),
                ),
              ).captured.single
              as String;

      expect(capturedPrompt, contains('# Runtime context'));
      expect(capturedPrompt, contains('Interface test instructions.'));
      expect(capturedPrompt, contains('name: review'));

      await eventController.close();
    },
  );

  test(
    'GatewayManager should provide concise context without a workspace',
    () async {
      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['Hello']));

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();
      eventController.add(
        GatewayEvent(
          sessionId: 'no-workspace-context-session',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Edit a file'),
          turnRequest: AgentTurnRequest(
            sessionId: 'no-workspace-context-session',
            message: 'Edit a file',
          ),
        ),
      );

      await untilCalled(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      );

      final capturedPrompt =
          verify(
                mockAgentRunner.streamMessage(
                  'Edit a file',
                  runtimeSystemPrompt: captureAnyNamed('runtimeSystemPrompt'),
                  providerId: anyNamed('providerId'),
                  model: anyNamed('model'),
                  thinkingMode: anyNamed('thinkingMode'),
                  receivedAt: anyNamed('receivedAt'),
                  onToolEvent: anyNamed('onToolEvent'),
                  onSteerContinuation: anyNamed('onSteerContinuation'),
                  onThoughtDelta: anyNamed('onThoughtDelta'),
                  onReasoningDelta: anyNamed('onReasoningDelta'),
                ),
              ).captured.single
              as String;
      expect(
        capturedPrompt,
        equals(const RuntimeContextBuilder().buildWithoutWorkspace()),
      );

      await eventController.close();
    },
  );

  test('GatewayManager should handle internet disconnection errors', () async {
    final eventController = StreamController<GatewayEvent>();
    when(mockPlatform.initialize()).thenAnswer((_) async => {});
    when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
    when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

    // Mock AgentRunner to throw an internet error
    when(
      mockAgentRunner.streamMessage(
        any,
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        providerId: anyNamed('providerId'),
        model: anyNamed('model'),
        thinkingMode: anyNamed('thinkingMode'),
        receivedAt: anyNamed('receivedAt'),
        onToolEvent: anyNamed('onToolEvent'),
        onSteerContinuation: anyNamed('onSteerContinuation'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).thenAnswer((_) => Stream.error('Internet connection lost'));

    gatewayManager.registerPlatform(mockPlatform);
    await gatewayManager.start();

    // Fire an event
    final event = GatewayEvent(
      sessionId: 'session-error',
      platformId: 'test-platform',
      message: Message(role: MessageRole.user, content: 'Hi'),
    );
    eventController.add(event);

    // Wait for async processing
    await Future.delayed(Duration(milliseconds: 100));

    // Verify an error response was sent
    verify(
      mockPlatform.sendResponse(
        argThat(
          predicate<GatewayResponse>(
            (r) =>
                r.message.role == MessageRole.assistant &&
                r.message.content!.contains('Error') &&
                r.isComplete,
          ),
        ),
      ),
    ).called(1);

    await eventController.close();
  });

  test(
    'GatewayManager routes platform_family events to same-family platforms and isolates external families',
    () async {
      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});
      // mockPlatform declares an EXTERNAL family (cli) to verify isolation:
      // a sanad_client platform_family event must NOT reach it.
      when(mockPlatform.descriptor).thenReturn(
        const PlatformDescriptor(
          platformFamily: PlatformFamily.cli,
          transport: PlatformTransport.cli,
          platformInstanceId: 'test-platform',
        ),
      );
      when(mirrorPlatform.initialize()).thenAnswer((_) async => {});
      when(mirrorPlatform.eventStream).thenAnswer((_) => Stream.empty());
      when(mirrorPlatform.sendResponse(any)).thenAnswer((_) async => {});
      // mirrorPlatform is sanad_client and opts into user echoes.
      when(mirrorPlatform.shouldReceiveUserEcho).thenReturn(true);

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['Hello']));

      gatewayManager.registerPlatform(mockPlatform);
      gatewayManager.registerPlatform(mirrorPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'session-mirror',
          platformId: 'local_gateway',
          message: Message(role: MessageRole.user, content: 'Hi'),
        ),
      );

      await Future.delayed(Duration(milliseconds: 100));

      // The external-family origin platform receives nothing.
      verifyNever(mockPlatform.sendResponse(any));
      // The sanad_client family receives the user echo and the assistant stream.
      verify(
        mirrorPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.message.role == MessageRole.user &&
                  r.message.content == 'Hi',
            ),
          ),
        ),
      ).called(1);
      verify(
        mirrorPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>((r) => r.message.content == 'Hello'),
          ),
        ),
      ).called(2);

      await eventController.close();
    },
  );

  test(
    'GatewayManager should recover and process next message after an error',
    () async {
      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      // First call fails, second succeeds
      var callCount = 0;
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) {
        callCount++;
        if (callCount == 1) {
          return Stream.error('Internet connection lost');
        }
        return Stream.fromIterable(['Recovered']);
      });

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      // Fire first event (fails)
      eventController.add(
        GatewayEvent(
          sessionId: 'session-recovery',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Hi 1'),
        ),
      );
      await Future.delayed(Duration(milliseconds: 50));

      // Fire second event (succeeds)
      eventController.add(
        GatewayEvent(
          sessionId: 'session-recovery',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Hi 2'),
        ),
      );
      await Future.delayed(Duration(milliseconds: 100));

      // Verify both were handled
      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.message.role == MessageRole.assistant &&
                  r.message.content!.contains('Error'),
            ),
          ),
        ),
      ).called(1);

      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) => r.message.content == 'Recovered' && !r.isComplete,
            ),
          ),
        ),
      ).called(1);

      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.message.role == MessageRole.assistant &&
                  r.message.content == 'Recovered' &&
                  r.isComplete,
            ),
          ),
        ),
      ).called(1);

      await eventController.close();
    },
  );

  test(
    'GatewayManager should dispatch session_created on new session',
    () async {
      final mockSessionManager = getIt<SessionManager>();
      // Override getSession to return null (new session)
      when(mockSessionManager.getSession('new-session')).thenReturn(null);

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['Hello']));

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      // Fire event for a brand new session
      eventController.add(
        GatewayEvent(
          sessionId: 'new-session',
          platformId: 'test-platform',
          message: Message(
            role: MessageRole.user,
            content: 'Create a new feature',
          ),
        ),
      );

      await Future.delayed(Duration(milliseconds: 100));

      // Verify session_created response was sent
      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.sessionId == 'new-session' &&
                  r.isSessionCreated &&
                  r.message.content == 'Create a new feature',
            ),
          ),
        ),
      ).called(1);

      await eventController.close();
    },
  );

  test(
    'GatewayManager should preserve the requested title when handling create_session',
    () async {
      when(mockSessionManager.getSession('new-thread')).thenReturn(null);

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'new-thread',
          platformId: 'test-platform',
          type: 'create_session',
          message: Message(role: MessageRole.user, content: ''),
          metadata: {
            'payload': {
              'title': 'مرحبا كيف الحال',
              'request_id': 'req-create-thread',
            },
          },
          runId: 'req-create-thread',
        ),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final savedSession =
          verify(mockSessionDb.saveSession(captureAny)).captured.single
              as SessionState;
      expect(savedSession.title, 'مرحبا كيف الحال');
      expect(savedSession.titleStatus, SessionTitleStatus.finalized);

      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.sessionId == 'new-thread' &&
                  r.isSessionCreated &&
                  r.message.content == 'مرحبا كيف الحال',
            ),
          ),
        ),
      ).called(1);
      verifyNever(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      );

      await eventController.close();
    },
  );

  test(
    'GatewayManager should preserve automatic title placeholder ownership',
    () async {
      when(
        mockSessionManager.getSession('placeholder-thread'),
      ).thenReturn(null);

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'placeholder-thread',
          platformId: 'test-platform',
          type: 'create_session',
          message: Message(role: MessageRole.user, content: ''),
          metadata: {
            'payload': {
              'title': 'مرحبا كيف الحال',
              'title_is_placeholder': true,
              'request_id': 'req-placeholder-thread',
            },
          },
          runId: 'req-placeholder-thread',
        ),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final savedSession =
          verify(mockSessionDb.saveSession(captureAny)).captured.single
              as SessionState;
      expect(savedSession.title, 'مرحبا كيف الحال');
      expect(savedSession.titleStatus, SessionTitleStatus.pending);

      await eventController.close();
    },
  );

  test(
    'GatewayManager should attach workspace context to session_created for pre-created sessions',
    () async {
      when(mockSessionManager.getSession('workspace-thread')).thenReturn(null);

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      final workspaceDir = Directory('${tempDir.path}/workspace-thread')
        ..createSync(recursive: true);

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'workspace-thread',
          platformId: 'test-platform',
          type: 'create_session',
          message: Message(role: MessageRole.user, content: ''),
          metadata: {
            'payload': {
              'title': 'Workspace Thread',
              'workspace_id': workspaceDir.path,
              'request_id': 'req-workspace-thread',
            },
          },
          runId: 'req-workspace-thread',
        ),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final capturedResponses = verify(
        mockPlatform.sendResponse(captureAny),
      ).captured.cast<GatewayResponse>();
      final threadCreated = capturedResponses.firstWhere(
        (response) =>
            response.sessionId == 'workspace-thread' &&
            response.isSessionCreated,
      );
      final normalizedWorkspacePath = workspaceDir.resolveSymbolicLinksSync();
      expect(
        threadCreated.sessionPayload?['workspace_id'],
        'workspace-${normalizedWorkspacePath.hashCode}',
      );
      expect(
        threadCreated.sessionPayload?['workspace_name'],
        'workspace-thread',
      );
      expect(
        threadCreated.sessionPayload?['workspace_path'],
        normalizedWorkspacePath,
      );

      await eventController.close();
    },
  );

  test(
    'GatewayManager should asynchronously generate intelligent title and dispatch session_updated on first assistant response',
    () async {
      final mockSessionManager = getIt<SessionManager>();
      final mockTitleService = getIt<TitleService>();

      // Mock new session (getSession returns null)
      when(
        mockSessionManager.getSession('intelligent-session'),
      ).thenReturn(null);

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['Sure, here is the answer.']));

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      // Fire the message
      eventController.add(
        GatewayEvent(
          sessionId: 'intelligent-session',
          platformId: 'test-platform',
          message: Message(
            role: MessageRole.user,
            content: 'Summarize quantum mechanics please.',
          ),
        ),
      );

      // Wait for the stream processing and asynchronous title generation to complete
      await Future.delayed(Duration(milliseconds: 150));

      // Verify TitleService was called
      verify(
        mockTitleService.generateTitle(
          sessionId: 'intelligent-session',
          userMessage: 'Summarize quantum mechanics please.',
          assistantResponse: 'Sure, here is the answer.',
          modelOverride: anyNamed('modelOverride'),
          route: completedTurnRoute,
        ),
      ).called(1);

      // Verify the captured placeholder still owned the title update.
      verify(
        mockSessionManager.updateSessionTitleIfCurrent(
          'intelligent-session',
          expectedTitle: 'Summarize quantum mechanics please.',
          title: 'Intelligent Generated Title',
        ),
      ).called(1);

      // Verify session_updated response was sent
      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.sessionId == 'intelligent-session' &&
                  r.isSessionUpdated &&
                  r.message.content == 'Intelligent Generated Title',
            ),
          ),
        ),
      ).called(1);

      await eventController.close();
    },
  );

  test(
    'delayed title completion survives ActiveRun cleanup and dispatches session_updated',
    () async {
      final mockTitleService = getIt<TitleService>() as MockTitleService;
      final titleCompleter = Completer<String>();
      final precreated = SessionState(
        sessionId: 'delayed-title-session',
        model: 'sanad-agent',
        title: 'Initial title',
        titleStatus: SessionTitleStatus.pending,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: const [],
      );
      when(
        mockSessionManager.getSession('delayed-title-session'),
      ).thenReturn(precreated);
      when(
        mockTitleService.generateTitle(
          sessionId: 'delayed-title-session',
          userMessage: 'Explain durable background work',
          assistantResponse: 'A complete answer.',
          modelOverride: anyNamed('modelOverride'),
          route: anyNamed('route'),
        ),
      ).thenAnswer((_) => titleCompleter.future);
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('A complete answer.'));

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async {});
      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'delayed-title-session',
          platformId: 'test-platform',
          message: Message(
            role: MessageRole.user,
            content: 'Explain durable background work',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (response) =>
                  response.sessionId == 'delayed-title-session' &&
                  !response.isSessionUpdated &&
                  response.isComplete &&
                  response.message.content == 'A complete answer.',
            ),
          ),
        ),
      ).called(1);

      titleCompleter.complete('Durable Background Work');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      verify(
        mockSessionManager.updateSessionTitleIfCurrent(
          'delayed-title-session',
          expectedTitle: 'Initial title',
          title: 'Durable Background Work',
        ),
      ).called(1);
      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (response) =>
                  response.sessionId == 'delayed-title-session' &&
                  response.isSessionUpdated &&
                  response.message.content == 'Durable Background Work',
            ),
          ),
        ),
      ).called(1);

      await eventController.close();
    },
  );

  test(
    'stale delayed title does not overwrite a newer title or emit',
    () async {
      final mockTitleService = getIt<TitleService>() as MockTitleService;
      final titleCompleter = Completer<String>();
      when(mockSessionManager.getSession('stale-title-session')).thenReturn(
        SessionState(
          sessionId: 'stale-title-session',
          model: 'sanad-agent',
          title: 'Initial title',
          titleStatus: SessionTitleStatus.pending,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          messages: const [],
        ),
      );
      when(
        mockSessionManager.updateSessionTitleIfCurrent(
          'stale-title-session',
          expectedTitle: 'Initial title',
          title: 'Obsolete Generated Title',
        ),
      ).thenReturn(false);
      when(
        mockTitleService.generateTitle(
          sessionId: 'stale-title-session',
          userMessage: 'Original prompt',
          assistantResponse: 'Original answer',
          modelOverride: anyNamed('modelOverride'),
          route: anyNamed('route'),
        ),
      ).thenAnswer((_) => titleCompleter.future);
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('Original answer'));

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async {});
      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();
      eventController.add(
        GatewayEvent(
          sessionId: 'stale-title-session',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Original prompt'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      titleCompleter.complete('Obsolete Generated Title');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final responses = verify(
        mockPlatform.sendResponse(captureAny),
      ).captured.cast<GatewayResponse>();
      expect(
        responses.where(
          (response) =>
              response.sessionId == 'stale-title-session' &&
              response.isSessionUpdated,
        ),
        isEmpty,
      );

      await eventController.close();
    },
  );

  test(
    'GatewayManager generates a pending title even when persisted history is non-empty',
    () async {
      final mockTitleService = getIt<TitleService>();

      when(mockSessionManager.getSession('precreated-session')).thenReturn(
        SessionState(
          sessionId: 'precreated-session',
          model: 'sanad-agent',
          title: 'Chat',
          titleStatus: SessionTitleStatus.pending,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          messages: [
            Message(role: MessageRole.user, content: 'Persisted first prompt'),
            Message(
              role: MessageRole.assistant,
              content: 'Persisted first answer',
            ),
          ],
        ),
      );

      final eventController = StreamController<GatewayEvent>();
      when(mockPlatform.initialize()).thenAnswer((_) async => {});
      when(mockPlatform.eventStream).thenAnswer((_) => eventController.stream);
      when(mockPlatform.sendResponse(any)).thenAnswer((_) async => {});

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromIterable(['First completed answer.']));

      gatewayManager.registerPlatform(mockPlatform);
      await gatewayManager.start();

      eventController.add(
        GatewayEvent(
          sessionId: 'precreated-session',
          platformId: 'test-platform',
          message: Message(
            role: MessageRole.user,
            content: 'First user message',
          ),
        ),
      );

      await Future.delayed(Duration(milliseconds: 150));

      verifyNever(
        mockPlatform.sendResponse(
          argThat(predicate<GatewayResponse>((r) => r.isSessionCreated)),
        ),
      );
      verify(
        mockTitleService.generateTitle(
          sessionId: 'precreated-session',
          userMessage: 'First user message',
          assistantResponse: 'First completed answer.',
          modelOverride: anyNamed('modelOverride'),
          route: completedTurnRoute,
        ),
      ).called(1);
      verify(
        mockPlatform.sendResponse(
          argThat(
            predicate<GatewayResponse>(
              (r) =>
                  r.sessionId == 'precreated-session' &&
                  r.isSessionUpdated &&
                  r.message.content == 'Intelligent Generated Title',
            ),
          ),
        ),
      ).called(1);

      await eventController.close();
    },
  );

  test('final session title is not regenerated', () async {
    final mockTitleService = getIt<TitleService>();
    when(mockSessionManager.getSession('final-title-session')).thenReturn(
      SessionState(
        sessionId: 'final-title-session',
        model: 'sanad-agent',
        title: 'User Owned Title',
        titleStatus: SessionTitleStatus.finalized,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    when(
      mockAgentRunner.streamMessage(
        any,
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        providerId: anyNamed('providerId'),
        model: anyNamed('model'),
        thinkingMode: anyNamed('thinkingMode'),
        receivedAt: anyNamed('receivedAt'),
        onToolEvent: anyNamed('onToolEvent'),
        onSteerContinuation: anyNamed('onSteerContinuation'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).thenAnswer((_) => Stream.value('Completed answer'));

    await getIt<SessionRunOrchestrator>().handleEvent(
      GatewayEvent(
        sessionId: 'final-title-session',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Keep my title'),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    verifyNever(
      mockTitleService.generateTitle(
        sessionId: 'final-title-session',
        userMessage: 'Keep my title',
        assistantResponse: 'Completed answer',
        modelOverride: anyNamed('modelOverride'),
        route: anyNamed('route'),
      ),
    );
  });

  test(
    'SessionRunOrchestrator routes steer into the active runner with identity metadata',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final responses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(responses.add);
      final completer = Completer<String>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromFuture(completer.future));

      unawaited(
        orchestrator.handleEvent(
          GatewayEvent(
            sessionId: 'session-steer-active',
            platformId: 'test-platform',
            message: Message(role: MessageRole.user, content: 'Initial task'),
          ),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      await orchestrator.handleEvent(
        GatewayEvent(
          sessionId: 'session-steer-active',
          platformId: 'test-platform',
          type: 'steer',
          message: Message(role: MessageRole.user, content: 'Change direction'),
          turnRequest: AgentTurnRequest(
            sessionId: 'session-steer-active',
            message: 'Change direction',
            requestId: 'steer-active-1',
          ),
        ),
      );

      verify(
        mockAgentRunner.steerEvent(
          'Change direction',
          requestId: 'steer-active-1',
          receivedAt: anyNamed('receivedAt'),
        ),
      ).called(1);
      expect(
        responses,
        contains(
          predicate<GatewayResponse>(
            (response) =>
                response.message.metadata?['canonical_event_type'] ==
                    'session.pending_steer_changed' &&
                response
                        .message
                        .metadata?['canonical_payload']?['request_id'] ==
                    'steer-active-1' &&
                response.message.metadata?['canonical_payload']?['state'] ==
                    'pending',
          ),
        ),
      );

      completer.complete('Done');
      await Future.delayed(const Duration(milliseconds: 50));
      await responseSubscription.cancel();
    },
  );

  test(
    'SessionRunOrchestrator should queue events when busy and process FIFO',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final responses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(responses.add);

      // Stub AgentRunner streamMessage to delay response
      final completer = Completer<String>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromFuture(completer.future));

      // Send first event
      final event1 = GatewayEvent(
        sessionId: 'session-busy-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi 1'),
      );
      unawaited(orchestrator.handleEvent(event1));
      await Future.delayed(Duration(milliseconds: 10));

      expect(orchestrator.isSessionBusy('session-busy-test'), isTrue);

      // Send second event (should be queued)
      final event2 = GatewayEvent(
        sessionId: 'session-busy-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi 2'),
        turnRequest: AgentTurnRequest(
          sessionId: 'session-busy-test',
          message: 'Hi 2',
          requestId: 'queued-request-2',
          deliveryIntent: MessageDeliveryIntent.queue,
        ),
      );
      await orchestrator.handleEvent(event2);

      expect(orchestrator.getQueuedEvents('session-busy-test').length, 1);
      expect(
        orchestrator.getQueuedEvents('session-busy-test').first.message.content,
        'Hi 2',
      );
      expect(
        responses,
        contains(
          predicate<GatewayResponse>(
            (response) =>
                response.message.content == 'Hi 2' &&
                response.message.metadata?['queued'] == true &&
                response.message.metadata?['request_id'] == 'queued-request-2',
          ),
        ),
      );

      // Complete the first event
      completer.complete('Response 1');
      await Future.delayed(Duration(milliseconds: 50));

      // Verify second event started processing and queue is cleared
      expect(orchestrator.getQueuedEvents('session-busy-test').length, 0);
      expect(
        responses,
        contains(
          predicate<GatewayResponse>(
            (response) =>
                response.message.content == 'Hi 2' &&
                response.message.metadata?['queued'] != true &&
                response.message.metadata?['request_id'] == 'queued-request-2',
          ),
        ),
      );
      await responseSubscription.cancel();
    },
  );

  test(
    'SessionRunOrchestrator keeps suspended sessions busy and resumes without duplicating the user echo',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final responses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(responses.add);
      var firstAttempt = true;

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) {
        if (firstAttempt) {
          firstAttempt = false;
          return Stream<String>.error(
            const RuntimeRecoveryRequired(
              'session-suspended-test',
              RuntimeFailureReason.rateLimit,
            ),
          );
        }
        return Stream.value('Queued response');
      });
      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('Recovered response'));

      final firstEvent = GatewayEvent(
        sessionId: 'session-suspended-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi suspended'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-suspended-test',
          message: 'Hi suspended',
          requestId: 'req-suspended-1',
        ),
      );

      await orchestrator.handleEvent(firstEvent);

      expect(orchestrator.hasSuspendedEvent('session-suspended-test'), isTrue);
      expect(orchestrator.isSessionBusy('session-suspended-test'), isTrue);

      final secondEvent = GatewayEvent(
        sessionId: 'session-suspended-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi queued later'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-suspended-test',
          message: 'Hi queued later',
          requestId: 'req-suspended-2',
          deliveryIntent: MessageDeliveryIntent.queue,
        ),
      );

      await orchestrator.handleEvent(secondEvent);

      expect(
        orchestrator.getQueuedEvents('session-suspended-test'),
        hasLength(1),
      );
      expect(
        responses.where(
          (response) =>
              response.message.content == 'Hi queued later' &&
              response.message.metadata?['queued'] == true,
        ),
        hasLength(1),
      );
      expect(
        orchestrator.hasSuspendedEvent('session-suspended-test'),
        isTrue,
        reason: 'explicit queue must not resume the older recovery owner',
      );
      verifyNever(
        mockAgentRunner.updateTurnRoute(
          providerId: anyNamed('providerId'),
          modelId: anyNamed('modelId'),
        ),
      );

      await orchestrator.resumeSuspended('session-suspended-test');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        responses.where(
          (response) => response.message.content == 'Hi suspended',
        ),
        hasLength(1),
      );
      await responseSubscription.cancel();
    },
  );

  test(
    'SessionRunOrchestrator rewrites queued provider overrides after continue_with_provider',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      var firstAttempt = true;

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((invocation) {
        final providerId = invocation.namedArguments[#providerId] as String?;
        if (firstAttempt) {
          firstAttempt = false;
          expect(providerId, 'provider-old');
          return Stream<String>.error(
            const RuntimeRecoveryRequired(
              'session-provider-switch-test',
              RuntimeFailureReason.rateLimit,
            ),
          );
        }
        expect(providerId, 'provider-new');
        return Stream.value('Queued response on new provider');
      });
      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((invocation) {
        expect(invocation.namedArguments[#providerId], 'provider-new');
        return Stream.value('Recovered response on new provider');
      });

      final firstEvent = GatewayEvent(
        sessionId: 'session-provider-switch-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi suspended'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-provider-switch-test',
          message: 'Hi suspended',
          providerInstanceId: 'provider-old',
          providerId: 'provider-old',
          requestId: 'req-provider-1',
        ),
      );

      await orchestrator.handleEvent(firstEvent);
      expect(
        orchestrator.hasSuspendedEvent('session-provider-switch-test'),
        isTrue,
      );

      final queuedEvent = GatewayEvent(
        sessionId: 'session-provider-switch-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi queued later'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-provider-switch-test',
          message: 'Hi queued later',
          providerInstanceId: 'provider-old',
          providerId: 'provider-old',
          requestId: 'req-provider-2',
        ),
      );

      await orchestrator.handleEvent(queuedEvent);
      expect(
        orchestrator.getQueuedEvents('session-provider-switch-test'),
        hasLength(1),
      );

      await orchestrator.resumeSuspended(
        'session-provider-switch-test',
        providerInstanceId: 'provider-new',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verify(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: 'provider-new',
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);
      verify(
        mockAgentRunner.streamMessage(
          'Hi queued later',
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: 'provider-new',
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);
    },
  );

  // ── Plan 30 Phase H: atomic route + stop idempotency ──────────────────
  test(
    'SessionRunOrchestrator rewrites provider AND model atomically on resume (Phase H §3)',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();

      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer(
        (_) => Stream<String>.error(
          const RuntimeRecoveryRequired(
            'session-atomic-route',
            RuntimeFailureReason.rateLimit,
          ),
        ),
      );
      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((invocation) {
        // The resumed request MUST carry the NEW provider AND the NEW model.
        final providerId = invocation.namedArguments[#providerId] as String?;
        final model = invocation.namedArguments[#model] as String?;
        expect(providerId, 'provider-new');
        expect(model, 'model-new');
        return Stream.value('Recovered with new route');
      });

      final firstEvent = GatewayEvent(
        sessionId: 'session-atomic-route',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-atomic-route',
          message: 'Hi',
          providerInstanceId: 'provider-old',
          providerId: 'provider-old',
          model: 'model-old',
          requestId: 'req-atomic-1',
        ),
      );
      await orchestrator.handleEvent(firstEvent);
      expect(orchestrator.hasSuspendedEvent('session-atomic-route'), isTrue);

      // Queue a second message on the old route.
      final queuedEvent = GatewayEvent(
        sessionId: 'session-atomic-route',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Queued'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-atomic-route',
          message: 'Queued',
          providerInstanceId: 'provider-old',
          providerId: 'provider-old',
          model: 'model-old',
          requestId: 'req-atomic-2',
        ),
      );
      await orchestrator.handleEvent(queuedEvent);

      // Resume with BOTH provider AND model (atomic route).
      await orchestrator.resumeSuspended(
        'session-atomic-route',
        providerInstanceId: 'provider-new',
        modelId: 'model-new',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verify(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: 'provider-new',
          model: 'model-new',
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);
    },
  );

  test(
    'requestStop clears the queue and suspended work and returns to idle (Phase H §1)',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final responses = <GatewayResponse>[];
      final responseSub = orchestrator.responses.listen(responses.add);
      addTearDown(responseSub.cancel);
      var callCount = 0;

      final completer = Completer<String>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) {
        if (callCount++ == 0) {
          return Stream.fromFuture(completer.future);
        }
        return Stream.value('Fresh response after stop');
      });

      final firstEvent = GatewayEvent(
        sessionId: 'session-stop-test',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Running'),
        turnRequest: const AgentTurnRequest(
          sessionId: 'session-stop-test',
          message: 'Running',
          providerInstanceId: 'provider-1',
          providerId: 'provider-1',
          requestId: 'req-stop-1',
        ),
      );
      unawaited(orchestrator.handleEvent(firstEvent));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(orchestrator.isSessionBusy('session-stop-test'), isTrue);

      // Queue two messages.
      for (var i = 0; i < 2; i++) {
        await orchestrator.handleEvent(
          GatewayEvent(
            sessionId: 'session-stop-test',
            platformId: 'test-platform',
            message: Message(role: MessageRole.user, content: 'Queued $i'),
            turnRequest: AgentTurnRequest(
              sessionId: 'session-stop-test',
              message: 'Queued $i',
              requestId: 'req-stop-queue-$i',
              deliveryIntent: MessageDeliveryIntent.queue,
            ),
          ),
        );
      }
      expect(orchestrator.getQueuedEvents('session-stop-test'), hasLength(2));

      // Stop from a "second client" — must clear queue + return to idle.
      await orchestrator.requestStop('session-stop-test');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(orchestrator.getQueuedEvents('session-stop-test'), isEmpty);
      expect(orchestrator.isSessionBusy('session-stop-test'), isFalse);
      expect(orchestrator.hasSuspendedEvent('session-stop-test'), isFalse);
      verify(mockAgentRunner.requestStop()).called(1);
      final stopped = responses.lastWhere(
        (response) =>
            response.message.metadata?['canonical_event_type'] == 'stopped',
      );
      final stoppedPayload = Map<String, dynamic>.from(
        stopped.message.metadata?['canonical_payload'] as Map,
      );
      expect(stopped.runId, isNotEmpty);
      expect(stopped.modelStepId, 'step-123');
      expect(stoppedPayload['run_id'], stopped.runId);
      expect(stoppedPayload['model_step_id'], 'step-123');

      await orchestrator.handleEvent(
        GatewayEvent(
          sessionId: 'session-stop-test',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Fresh request'),
        ),
      );

      verify(
        mockAgentRunner.streamMessage(
          'Fresh request',
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);
    },
  );

  test(
    'stop completes cleanup when recovery cancellation surfaces from stream cancellation',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final listening = Completer<void>();
      final controller = StreamController<String>(
        onListen: listening.complete,
        onCancel: () => Future<void>.error(
          const RuntimeRecoveryCancelled('session-stop-rate-limit'),
        ),
      );
      addTearDown(() async {
        if (!controller.isClosed) await controller.close();
      });
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => controller.stream);

      final responses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(responses.add);
      addTearDown(responseSubscription.cancel);

      unawaited(
        orchestrator.handleEvent(
          GatewayEvent(
            sessionId: 'session-stop-rate-limit',
            platformId: 'test-platform',
            message: Message(role: MessageRole.user, content: 'Running'),
          ),
        ),
      );
      await listening.future;
      expect(orchestrator.isSessionBusy('session-stop-rate-limit'), isTrue);

      await orchestrator.requestStop('session-stop-rate-limit');
      await Future<void>.delayed(Duration.zero);

      expect(orchestrator.isSessionBusy('session-stop-rate-limit'), isFalse);
      expect(
        orchestrator.hasSuspendedEvent('session-stop-rate-limit'),
        isFalse,
      );
      expect(
        responses.where(
          (response) =>
              response.message.metadata?['canonical_event_type'] == 'stopped',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'stop A preserves message B received while subscription cancellation waits',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final cancelStarted = Completer<void>();
      final releaseCancellation = Completer<void>();
      final firstListening = Completer<void>();
      final firstController = StreamController<String>(
        onListen: firstListening.complete,
        onCancel: () {
          cancelStarted.complete();
          return releaseCancellation.future;
        },
      );
      addTearDown(() async {
        if (!firstController.isClosed) await firstController.close();
      });

      var callCount = 0;
      dynamic lateReasoningFromA;
      dynamic lateToolFromA;
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((invocation) {
        if (callCount++ == 0) {
          lateReasoningFromA = invocation.namedArguments[#onReasoningDelta];
          lateToolFromA = invocation.namedArguments[#onToolEvent];
          return firstController.stream;
        }
        return Stream.value('Response B');
      });

      final responses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(responses.add);
      addTearDown(responseSubscription.cancel);

      unawaited(
        orchestrator.handleEvent(
          GatewayEvent(
            sessionId: 'session-stop-generation',
            platformId: 'test-platform',
            message: Message(role: MessageRole.user, content: 'Request A'),
          ),
        ),
      );
      await firstListening.future;

      final stopFuture = orchestrator.requestStop('session-stop-generation');
      await cancelStarted.future;
      await Future<void>.delayed(Duration.zero);

      await orchestrator.handleEvent(
        GatewayEvent(
          sessionId: 'session-stop-generation',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Request B'),
        ),
      );
      expect(
        orchestrator.getQueuedEvents('session-stop-generation'),
        hasLength(1),
      );

      releaseCancellation.complete();
      await stopFuture;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await lateReasoningFromA('Late reasoning from A');
      await Function.apply(lateToolFromA, const [], {
        #toolName: 'late_tool_from_a',
        #input: '{}',
        #output: null,
        #isError: false,
        #isStart: true,
        #toolRunId: 'late-tool-run-a',
      });
      await Future<void>.delayed(Duration.zero);

      expect(orchestrator.getQueuedEvents('session-stop-generation'), isEmpty);
      expect(callCount, 2);
      final bResponses = responses
          .where((response) => response.message.content == 'Response B')
          .toList();
      expect(bResponses, hasLength(2));
      expect(
        bResponses.map((response) => response.runId).toSet(),
        hasLength(1),
      );
      final aRunId = responses
          .firstWhere((response) => response.message.content == 'Request A')
          .runId;
      expect(bResponses.first.runId, isNot(aRunId));
      expect(
        responses.where(
          (response) =>
              response.message.content == 'Late reasoning from A' ||
              response.toolName == 'late_tool_from_a',
        ),
        isEmpty,
      );
    },
  );

  test(
    'unexpected RuntimeRecoveryCancelled on the current run emits a controlled error',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer(
        (_) => Stream<String>.error(
          const RuntimeRecoveryCancelled('session-unexpected-cancel'),
        ),
      );
      final responses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(responses.add);
      addTearDown(responseSubscription.cancel);

      await orchestrator.handleEvent(
        GatewayEvent(
          sessionId: 'session-unexpected-cancel',
          platformId: 'test-platform',
          message: Message(role: MessageRole.user, content: 'Run'),
        ),
      );

      expect(
        responses.where(
          (response) =>
              response.isComplete &&
              (response.message.content?.startsWith('Error:') ?? false),
        ),
        hasLength(1),
      );
      expect(orchestrator.isSessionBusy('session-unexpected-cancel'), isFalse);
    },
  );

  test(
    'requestStop is idempotent and safe when already idle (Phase H §1)',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();

      // Stopping an idle session must not throw.
      await orchestrator.requestStop('session-idle');

      // Stopping again is a safe no-op.
      await orchestrator.requestStop('session-idle');

      // A second stop from another client on a busy session is also safe.
      final completer = Completer<String>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromFuture(completer.future));

      final event = GatewayEvent(
        sessionId: 'session-double-stop',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Hi'),
      );
      unawaited(orchestrator.handleEvent(event));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Two stops from two clients.
      await orchestrator.requestStop('session-double-stop');
      await orchestrator.requestStop('session-double-stop');

      expect(orchestrator.isSessionBusy('session-double-stop'), isFalse);
      if (!completer.isCompleted) completer.complete('stopped');
    },
  );

  test(
    'requestStopAll clears every active session before a controlled daemon restart',
    () async {
      final orchestrator = getIt<SessionRunOrchestrator>();
      final controllers = [
        StreamController<String>(),
        StreamController<String>(),
      ];
      var streamIndex = 0;
      addTearDown(() async {
        for (final controller in controllers) {
          if (!controller.isClosed) await controller.close();
        }
      });
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => controllers[streamIndex++].stream);

      for (final sessionId in ['restart-active-a', 'restart-active-b']) {
        unawaited(
          orchestrator.handleEvent(
            GatewayEvent(
              sessionId: sessionId,
              platformId: 'test-platform',
              message: Message(role: MessageRole.user, content: 'work'),
            ),
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(orchestrator.isSessionBusy('restart-active-a'), isTrue);
      expect(orchestrator.isSessionBusy('restart-active-b'), isTrue);

      await orchestrator.requestStopAll();

      expect(orchestrator.isSessionBusy('restart-active-a'), isFalse);
      expect(orchestrator.isSessionBusy('restart-active-b'), isFalse);
      verify(mockAgentRunner.requestStop()).called(2);
    },
  );

  group('Gate E: Runtime Restoration and FIFO', () {
    test(
      'restart restores a suspended ask-user tool as waiting, not blocked',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);
        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        final now = DateTime.now();
        final checkpoint = SuspendedCheckpoint(
          checkpointId: 'ask-checkpoint',
          sessionId: 'session-ask-restart',
          requestId: 'ask-request',
          toolCallId: 'call-ask-user',
          toolName: 'system_ask_user',
          status: 'awaiting_permission',
          toolArguments: const {'questions': []},
          permissionPayload: const {'questions': []},
          createdAt: now,
          updatedAt: now,
        );
        final legacyBlockedCheckpoint = SuspendedCheckpoint(
          checkpointId: 'ask-checkpoint-legacy-blocked',
          sessionId: 'session-ask-legacy-blocked',
          requestId: 'ask-request-legacy-blocked',
          toolCallId: 'call-ask-user-legacy-blocked',
          toolName: 'system_ask_user',
          status: 'awaiting_permission',
          toolArguments: const {'questions': []},
          permissionPayload: const {'questions': []},
          createdAt: now,
          updatedAt: now,
        );
        when(
          mockSessionManager.listSuspendedCheckpoints(
            status: 'awaiting_permission',
          ),
        ).thenReturn([checkpoint, legacyBlockedCheckpoint]);
        GetIt.I.registerSingleton<SuspendedCheckpointStore>(
          SuspendedCheckpointStore(sessionManager: mockSessionManager),
        );

        addTearDown(() {
          GetIt.I.unregister<SuspendedCheckpointStore>();
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-ask-restart', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-ask-legacy-blocked', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-ask-restart',
            sessionId: 'session-ask-restart',
            requestId: 'turn-request',
            sequence: 1,
            state: SessionWorkState.running,
            attempt: 0,
            payload: const {'message': 'build the site'},
            continuationMetadata: const {
              'owner_run_id': 'run-ask-restart',
              'owner_generation': 1,
              'currently_executing_tools': ['call-ask-user'],
              'tool_replay_safety': {'call-ask-user': false},
            },
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-ask-legacy-blocked',
            sessionId: 'session-ask-legacy-blocked',
            requestId: 'turn-request-legacy-blocked',
            sequence: 1,
            state: SessionWorkState.blocked,
            attempt: 0,
            payload: const {'message': 'continue the old task'},
            continuationMetadata: const {
              'owner_run_id': 'run-ask-legacy-blocked',
              'owner_generation': 1,
              'currently_executing_tools': ['call-ask-user-legacy-blocked'],
              'tool_replay_safety': {'call-ask-user-legacy-blocked': false},
            },
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.upsertNotice(
          sessionId: 'session-ask-legacy-blocked',
          status: 'blocked',
          reason: 'unknown',
          title: 'Execution interrupted',
          message: 'stale false notice',
        );

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        expect(
          repo.findWorkItem('work-ask-restart')?.state,
          SessionWorkState.waiting,
        );
        expect(
          repo.executionSnapshots.getSnapshot('session-ask-restart').state,
          SessionExecutionState.waiting,
        );
        expect(recoveryService.hasActiveNotice('session-ask-restart'), isFalse);
        expect(orchestrator.hasSuspendedEvent('session-ask-restart'), isTrue);
        expect(
          repo.findWorkItem('work-ask-legacy-blocked')?.state,
          SessionWorkState.waiting,
        );
        expect(repo.findNotice('session-ask-legacy-blocked'), isNull);
        expect(
          orchestrator.hasSuspendedEvent('session-ask-legacy-blocked'),
          isTrue,
        );
      },
    );

    test(
      'startup removes a runtime notice with no active recovery work',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);
        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-old-complete', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-old-complete',
            sessionId: 'session-old-complete',
            sequence: 1,
            state: SessionWorkState.completed,
            attempt: 0,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertNotice(
          sessionId: 'session-old-complete',
          status: 'blocked',
          reason: 'unknown',
          title: 'Runtime recovery failed on startup',
          message: 'stale',
        );

        await SessionRunOrchestrator().restorePersistedState();

        expect(repo.findNotice('session-old-complete'), isNull);
        expect(
          recoveryService.hasActiveNotice('session-old-complete'),
          isFalse,
        );
      },
    );

    test(
      'persisted ask-user answer completes durable work before final delivery',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);
        final now = DateTime.now();
        const sessionId = 'session-persisted-answer';
        const toolCallId = 'call-persisted-answer';
        final checkpoint = SuspendedCheckpoint(
          checkpointId: 'checkpoint-persisted-answer',
          sessionId: sessionId,
          requestId: 'ask-persisted-answer',
          toolCallId: toolCallId,
          toolName: 'system_ask_user',
          status: 'awaiting_permission',
          toolArguments: const {'questions': []},
          permissionPayload: const {'questions': []},
          createdAt: now,
          updatedAt: now,
        );
        when(
          mockSessionManager.getSuspendedCheckpointByRequestId(
            checkpoint.requestId,
          ),
        ).thenReturn(checkpoint);
        when(
          mockSessionManager.claimSuspendedCheckpointDecision(
            requestId: checkpoint.requestId,
            status: 'resuming',
          ),
        ).thenReturn(true);
        when(
          mockSessionManager.deleteSuspendedCheckpointByRequestId(
            checkpoint.requestId,
          ),
        ).thenReturn(null);
        when(
          mockAgentRunner.beginAuthoritativeRun(
            'run-persisted-answer',
            workItemId: 'work-persisted-answer',
            generation: 7,
          ),
        ).thenReturn(null);
        when(
          mockAgentRunner.resumeAfterToolCall(
            toolCallId: toolCallId,
            toolName: 'system_ask_user',
            arguments: checkpoint.toolArguments,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            forcedOutput: 'approved',
            forcedIsError: false,
            onToolEvent: anyNamed('onToolEvent'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('continued'));

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-persisted-answer',
            sessionId: sessionId,
            requestId: 'turn-persisted-answer',
            sequence: 1,
            state: SessionWorkState.waiting,
            attempt: 0,
            continuationMetadata: const {
              'owner_run_id': 'run-persisted-answer',
              'owner_generation': 7,
              'currently_executing_tools': [toolCallId],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.upsertNotice(
          sessionId: sessionId,
          status: 'blocked',
          reason: 'unknown',
          title: 'Execution interrupted',
          message: 'stale false notice',
        );
        final runtimeRecovery = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        runtimeRecovery.attachPersistedState(repo);

        final checkpointStore = SuspendedCheckpointStore(
          sessionManager: mockSessionManager,
        );
        final permissionManager = PermissionManager(
          policyStore: const WorkspacePolicyStore(),
          platformRuntimeBridge: PlatformRuntimeBridge(),
          checkpointStore: checkpointStore,
        );
        final service = SuspendedResumeService(
          checkpointStore: checkpointStore,
          sessionManager: mockSessionManager,
          runtimeCatalog: getIt<LocalRuntimeCatalog>(),
          runtimeContextBuilder: const RuntimeContextBuilder(
            skillRegistry: SkillRegistry(),
          ),
          workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
          permissionManager: permissionManager,
          persistedState: repo,
          runtimeRecovery: runtimeRecovery,
        );
        final statesAtDelivery = <SessionWorkState?>[];
        final responses = <GatewayResponse>[];

        final resumed = await service.resumeFromDecision(
          requestId: checkpoint.requestId,
          decision: const {'answer': 'approved'},
          emitResponse: (response) async {
            responses.add(response);
            statesAtDelivery.add(
              repo.findWorkItem('work-persisted-answer')?.state,
            );
          },
        );

        expect(resumed, isTrue);
        expect(
          repo.findWorkItem('work-persisted-answer')?.state,
          SessionWorkState.completed,
        );
        expect(repo.findNotice(sessionId), isNull);
        expect(responses.last.isComplete, isTrue);
        expect(responses.last.message.content, 'continued');
        expect(statesAtDelivery.last, SessionWorkState.completed);
        verify(
          mockAgentRunner.endAuthoritativeRun('run-persisted-answer'),
        ).called(1);
        stateDb.dispose();
      },
    );

    test(
      'restored waiting notice auto-resumes through resumeSuspended',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-auto-resume', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        final resumeAt = DateTime.now().add(const Duration(milliseconds: 30));
        repo.upsertNotice(
          sessionId: 'session-auto-resume',
          requestId: 'req-auto-resume',
          runId: 'run-auto-resume',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Rate limited',
          message: 'waiting',
          providerInstanceId: 'provider-auto',
          resumeAt: resumeAt.toUtc().toIso8601String(),
          actions: ['stop', 'changeProvider'],
        );

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-auto-resume',
            sessionId: 'session-auto-resume',
            requestId: 'req-auto-resume',
            sequence: 1,
            state: SessionWorkState.waiting,
            providerInstanceId: 'provider-auto',
            modelId: 'gpt-4o',
            attempt: 0,
            payload: const {
              'message': 'Resume me',
              'eventMetadata': {},
              'runId': 'run-auto-resume',
            },
            continuationMetadata: const {
              'owner_run_id': 'run-auto-resume',
              'owner_generation': 1,
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        when(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('auto resumed'));

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();
        await Future<void>.delayed(const Duration(milliseconds: 120));

        verify(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: 'provider-auto',
            model: 'gpt-4o',
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).called(1);

        final restoredItem = repo.findWorkItem('work-auto-resume');
        expect(restoredItem?.state, equals(SessionWorkState.completed));
        expect(recoveryService.hasActiveNotice('session-auto-resume'), isFalse);
      },
    );

    test('durable work payloads are redacted before persistence', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        stateDb.dispose();
      });

      final completer = Completer<String>();
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.fromFuture(completer.future));

      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-redacted-durable', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      final event = GatewayEvent(
        sessionId: 'session-redacted-durable',
        platformId: 'test-platform',
        message: Message(
          role: MessageRole.user,
          content: 'token=fixture-value',
        ),
        metadata: {
          'authorization': 'Bearer secret-token-123456',
          'payload': {
            'request_id': 'req-redacted',
            'provider_instance_id': 'provider-1',
          },
        },
      );

      final orchestrator = SessionRunOrchestrator();
      final handleFuture = orchestrator.handleEvent(event);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final active = repo.findActiveWorkItem('session-redacted-durable');
      expect(active, isNotNull);
      expect(active!.payload['message'], equals('token: ***'));
      expect(active.payload['eventMetadata']['authorization'], equals('***'));

      if (!completer.isCompleted) completer.complete('done');
      await handleFuture;
    });

    test('restoring work items and notices on startup', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      // Inject database and repo into GetIt
      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final mockLimiter = ProviderRateLimiter();
      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        mockLimiter,
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      final session1 = 'session-gate-e-1';
      final session2 = 'session-gate-e-2';

      // 1. Insert sessions first to respect FK
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$session1', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$session2', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      // 2. Insert waiting notice in DB for session1
      final resumeAt = DateTime.now().add(const Duration(minutes: 5));
      repo.upsertNotice(
        sessionId: session1,
        requestId: 'req-1',
        runId: 'run-1',
        status: 'waiting',
        reason: 'rateLimit',
        title: 'Rate limited',
        message: 'Wait',
        providerInstanceId: 'openai-gpt-4o',
        providerDisplayName: 'OpenAI',
        resumeAt: resumeAt.toUtc().toIso8601String(),
        actions: ['stop', 'changeProvider'],
      );

      // 3. Insert work items:
      // - One queued item in session1
      final queuedItem = SessionWorkItem(
        workItemId: 'work-queued',
        sessionId: session1,
        requestId: 'req-queued',
        sequence: 2,
        state: SessionWorkState.queued,
        attempt: 0,
        payload: const {'message': 'Queued Message', 'eventMetadata': {}},
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.insertWorkItem(queuedItem);

      // - One running item that has only IDEMPOTENT executing tools in session1
      final runningIdempotentItem = SessionWorkItem(
        workItemId: 'work-running-idempotent',
        sessionId: session1,
        requestId: 'req-running-idempotent',
        sequence: 3,
        state: SessionWorkState.running,
        attempt: 0,
        payload: const {
          'message': 'Idempotent Message',
          'eventMetadata': {},
          'toolCalls': [
            {'id': 'call-view', 'name': 'view_file'},
          ],
        },
        continuationMetadata: const {
          'completed_tool_results': {},
          'currently_executing_tools': ['call-view'],
          'tool_replay_safety': {'call-view': true},
        },
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.insertWorkItem(runningIdempotentItem);

      // - One running item that has NON-IDEMPOTENT executing tools in session2
      final runningNonIdempotentItem = SessionWorkItem(
        workItemId: 'work-running-non-idempotent',
        sessionId: session2,
        requestId: 'req-running-non-idempotent',
        sequence: 4,
        state: SessionWorkState.running,
        attempt: 0,
        payload: const {
          'message': 'Non-Idempotent Message',
          'eventMetadata': {},
          'toolCalls': [
            {'id': 'call-run', 'name': 'run_command'},
          ],
        },
        continuationMetadata: const {
          'completed_tool_results': {},
          'currently_executing_tools': ['call-run'],
          'tool_replay_safety': {'call-run': false},
        },
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.insertWorkItem(runningNonIdempotentItem);

      final orchestrator = SessionRunOrchestrator();

      // Act: Restore
      await orchestrator.restorePersistedState();

      // Assert E.1: Notice restored to recovery service
      expect(recoveryService.hasActiveNotice(session1), isTrue);
      final activeNotice = recoveryService.activeNotice(session1);
      expect(activeNotice?.status, equals(RuntimeNoticeStatus.waiting));
      expect(activeNotice?.providerInstanceId, equals('openai-gpt-4o'));

      // Assert E.2.3: Idempotent run was re-queued, Non-idempotent run was blocked
      final restoredIdempotent = repo.findWorkItem('work-running-idempotent');
      expect(restoredIdempotent?.state, equals(SessionWorkState.queued));

      final restoredNonIdempotent = repo.findWorkItem(
        'work-running-non-idempotent',
      );
      expect(restoredNonIdempotent?.state, equals(SessionWorkState.blocked));

      // Assert E.2.1: FIFO queue rebuilt
      final queuedEvents = orchestrator.getQueuedEvents(session1);
      expect(
        queuedEvents.length,
        equals(2),
      ); // queuedItem + runningIdempotentItem which became queued!
      expect(queuedEvents[0].message.content, equals('Queued Message'));
      expect(queuedEvents[1].message.content, equals('Idempotent Message'));
    });

    test(
      'queue-only restore starts draining the oldest queued item automatically',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-queue-bootstrap', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-queue-bootstrap',
            sessionId: 'session-queue-bootstrap',
            requestId: 'req-queue-bootstrap',
            sequence: 1,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: const {'message': 'Drain me first', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        when(
          mockAgentRunner.streamMessage(
            any,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            receivedAt: anyNamed('receivedAt'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('drained'));

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        verify(
          mockAgentRunner.streamMessage(
            'Drain me first',
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            receivedAt: anyNamed('receivedAt'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).called(1);

        final workItem = repo.findWorkItem('work-queue-bootstrap');
        expect(workItem?.state, equals(SessionWorkState.completed));
        expect(
          orchestrator.getQueuedEvents('session-queue-bootstrap'),
          isEmpty,
        );
      },
    );

    test(
      'Gate C.2: a successful resume ends with the work item in `completed`, '
      'never silently deleted or stuck in `resuming`',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        // Wire the runner so resumeStream() returns a one-chunk stream
        // that completes naturally.
        when(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('resumed answer'));

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('session-c2', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        // Insert a runtime notice whose resume_at has already elapsed so
        // the restore path schedules an immediate auto-resume.
        repo.upsertNotice(
          sessionId: 'session-c2',
          requestId: 'req-c2-1',
          runId: 'run-c2-1',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Rate limited',
          message: 'waiting',
          providerInstanceId: 'prov-c2',
          resumeAt: DateTime.now()
              .subtract(const Duration(seconds: 1))
              .toUtc()
              .toIso8601String(),
          actions: ['stop', 'changeProvider'],
        );
        // Seed a `waiting` work item. The orchestrator will restore it
        // and the auto-resume will drive the `waiting -> resuming -> completed`
        // path on a successful stream.
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-c2-1',
            sessionId: 'session-c2',
            requestId: 'req-c2-1',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            payload: const {
              'message': 'Resume me',
              'eventMetadata': {},
              'runId': 'run-c2-1',
            },
            continuationMetadata: const {
              'owner_run_id': 'run-c2-1',
              'owner_generation': 1,
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Contract: the work item remains in the database (never silently
        // dropped) and reaches a terminal `completed` state once the
        // terminal response and history snapshot have been emitted. If the
        // transition were to fire BEFORE the terminal response and the
        // daemon crashed in the gap, the user would lose the result.
        final workItem = repo.findWorkItem('work-c2-1');
        expect(workItem, isNotNull, reason: 'work item must not be deleted');
        expect(
          workItem?.state,
          equals(SessionWorkState.completed),
          reason:
              'Successful resume must end in `completed`. The '
              '`resuming -> completed` transition must happen only after the '
              'terminal response and history snapshot are emitted; if it '
              'happens earlier and the daemon crashes in the gap, the user '
              'loses the result.',
        );
        expect(repo.findActiveWorkItem('session-c2'), isNull);
      },
    );

    test(
      'resuming notice stays visible until the resumed turn shows real progress',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('session-resume-visibility', 'gpt-4o', '2026-07-12', '2026-07-12')",
        );
        repo.upsertNotice(
          sessionId: 'session-resume-visibility',
          requestId: 'req-resume-visible',
          status: 'blocked',
          reason: 'timeout',
          title: 'Request timed out',
          message: 'Retry needed.',
          providerInstanceId: 'prov-visible',
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-resume-visibility',
            sessionId: 'session-resume-visibility',
            requestId: 'req-resume-visible',
            sequence: 0,
            state: SessionWorkState.blocked,
            attempt: 0,
            payload: const {
              'message': 'resume me visibly',
              'eventMetadata': {},
              'runId': 'run-visible',
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final controller = StreamController<String>();
        addTearDown(() async {
          await controller.close();
        });
        when(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => controller.stream);

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        final resumeFuture = orchestrator.resumeSuspended(
          'session-resume-visibility',
          recoveryReason: 'manual_retry',
          recoveryMessage: 'Retrying the last request.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(
          recoveryService.activeNotice('session-resume-visibility')?.status,
          equals(RuntimeNoticeStatus.resuming),
        );
        expect(
          repo.findNotice('session-resume-visibility')?.status,
          equals('resuming'),
        );

        controller.add('first resumed chunk');
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(
          recoveryService.activeNotice('session-resume-visibility'),
          isNull,
        );
        expect(repo.findNotice('session-resume-visibility'), isNull);

        await controller.close();
        await resumeFuture;
      },
    );

    test(
      'a stale blocked durable work item is never overwritten as completed',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('session-stale-block', 'gpt-4o', '2026-07-12', '2026-07-12')",
        );

        when(
          mockAgentRunner.streamMessage(
            any,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            receivedAt: anyNamed('receivedAt'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) async* {
          final activeItem = repo.findActiveWorkItem('session-stale-block');
          expect(activeItem, isNotNull);
          repo.transitionWorkItemState(
            workItemId: activeItem!.workItemId,
            fromState: activeItem.state,
            toState: SessionWorkState.blocked,
          );
          yield 'completed despite stale durable block';
        });

        final orchestrator = SessionRunOrchestrator();
        final responses = <GatewayResponse>[];
        final responseSubscription = orchestrator.responses.listen(
          responses.add,
        );
        addTearDown(responseSubscription.cancel);
        await orchestrator.handleEvent(
          GatewayEvent(
            sessionId: 'session-stale-block',
            platformId: 'test-platform',
            message: Message(
              role: MessageRole.user,
              content: 'finish normally',
            ),
            turnRequest: const AgentTurnRequest(
              sessionId: 'session-stale-block',
              message: 'finish normally',
              requestId: 'req-stale-block',
            ),
          ),
        );

        final item = repo.findAllWorkItems('session-stale-block').single;
        expect(item.state, equals(SessionWorkState.blocked));
        expect(repo.findActiveWorkItem('session-stale-block'), isNotNull);
        expect(recoveryService.hasActiveNotice('session-stale-block'), isFalse);
        expect(
          responses.where(
            (response) =>
                response.message.role == MessageRole.assistant &&
                response.isComplete &&
                !response.isSessionCreated,
          ),
          isEmpty,
          reason:
              'Recovery-owned work must not emit a final answer or a later error.',
        );
      },
    );

    test(
      'durable waiting work queues a new message without an in-memory busy flag',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);
        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-durable-busy', 'gpt-4o', '2026-07-12', '2026-07-12')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-durable-busy',
            sessionId: 'session-durable-busy',
            requestId: 'req-durable-busy',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final orchestrator = SessionRunOrchestrator();
        final responses = <GatewayResponse>[];
        final responseSubscription = orchestrator.responses.listen(
          responses.add,
        );
        addTearDown(responseSubscription.cancel);
        await orchestrator.handleEvent(
          GatewayEvent(
            sessionId: 'session-durable-busy',
            platformId: 'test-platform',
            message: Message(role: MessageRole.user, content: 'queue me'),
            turnRequest: const AgentTurnRequest(
              sessionId: 'session-durable-busy',
              message: 'queue me',
              requestId: 'req-queued-behind-waiting',
              deliveryIntent: MessageDeliveryIntent.queue,
            ),
          ),
        );

        expect(
          repo.findActiveWorkItem('session-durable-busy')?.workItemId,
          'work-durable-busy',
        );
        expect(repo.findQueuedWorkItems('session-durable-busy'), hasLength(1));
        expect(
          responses
              .singleWhere((response) => response.message.content == 'queue me')
              .message
              .metadata?['queued'],
          isTrue,
        );
      },
    );

    test('Gate C.2: a resume that throws keeps the work item reachable so a '
        'later retry or stop can act on it (never silently deleted)', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        ProviderRateLimiter(),
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      var resumeAttempt = 0;
      // First resume attempt throws, second one succeeds on a new route.
      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((invocation) {
        resumeAttempt++;
        if (resumeAttempt == 1) {
          return Stream.error(StateError('resume failed'));
        }
        expect(invocation.namedArguments[#providerId], equals('prov-c2-new'));
        expect(invocation.namedArguments[#model], equals('claude-sonnet'));
        return Stream.value('recovered after second retry');
      });

      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('session-c2-fail', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      repo.upsertNotice(
        sessionId: 'session-c2-fail',
        requestId: 'req-c2-fail',
        runId: 'run-c2-fail',
        status: 'waiting',
        reason: 'rateLimit',
        title: 'Rate limited',
        message: 'waiting',
        providerInstanceId: 'prov-c2',
        resumeAt: DateTime.now()
            .subtract(const Duration(seconds: 1))
            .toUtc()
            .toIso8601String(),
        actions: ['stop', 'changeProvider'],
      );
      // Seed a `waiting` work item so the orchestrator restores it and
      // the auto-resume drives the resume path that throws.
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-c2-fail',
          sessionId: 'session-c2-fail',
          requestId: 'req-c2-fail',
          sequence: 0,
          state: SessionWorkState.waiting,
          attempt: 0,
          payload: const {
            'message': 'Resume me',
            'eventMetadata': {},
            'runId': 'run-c2-fail',
          },
          continuationMetadata: const {
            'owner_run_id': 'run-c2-fail',
            'owner_generation': 1,
          },
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final orchestrator = SessionRunOrchestrator();
      final responses = <GatewayResponse>[];
      final responseSub = orchestrator.responses.listen(responses.add);
      addTearDown(responseSub.cancel);
      await orchestrator.restorePersistedState();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Contract: a failed resume must leave the work item reachable
      // (blocked) and not silently delete it. Without this, a transient
      // failure during resume would lose the user's queued work and a
      // later retry or stop would have nothing to act on.
      final workItem = repo.findWorkItem('work-c2-fail');
      expect(workItem, isNotNull);
      expect(workItem!.state, equals(SessionWorkState.blocked));
      expect(orchestrator.hasSuspendedEvent('session-c2-fail'), isTrue);
      expect(
        recoveryService.activeNotice('session-c2-fail')?.status,
        equals(RuntimeNoticeStatus.blocked),
      );

      final resumed = await orchestrator.resumeSuspended(
        'session-c2-fail',
        providerInstanceId: 'prov-c2-new',
        modelId: 'claude-sonnet',
        recoveryReason: 'manual_retry',
        recoveryMessage: 'Retrying the saved work item.',
      );
      expect(resumed, equals(ResumeSuspendedResult.claimed));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        repo.findWorkItem('work-c2-fail')?.state,
        SessionWorkState.completed,
      );
      expect(orchestrator.hasSuspendedEvent('session-c2-fail'), isFalse);
      expect(
        responses.where(
          (response) =>
              response.message.role == MessageRole.user &&
              response.message.content == 'Resume me',
        ),
        isEmpty,
        reason:
            'A later retry must resume the saved work item directly, not add a new user echo.',
      );
      expect(
        responses.where(
          (response) =>
              response.message.role == MessageRole.assistant &&
              response.message.content == 'recovered after second retry',
        ),
        isNotEmpty,
      );
    });

    test(
      'Gate E.1: restored waiting notice without a suspended owner becomes blocked instead of clearing silently',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        final orchestrator = SessionRunOrchestrator();
        repo.upsertNotice(
          sessionId: 'session-orphan-auto-resume',
          requestId: 'req-orphan-auto-resume',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Rate limited',
          message: 'waiting',
          providerInstanceId: 'prov-orphan',
          resumeAt: DateTime.now()
              .subtract(const Duration(seconds: 1))
              .toUtc()
              .toIso8601String(),
          actions: ['stop', 'changeProvider'],
        );

        recoveryService.restoreActiveNotices();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final notice = recoveryService.activeNotice(
          'session-orphan-auto-resume',
        );
        expect(notice, isNotNull);
        expect(notice!.status, equals(RuntimeNoticeStatus.blocked));
        expect(notice.message, contains('could not find the saved work'));
        expect(
          orchestrator.hasSuspendedEvent('session-orphan-auto-resume'),
          isFalse,
        );
        expect(
          repo.findNotice('session-orphan-auto-resume')?.status,
          equals('blocked'),
        );
      },
    );

    // ── Gate E.1: blocked state restores full action set ────────────────

    test(
      'E.1: blocked notice stays durable-only on startup and is not restored '
      'into live recovery memory',
      () {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);

        addTearDown(stateDb.dispose);

        repo.upsertNotice(
          sessionId: 'session-blocked-actions',
          requestId: 'req-blocked',
          status: 'blocked',
          reason: 'unknown',
          title: 'Blocked',
          message: 'blocked',
          providerInstanceId: 'prov-blocked',
          // Persist only stop — the restore must fill in retry + changeProvider
          actions: ['stop'],
        );

        recoveryService.restoreActiveNotices();

        expect(recoveryService.activeNotice('session-blocked-actions'), isNull);
      },
    );

    // ── Gate E.1: clear/stop removes memory + durable state atomically ──

    test(
      'E.1: requestStop after restart removes in-memory queue, suspended run, '
      'notice, and durable work items atomically',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('session-stop-atomic', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        // Seed a blocked work item + notice
        repo.upsertNotice(
          sessionId: 'session-stop-atomic',
          requestId: 'req-stop',
          status: 'blocked',
          reason: 'unknown',
          title: 'Blocked',
          message: 'blocked',
          providerInstanceId: 'prov-stop',
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-stop',
            sessionId: 'session-stop-atomic',
            requestId: 'req-stop',
            sequence: 0,
            state: SessionWorkState.blocked,
            attempt: 0,
            payload: const {'message': 'Stop me', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-stop-queued',
            sessionId: 'session-stop-atomic',
            requestId: 'req-stop-q',
            sequence: 1,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: const {'message': 'Queued', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        // Verify state exists before stop
        expect(recoveryService.hasActiveNotice('session-stop-atomic'), isFalse);
        expect(repo.findActiveWorkItem('session-stop-atomic'), isNotNull);
        expect(repo.findQueuedWorkItems('session-stop-atomic'), isNotEmpty);

        // Stop
        await orchestrator.requestStop('session-stop-atomic');

        // Memory + durable state must all be cleared
        expect(recoveryService.hasActiveNotice('session-stop-atomic'), isFalse);
        expect(repo.findActiveWorkItem('session-stop-atomic'), isNull);
        expect(repo.findQueuedWorkItems('session-stop-atomic'), isEmpty);
        expect(repo.findNotice('session-stop-atomic'), isNull);
        final allItems = repo.findAllWorkItems('session-stop-atomic');
        for (final item in allItems) {
          expect(
            item.state,
            equals(SessionWorkState.cancelled),
            reason: 'All work items must be cancelled after stop',
          );
        }
      },
    );

    // ── Gate E.2: items restored by sequence ─────────────────────────────

    test(
      'E.2: queued items are restored in FIFO sequence order after restart',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('session-fifo-seq', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        // Insert items out of order to verify sequence-based FIFO.
        // All items will complete normally; we verify call order.
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-fifo-3',
            sessionId: 'session-fifo-seq',
            requestId: 'req-3',
            sequence: 2,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: const {'message': 'Third', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-fifo-1',
            sessionId: 'session-fifo-seq',
            requestId: 'req-1',
            sequence: 0,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: const {'message': 'First', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-fifo-2',
            sessionId: 'session-fifo-seq',
            requestId: 'req-2',
            sequence: 1,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: const {'message': 'Second', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        // Capture call order
        final calls = <String>[];
        when(
          mockAgentRunner.streamMessage(
            any,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            receivedAt: anyNamed('receivedAt'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((inv) {
          calls.add(inv.positionalArguments[0] as String);
          return Stream.value('ok');
        });

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();
        // Wait for all three items to drain sequentially
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Calls must be in FIFO sequence order
        expect(calls, equals(['First', 'Second', 'Third']));

        // All items should be completed
        for (final id in ['work-fifo-1', 'work-fifo-2', 'work-fifo-3']) {
          expect(
            repo.findWorkItem(id)?.state,
            equals(SessionWorkState.completed),
          );
        }
      },
    );

    // ── Gate E.2: only one active/suspended work item per session ────────

    test(
      'E.2: restore picks at most one active/suspended work item per session',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });

        final sessionId = 'session-single-active';
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        // The unique constraint allows only ONE active item per session.
        // Insert a waiting item; the orchestrator should restore exactly
        // one suspended event.
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-active-a',
            sessionId: sessionId,
            requestId: 'req-a',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            payload: const {'message': 'Active A', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        // Only one suspended event should exist
        expect(orchestrator.hasSuspendedEvent(sessionId), isTrue);
        // No extra queued events
        expect(orchestrator.getQueuedEvents(sessionId), isEmpty);
      },
    );

    // ── Gate E.2: FIFO — new message does not jump ahead of older items ─

    test('E.2: a new message arriving after restart does not execute before '
        'older restored queued items (FIFO invariant)', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        stateDb.dispose();
      });

      final sessionId = 'session-fifo-new-msg';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      // Seed one queued item
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-old',
          sessionId: sessionId,
          requestId: 'req-old',
          sequence: 0,
          state: SessionWorkState.queued,
          attempt: 0,
          payload: const {'message': 'Old message', 'eventMetadata': {}},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      // Stub the runner — items complete normally
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('done'));

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The old item should have started draining first
      verify(
        mockAgentRunner.streamMessage(
          'Old message',
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);

      final item = repo.findWorkItem('work-old');
      expect(item?.state, equals(SessionWorkState.completed));
    });

    // ── Gate E.2: change provider/model rewrites all non-terminal work ───

    test('E.2: rewriteQueuedRoute with allNonTerminal updates blocked, waiting, '
        'and queued work items atomically', () {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        stateDb.dispose();
      });

      final sessionId = 'session-route-rewrite';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      // The unique constraint allows only one active item per session, so
      // we test the rewrite across multiple sessions: one queued + one
      // completed in the main session, and separate sessions for waiting
      // and blocked states.
      // Main session: queued + completed
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-q',
          sessionId: sessionId,
          requestId: 'req-work-q',
          sequence: 0,
          state: SessionWorkState.queued,
          attempt: 0,
          providerInstanceId: 'old-provider',
          modelId: 'old-model',
          payload: const {'message': 'test', 'eventMetadata': {}},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-done',
          sessionId: sessionId,
          requestId: 'req-work-done',
          sequence: 1,
          state: SessionWorkState.completed,
          attempt: 0,
          providerInstanceId: 'old-provider',
          modelId: 'old-model',
          payload: const {'message': 'test', 'eventMetadata': {}},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      // Separate session for waiting state
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('session-route-waiting', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-w',
          sessionId: 'session-route-waiting',
          requestId: 'req-work-w',
          sequence: 0,
          state: SessionWorkState.waiting,
          attempt: 0,
          providerInstanceId: 'old-provider',
          modelId: 'old-model',
          payload: const {'message': 'test', 'eventMetadata': {}},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      // Separate session for blocked state
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('session-route-blocked', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-b',
          sessionId: 'session-route-blocked',
          requestId: 'req-work-b',
          sequence: 0,
          state: SessionWorkState.blocked,
          attempt: 0,
          providerInstanceId: 'old-provider',
          modelId: 'old-model',
          payload: const {'message': 'test', 'eventMetadata': {}},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final orchestrator = SessionRunOrchestrator();
      // Rewrite routes for each session
      orchestrator.rewriteQueuedRoute(
        sessionId,
        providerInstanceId: 'new-provider',
        modelId: 'new-model',
        allNonTerminal: true,
      );
      orchestrator.rewriteQueuedRoute(
        'session-route-waiting',
        providerInstanceId: 'new-provider',
        modelId: 'new-model',
        allNonTerminal: true,
      );
      orchestrator.rewriteQueuedRoute(
        'session-route-blocked',
        providerInstanceId: 'new-provider',
        modelId: 'new-model',
        allNonTerminal: true,
      );

      // Non-terminal items should have the new route
      for (final id in ['work-q', 'work-w', 'work-b']) {
        final item = repo.findWorkItem(id);
        expect(item?.providerInstanceId, equals('new-provider'));
        expect(item?.modelId, equals('new-model'));
      }
      // Completed item must remain unchanged
      final done = repo.findWorkItem('work-done');
      expect(done?.providerInstanceId, equals('old-provider'));
      expect(done?.modelId, equals('old-model'));
    });

    // ── Gate E.2: restored notice only appears if runtime owns recovery ──

    test('E.2: restored notice is not surfaced as active when no corresponding '
        'work item exists in the runtime', () {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        ProviderRateLimiter(),
      );
      recoveryService.attachPersistedState(repo);

      addTearDown(stateDb.dispose);

      // Insert a notice with no corresponding session or work item.
      // The recovery service will load it into memory, but the
      // orchestrator's restorePersistedState will not find any work item
      // for that session, so the notice alone does not create a suspended
      // run.
      repo.upsertNotice(
        sessionId: 'session-orphan-notice',
        requestId: 'req-orphan',
        status: 'blocked',
        reason: 'unknown',
        title: 'Orphan',
        message: 'no work item',
      );

      recoveryService.restoreActiveNotices();
      // Blocked notices are durable-only after startup and are not loaded
      // into live recovery memory without a corresponding runtime claim.
      expect(recoveryService.hasActiveNotice('session-orphan-notice'), isFalse);

      // The orchestrator's restore finds no work items → no suspended run
      final sessionIds = repo.findAllSessionIdsWithWorkItems();
      expect(sessionIds, isNot(contains('session-orphan-notice')));
    });

    test(
      'E.2: restored blocked work without a persisted notice becomes a visible '
      'blocked recovery session instead of a hidden owner',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        const sessionId = 'session-hidden-owner';
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('$sessionId', 'gpt-4o', '2026-07-12', '2026-07-12')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-hidden-owner',
            sessionId: sessionId,
            requestId: 'req-hidden-owner',
            sequence: 0,
            state: SessionWorkState.blocked,
            providerInstanceId: 'prov-hidden-owner',
            modelId: 'gpt-4o',
            attempt: 0,
            payload: const {'message': 'restore me', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        when(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('restored safely'));

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        expect(orchestrator.hasSuspendedEvent(sessionId), isTrue);
        expect(recoveryService.activeNotice(sessionId), isNull);
        final notice = repo.findNotice(sessionId);
        expect(notice, isNotNull);
        expect(notice!.status, RuntimeNoticeStatus.blocked.name);
        expect(notice.title, 'Session recovery needs your input');
        expect(notice.actions, contains('stop'));
        expect(notice.actions, contains('retry'));
        expect(
          repo.findNotice(sessionId)?.status,
          equals(RuntimeNoticeStatus.blocked.name),
        );

        final result = await orchestrator.resumeSuspended(
          sessionId,
          recoveryReason: 'manual_retry',
        );
        expect(result, ResumeSuspendedResult.claimed);
        expect(
          repo.findWorkItem('work-hidden-owner')?.state,
          SessionWorkState.completed,
        );
        expect(orchestrator.hasSuspendedEvent(sessionId), isFalse);
        expect(orchestrator.isSessionBusy(sessionId), isFalse);
      },
    );

    // ── Gate E.3: blocked then restart allows Retry ──────────────────────

    test(
      'E.3: blocked session after restart can be retried via resumeSuspended',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        final sessionId = 'session-blocked-retry';
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        repo.upsertNotice(
          sessionId: sessionId,
          requestId: 'req-blocked-retry',
          status: 'blocked',
          reason: 'unknown',
          title: 'Blocked',
          message: 'blocked',
          providerInstanceId: 'prov-blocked-retry',
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-blocked-retry',
            sessionId: sessionId,
            requestId: 'req-blocked-retry',
            sequence: 0,
            state: SessionWorkState.blocked,
            providerInstanceId: 'prov-blocked-retry',
            modelId: 'gpt-4o',
            attempt: 0,
            payload: const {
              'message': 'Retry after block',
              'eventMetadata': {},
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        when(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('retried successfully'));

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        expect(recoveryService.activeNotice(sessionId), isNull);

        // Simulate a retry: resume the suspended run
        final resumed = await orchestrator.resumeSuspended(sessionId);
        expect(resumed, equals(ResumeSuspendedResult.claimed));

        await Future<void>.delayed(const Duration(milliseconds: 100));

        verify(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: 'prov-blocked-retry',
            model: 'gpt-4o',
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).called(1);

        final item = repo.findWorkItem('work-blocked-retry');
        expect(item?.state, equals(SessionWorkState.completed));
      },
    );

    // ── Gate E.3: blocked then restart allows Change Provider ────────────

    test(
      'E.3: blocked session after restart can change provider and resume with '
      'the new route',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final mockProviderRepo = MockProviderInstanceRepository();
        when(mockProviderRepo.findById('new-provider-instance')).thenReturn(
          ProviderInstance(
            id: 'new-provider-instance',
            templateId: 'anthropic',
            displayName: 'Claude',
            protocol: ProviderProtocol.anthropicCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'claude-sonnet',
            status: InstanceStatus.ready,
            configRevision: 1,
            credentialRevision: 1,
            requestsPerMinute: 0,
            allowAutoFailover: true,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        GetIt.I.registerSingleton<ProviderInstanceRepository>(mockProviderRepo);

        final recoveryService = RuntimeRecoveryService(
          mockProviderRepo,
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          GetIt.I.unregister<ProviderInstanceRepository>();
          stateDb.dispose();
        });

        final sessionId = 'session-blocked-change';
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        repo.upsertNotice(
          sessionId: sessionId,
          requestId: 'req-change',
          status: 'blocked',
          reason: 'unknown',
          title: 'Blocked',
          message: 'blocked',
          providerInstanceId: 'old-provider',
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-blocked-change',
            sessionId: sessionId,
            requestId: 'req-change',
            sequence: 0,
            state: SessionWorkState.blocked,
            providerInstanceId: 'old-provider',
            modelId: 'gpt-4o',
            attempt: 0,
            payload: const {'message': 'Change provider', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        when(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('changed provider ok'));

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();

        expect(recoveryService.activeNotice(sessionId), isNull);

        // Resume with the new provider
        final resumed = await orchestrator.resumeSuspended(
          sessionId,
          providerInstanceId: 'new-provider-instance',
          modelId: 'claude-sonnet',
        );
        expect(resumed, equals(ResumeSuspendedResult.claimed));

        await Future<void>.delayed(const Duration(milliseconds: 100));

        verify(
          mockAgentRunner.resumeStream(
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: 'new-provider-instance',
            model: 'claude-sonnet',
            thinkingMode: anyNamed('thinkingMode'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).called(1);

        final item = repo.findWorkItem('work-blocked-change');
        expect(item?.state, equals(SessionWorkState.completed));
      },
    );

    // ── Gate E.3: waiting 5h then restart restores notice + timer ────────

    test('E.3: a five-hour waiting notice restores its timer and notice after '
        'restart (long-duration resume_at)', () {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final limiter = ProviderRateLimiter();
      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        limiter,
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      final sessionId = 'session-5h-wait';
      final resumeAt = DateTime.now().add(const Duration(hours: 5));

      repo.upsertNotice(
        sessionId: sessionId,
        requestId: 'req-5h',
        status: 'waiting',
        reason: 'rateLimit',
        title: 'Rate limited',
        message: 'waiting 5 hours',
        providerInstanceId: 'prov-5h',
        resumeAt: resumeAt.toUtc().toIso8601String(),
        actions: ['stop', 'changeProvider'],
      );

      recoveryService.restoreActiveNotices();

      // Notice must be active
      expect(recoveryService.hasActiveNotice(sessionId), isTrue);
      final notice = recoveryService.activeNotice(sessionId);
      expect(notice?.status, equals(RuntimeNoticeStatus.waiting));
      expect(notice?.resumeAt, isNotNull);

      // Provider cooldown must reflect the ~5h remaining duration
      final permit = limiter.tryAcquire('prov-5h', 1);
      expect(permit.granted, isFalse);
      expect(
        permit.retryAfter.inHours,
        greaterThanOrEqualTo(4),
        reason: 'Cooldown should reflect the long remaining duration',
      );
    });

    // ── Gate E.3: Stop after restart clears active/queue/notice ──────────

    test(
      'E.3: Stop after restart broadcasts stopped/cleared and clears all work',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        final sessionId = 'session-stop-restart';
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        repo.upsertNotice(
          sessionId: sessionId,
          requestId: 'req-stop-r',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Wait',
          message: 'waiting',
          providerInstanceId: 'prov-stop-r',
          resumeAt: DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-stop-r',
            sessionId: sessionId,
            requestId: 'req-stop-r',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            payload: const {
              'message': 'Stop after restart',
              'eventMetadata': {},
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-stop-r-q',
            sessionId: sessionId,
            requestId: 'req-stop-r-q',
            sequence: 1,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: const {'message': 'Queued', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final orchestrator = SessionRunOrchestrator();
        final responses = <GatewayResponse>[];
        final sub = orchestrator.responses.listen(responses.add);
        addTearDown(sub.cancel);

        await orchestrator.restorePersistedState();

        // Stop via the event path (simulates client sending stop)
        await orchestrator.handleEvent(
          GatewayEvent(
            sessionId: sessionId,
            platformId: 'test',
            type: 'stop',
            message: Message(role: MessageRole.user, content: ''),
          ),
        );

        // Notice cleared
        expect(recoveryService.hasActiveNotice(sessionId), isFalse);
        // Durable work all cancelled
        final active = repo.findActiveWorkItem(sessionId);
        expect(active, isNull);
        final queued = repo.findQueuedWorkItems(sessionId);
        expect(queued, isEmpty);
        expect(repo.findNotice(sessionId), isNull);

        // A stopped event was emitted
        final stoppedEvent = responses.lastWhere(
          (r) => r.message.metadata?['canonical_event_type'] == 'stopped',
          orElse: () => throw StateError('No stopped event emitted'),
        );
        expect(stoppedEvent.sessionId, equals(sessionId));

        // Session is now idle — a new message should not be blocked
        expect(orchestrator.isSessionBusy(sessionId), isFalse);
      },
    );

    // ── Gate E.3: crash during running does not lose or duplicate work ───

    test(
      'E.3: a crashed running work item with no executing tools is re-queued '
      'on restart (no loss, no duplication)',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });

        final sessionId = 'session-crash-running';
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        // A running item with no executing tools → safe to re-queue
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-crash-run',
            sessionId: sessionId,
            requestId: 'req-crash',
            sequence: 0,
            state: SessionWorkState.running,
            attempt: 0,
            payload: const {'message': 'Crashed mid-run', 'eventMetadata': {}},
            continuationMetadata: const {
              'currently_executing_tools': [],
              'completed_tool_results': {},
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        // Stub runner so the re-queued item processes
        when(
          mockAgentRunner.streamMessage(
            any,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            receivedAt: anyNamed('receivedAt'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) => Stream.value('recovered'));

        final orchestrator = SessionRunOrchestrator();
        await orchestrator.restorePersistedState();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // The work item was re-queued, then drained and completed
        final item = repo.findWorkItem('work-crash-run');
        expect(item, isNotNull);
        expect(item?.state, equals(SessionWorkState.completed));

        // Only one execution happened (no duplication)
        verify(
          mockAgentRunner.streamMessage(
            'Crashed mid-run',
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            providerId: anyNamed('providerId'),
            model: anyNamed('model'),
            thinkingMode: anyNamed('thinkingMode'),
            receivedAt: anyNamed('receivedAt'),
            onToolEvent: anyNamed('onToolEvent'),
            onSteerContinuation: anyNamed('onSteerContinuation'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).called(1);
      },
    );

    test('E.3: a controlled restart resumes an after-tool checkpoint without '
        'replaying the original message', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        stateDb.dispose();
      });

      const sessionId = 'session-controlled-restart';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-controlled-restart',
          sessionId: sessionId,
          requestId: 'req-controlled-restart',
          sequence: 0,
          state: SessionWorkState.running,
          attempt: 0,
          payload: const {
            'message': 'Restart the agent and confirm completion',
            'eventMetadata': {},
          },
          continuationMetadata: const {
            'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
            'resume_history_length': 2,
            'currently_executing_tools': [],
            'completed_tool_results': {
              'restart-call': {'output': 'Daemon exiting for restart...'},
            },
          },
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('Restart completed'));

      final orchestrator = SessionRunOrchestrator();
      final emittedResponses = <GatewayResponse>[];
      final responseSubscription = orchestrator.responses.listen(
        emittedResponses.add,
      );
      addTearDown(responseSubscription.cancel);
      await orchestrator.restorePersistedState();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        repo.findWorkItem('work-controlled-restart')?.state,
        SessionWorkState.completed,
      );
      verify(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);
      verifyNever(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      );
      expect(
        emittedResponses.where(
          (response) => response.message.role == MessageRole.user,
        ),
        isEmpty,
        reason: 'resuming a checkpoint must not echo the user message again',
      );
    });

    test('E.3: startup checkpoint auto-resume emits a visible resuming notice '
        'before the resumed turn makes progress', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        ProviderRateLimiter(),
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      const sessionId = 'session-visible-auto-resume';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-12', '2026-07-12')",
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-visible-auto-resume',
          sessionId: sessionId,
          requestId: 'req-visible-auto-resume',
          sequence: 0,
          state: SessionWorkState.running,
          attempt: 0,
          payload: const {
            'message': 'resume after restart',
            'eventMetadata': {},
          },
          continuationMetadata: const {
            'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
            'resume_history_length': 2,
            'currently_executing_tools': [],
            'completed_tool_results': {
              'checkpoint-tool': {'output': 'done'},
            },
          },
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) async* {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        yield 'first restored chunk';
      });

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        recoveryService.activeNotice(sessionId)?.status,
        RuntimeNoticeStatus.resuming,
      );
      expect(
        repo.findNotice(sessionId)?.status,
        RuntimeNoticeStatus.resuming.name,
      );

      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(
        repo.findWorkItem('work-visible-auto-resume')?.state,
        SessionWorkState.completed,
      );
    });

    test('E.3: safely owned interrupted resuming work auto-resumes after '
        'startup instead of becoming blocked', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        ProviderRateLimiter(),
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      const sessionId = 'session-owned-interrupted-resuming';
      const runId = 'run-owned-interrupted-resuming';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-12', '2026-07-12')",
      );
      repo.upsertNotice(
        sessionId: sessionId,
        requestId: 'req-owned-interrupted-resuming',
        runId: runId,
        status: 'resuming',
        reason: 'daemon_restart',
        title: 'Resume interrupted by restart',
        message: 'The new daemon should reclaim this checkpoint.',
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-owned-interrupted-resuming',
          sessionId: sessionId,
          requestId: 'req-owned-interrupted-resuming',
          sequence: 0,
          state: SessionWorkState.resuming,
          attempt: 0,
          payload: const {
            'message': 'continue after controlled restart',
            'eventMetadata': {},
          },
          continuationMetadata: const {
            'owner_run_id': runId,
            'owner_generation': 4,
            'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
            'resume_history_length': 2,
            'currently_executing_tools': [],
            'completed_tool_results': {
              'restart-call': {'output': 'Daemon exiting for restart...'},
            },
          },
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('resumed after controlled restart'));

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        repo.findWorkItem('work-owned-interrupted-resuming')?.state,
        SessionWorkState.completed,
      );
      expect(orchestrator.hasSuspendedEvent(sessionId), isFalse);
      verify(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).called(1);
    });

    test('E.3: legacy interrupted resuming checkpoint without an owner is '
        'blocked instead of auto-resuming ambiguously', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        ProviderRateLimiter(),
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      const sessionId = 'session-interrupted-resuming';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-12', '2026-07-12')",
      );
      repo.upsertNotice(
        sessionId: sessionId,
        requestId: 'req-interrupted-resume',
        status: 'blocked',
        reason: 'unknown',
        title: 'Session recovery needs your input',
        message: 'stale blocked notice',
        actions: ['stop', 'retry', 'changeProvider'],
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-interrupted-resume',
          sessionId: sessionId,
          requestId: 'req-interrupted-resume',
          sequence: 0,
          state: SessionWorkState.resuming,
          attempt: 0,
          payload: const {
            'message': 'continue after restart',
            'eventMetadata': {},
          },
          continuationMetadata: const {
            'checkpoint_kind': AgentRunner.checkpointKindInitialModelRequest,
            'resume_history_length': 3,
            'currently_executing_tools': [],
            'completed_tool_results': {},
          },
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      when(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((_) => Stream.value('resumed after second restart'));

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        repo.findWorkItem('work-interrupted-resume')?.state,
        SessionWorkState.blocked,
      );
      expect(repo.findNotice(sessionId)?.status, 'blocked');
      expect(orchestrator.hasSuspendedEvent(sessionId), isTrue);
      expect(orchestrator.isSessionBusy(sessionId), isTrue);
      verifyNever(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      );
    });

    test('E.3: interrupted resuming work with an unsafe executing tool is '
        'blocked and never auto-resumed', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      final recoveryService = RuntimeRecoveryService(
        MockProviderInstanceRepository(),
        ProviderRateLimiter(),
      );
      recoveryService.attachPersistedState(repo);
      GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        GetIt.I.unregister<RuntimeRecoveryService>();
        stateDb.dispose();
      });

      const sessionId = 'session-unsafe-interrupted-resume';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-12', '2026-07-12')",
      );
      repo.upsertNotice(
        sessionId: sessionId,
        requestId: 'req-unsafe-interrupted-resume',
        status: 'resuming',
        reason: 'daemon_restart',
        title: 'Stale resume in progress',
        message: 'This notice must become blocked after safety validation.',
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-unsafe-interrupted-resume',
          sessionId: sessionId,
          requestId: 'req-unsafe-interrupted-resume',
          sequence: 0,
          state: SessionWorkState.resuming,
          attempt: 0,
          payload: const {
            'message': 'do not replay the unsafe tool',
            'eventMetadata': {},
          },
          continuationMetadata: const {
            'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
            'resume_history_length': 3,
            'currently_executing_tools': ['unsafe-tool-call'],
            'tool_replay_safety': {'unsafe-tool-call': false},
            'completed_tool_results': {},
          },
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        repo.findWorkItem('work-unsafe-interrupted-resume')?.state,
        SessionWorkState.blocked,
      );
      expect(repo.findNotice(sessionId)?.status, 'blocked');
      expect(orchestrator.hasSuspendedEvent(sessionId), isTrue);
      verifyNever(
        mockAgentRunner.resumeStream(
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      );
    });

    // ── Gate E.3: queue-only crash does not reverse FIFO ─────────────────

    test('E.3: queue-only crash recovery drains items in FIFO order without '
        'reversing', () async {
      final stateDb = AgentStateDatabase.inMemory();
      final repo = PersistedRuntimeStateRepository(stateDb.db);

      GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
      GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

      addTearDown(() {
        GetIt.I.unregister<AgentStateDatabase>();
        GetIt.I.unregister<PersistedRuntimeStateRepository>();
        stateDb.dispose();
      });

      final sessionId = 'session-queue-crash-fifo';
      stateDb.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      // Insert 3 queued items
      for (var i = 0; i < 3; i++) {
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-qcrash-$i',
            sessionId: sessionId,
            requestId: 'req-qcrash-$i',
            sequence: i,
            state: SessionWorkState.queued,
            attempt: 0,
            payload: {'message': 'Message $i', 'eventMetadata': {}},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
      }

      // Capture call order — items complete normally
      final calls = <String>[];
      when(
        mockAgentRunner.streamMessage(
          any,
          runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
          providerId: anyNamed('providerId'),
          model: anyNamed('model'),
          thinkingMode: anyNamed('thinkingMode'),
          receivedAt: anyNamed('receivedAt'),
          onToolEvent: anyNamed('onToolEvent'),
          onSteerContinuation: anyNamed('onSteerContinuation'),
          onThoughtDelta: anyNamed('onThoughtDelta'),
          onReasoningDelta: anyNamed('onReasoningDelta'),
        ),
      ).thenAnswer((inv) {
        calls.add(inv.positionalArguments[0] as String);
        return Stream.value('ok');
      });

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();
      // Wait for all three items to drain sequentially
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // All items must be drained in FIFO order
      expect(calls, equals(['Message 0', 'Message 1', 'Message 2']));

      for (var i = 0; i < 3; i++) {
        expect(
          repo.findWorkItem('work-qcrash-$i')?.state,
          equals(SessionWorkState.completed),
        );
      }
    });
  });

  group('Gate F: Production Activation and startup fallback', () {
    test(
      'restore failure fallback blocks persisted work instead of leaving it silent',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-startup-failure', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-startup-failure',
            sessionId: 'session-startup-failure',
            requestId: 'req-startup-failure',
            sequence: 1,
            state: SessionWorkState.running,
            providerInstanceId: 'provider-failure',
            attempt: 0,
            payload: const {'message': 'recover me'},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final orchestrator = SessionRunOrchestrator();
        orchestrator.markRestoreFailureAsBlocked(error: StateError('boom'));

        final workItem = repo.findWorkItem('work-startup-failure');
        expect(workItem?.state, equals(SessionWorkState.blocked));
        expect(
          recoveryService.hasActiveNotice('session-startup-failure'),
          isTrue,
        );
        expect(
          recoveryService.activeNotice('session-startup-failure')?.status,
          equals(RuntimeNoticeStatus.blocked),
        );
      },
    );

    test(
      'restore failure fallback ignores sessions with only terminal history',
      () async {
        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);

        GetIt.I.registerSingleton<AgentStateDatabase>(stateDb);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);

        final recoveryService = RuntimeRecoveryService(
          MockProviderInstanceRepository(),
          ProviderRateLimiter(),
        );
        recoveryService.attachPersistedState(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

        addTearDown(() {
          GetIt.I.unregister<AgentStateDatabase>();
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          GetIt.I.unregister<RuntimeRecoveryService>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('session-terminal-history', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-terminal-history',
            sessionId: 'session-terminal-history',
            sequence: 1,
            state: SessionWorkState.completed,
            attempt: 0,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        SessionRunOrchestrator().markRestoreFailureAsBlocked(
          error: StateError('boom'),
        );

        expect(repo.findNotice('session-terminal-history'), isNull);
        expect(
          recoveryService.hasActiveNotice('session-terminal-history'),
          isFalse,
        );
      },
    );
  });
}

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  _NoopMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async {
    return const [];
  }
}

class MockProviderInstanceRepository extends Mock
    implements ProviderInstanceRepository {}
