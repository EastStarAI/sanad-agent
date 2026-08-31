import 'dart:async';

import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

import 'compaction_queue_integration_test.mocks.dart';

@GenerateMocks([AgentRunner, SessionManager, TitleService])
void main() {
  late MockAgentRunner mockAgentRunner;
  late MockSessionManager mockSessionManager;
  late SessionRunOrchestrator orchestrator;

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

  setUp(() {
    getIt.allowReassignment = true;
    mockAgentRunner = MockAgentRunner();
    mockSessionManager = MockSessionManager();

    when(mockAgentRunner.registry).thenReturn(ToolsRegistry());
    when(mockAgentRunner.accumulatedUsage).thenReturn(const {
      'prompt_tokens': 0,
      'completion_tokens': 0,
      'total_tokens': 0,
    });
    when(mockAgentRunner.lastUsage).thenReturn(const {
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
    when(mockAgentRunner.getContextUsageSnapshot()).thenAnswer((_) async => null);
    when(
      mockAgentRunner.attachMetadataToLastAssistantMessage(any),
    ).thenReturn(null);
    when(mockAgentRunner.requestStop()).thenReturn(null);
    when(mockAgentRunner.beginAuthoritativeRun(
      any,
      workItemId: anyNamed('workItemId'),
      generation: anyNamed('generation'),
    )).thenReturn(null);
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
    when(mockAgentRunner.setTurnRequestId(any)).thenReturn(null);

    when(mockSessionManager.getSession(any)).thenReturn(
      SessionState(
        sessionId: 'session-compact-queue',
        model: 'gpt-4o',
        createdAt: DateTime.utc(2026, 8, 29),
        updatedAt: DateTime.utc(2026, 8, 29),
        lastUserMessageAt: DateTime.utc(2026, 8, 29),
      ),
    );
    when(mockSessionManager.recordCanonicalUserMessageAccepted(any, any))
        .thenReturn(null);
    when(mockSessionManager.saveSessionMetadata(any, any)).thenReturn(null);
    when(mockSessionManager.getSessionMetadata(any)).thenReturn(null);
    when(mockSessionManager.getInFlightSnapshot(any)).thenReturn(null);
    when(mockSessionManager.saveInFlightSnapshot(any, any)).thenReturn(null);
    when(mockSessionManager.clearInFlightSnapshot(any)).thenReturn(null);

    getIt.registerSingleton<SessionManager>(mockSessionManager);
    getIt.registerSingleton<TitleService>(MockTitleService());
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      LocalWorkspaceRuntimeService(
        sanadHomePath: '/tmp/sanad-compaction-queue-test',
        currentWorkingDirectory: '/tmp/sanad-compaction-queue-test',
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
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (sessionId, _) => mockAgentRunner,
    );

    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
  });

  tearDown(() async {
    await getIt.reset();
  });

  test('queues user messages while compaction barrier is active', () async {
    orchestrator.debugEnterCompactionBarrier('session-compact-queue');

    await orchestrator.handleEvent(
      GatewayEvent(
        sessionId: 'session-compact-queue',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'During compact'),
        turnRequest: AgentTurnRequest(
          sessionId: 'session-compact-queue',
          message: 'During compact',
          requestId: 'queued-during-compact',
          deliveryIntent: MessageDeliveryIntent.auto,
        ),
      ),
    );

    expect(orchestrator.isSessionCompacting('session-compact-queue'), isTrue);
    expect(orchestrator.getQueuedEvents('session-compact-queue').length, 1);
    expect(
      orchestrator.getQueuedEvents('session-compact-queue').first.message.content,
      'During compact',
    );
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
  });

  test('drains queued messages FIFO after compaction barrier clears', () async {
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

    orchestrator.debugEnterCompactionBarrier('session-compact-queue');
    await orchestrator.handleEvent(
      GatewayEvent(
        sessionId: 'session-compact-queue',
        platformId: 'test-platform',
        message: Message(role: MessageRole.user, content: 'Queued one'),
        turnRequest: AgentTurnRequest(
          sessionId: 'session-compact-queue',
          message: 'Queued one',
          requestId: 'queued-one',
        ),
      ),
    );
    expect(orchestrator.getQueuedEvents('session-compact-queue').length, 1);

    orchestrator.debugExitCompactionBarrier('session-compact-queue');
    await pump();

    expect(orchestrator.getQueuedEvents('session-compact-queue'), isEmpty);
    verify(
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
    ).called(1);

    completer.complete('done');
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
