/// Task 125 (G2 defect 1): a turn that fails before the engine's typed
/// recovery must never hold the session queue.
///
/// Drives the real `SessionRunOrchestrator` admission path, the real
/// `SessionTurnExecutor`, `AgentRunner`, `LocalRuntimeOrchestrator`,
/// `RuntimeRecoveryService` and the SQLite-backed durable execution state. The
/// pre-start failure is a real one: the turn names an execution root whose
/// directory no longer exists, so runtime-context construction throws before
/// any provider call.
library;

import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/session_turn_executor.dart';
import 'package:test/test.dart';

class _RecordingAdapter implements LLMAdapter {
  int calls = 0;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    calls++;
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'ok'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(history, options: options);
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];
}

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  _NoopMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}

void main() {
  const providerId = 'inst-g2';
  const modelId = 'g2-model';

  late Directory tempDir;
  late String missingExecutionRoot;
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository runtime;
  late SessionManager sessions;
  late RuntimeRecoveryService recovery;
  late _RecordingAdapter adapter;
  late SessionRunOrchestrator orchestrator;
  late List<GatewayResponse> responses;
  late StreamSubscription<GatewayResponse> responseSub;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('g2_pre_start_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    final gone = Directory('${tempDir.path}/deleted-root')..createSync();
    missingExecutionRoot = gone.path;
    gone.deleteSync();
    setSanadHomeOverride(tempDir.path);
    await getIt.reset();
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;

    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    runtime = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(runtime);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    repo.createInstance(
      ProviderInstance(
        id: providerId,
        templateId: kCustomProviderTemplateId,
        displayName: 'G2 provider',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: modelId,
        status: InstanceStatus.ready,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    sessions = SessionManager();
    getIt.registerSingleton<SessionManager>(sessions);
    getIt.registerSingleton<Config>(Config());
    recovery = RuntimeRecoveryService(repo, ProviderRateLimiter())
      ..attachPersistedState(runtime);
    getIt.registerSingleton<RuntimeRecoveryService>(recovery);

    final workspace = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
    );
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
    final catalog = LocalRuntimeCatalog(
      workspaceRuntimeService: workspace,
      mcpRuntimeManager: _NoopMcpRuntimeManager(),
    );
    getIt.registerSingleton<LocalRuntimeCatalog>(catalog);
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(workspace, catalog),
    );

    adapter = _RecordingAdapter();
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (sessionId, _) => AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: sessionId,
      ),
    );
    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
    responses = [];
    responseSub = orchestrator.responses.listen(responses.add);
  });

  tearDown(() async {
    await responseSub.cancel();
    await getIt.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  AgentTurnRequest request(
    String sessionId,
    String requestId, {
    String message = 'hi',
    String? executionRoot,
  }) => AgentTurnRequest(
    sessionId: sessionId,
    message: message,
    providerInstanceId: providerId,
    model: modelId,
    requestId: requestId,
    metadata: {'execution_root': ?executionRoot},
  );

  GatewayEvent think(
    String sessionId,
    String requestId, {
    String message = 'hi',
    String? executionRoot,
  }) => GatewayEvent(
    sessionId: sessionId,
    platformId: 'client',
    message: Message(role: MessageRole.user, content: message),
    runId: requestId,
    turnRequest: request(
      sessionId,
      requestId,
      message: message,
      executionRoot: executionRoot,
    ),
  );

  Future<void> createSession(String sessionId) => orchestrator.handleEvent(
    GatewayEvent(
      sessionId: sessionId,
      platformId: 'client',
      type: 'create_session',
      message: Message(role: MessageRole.user, content: ''),
      metadata: {
        'payload': {'request_id': 'create-$sessionId'},
      },
      runId: 'create-$sessionId',
      turnRequest: request(sessionId, 'create-$sessionId', message: ''),
    ),
  );

  Future<GatewayResponse> terminalFor(String runId) async {
    for (var i = 0; i < 400; i++) {
      final terminal = responses.where(
        (r) =>
            r.isComplete &&
            !r.isSessionCreated &&
            r.message.role == MessageRole.assistant &&
            r.runId == runId,
      );
      if (terminal.isNotEmpty) return terminal.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no terminal response for $runId');
  }

  List<String> classifications(String requestId) => responses
      .where(
        (r) =>
            r.message.metadata?['canonical_event_type'] ==
                'session.message_classified' &&
            (r.message.metadata?['canonical_payload'] as Map?)?['request_id'] ==
                requestId,
      )
      .map(
        (r) =>
            (r.message.metadata!['canonical_payload'] as Map)['classification']
                as String,
      )
      .toList();

  test(
    'a pre-start failure terminalizes its own work item with a typed outcome '
    'and the next message runs instead of queuing forever',
    () async {
      const sessionId = 's-g2-pre-start';
      await createSession(sessionId);

      await orchestrator.handleEvent(
        think(sessionId, 'req-fails', executionRoot: missingExecutionRoot),
      );
      final failed = await terminalFor('req-fails');

      // A typed terminal outcome the Client and CLI can show.
      expect(failed.message.metadata?['error_code'], 'turn_failed');
      expect(failed.message.content, startsWith('Error:'));
      expect(adapter.calls, 0, reason: 'the failure happened before dispatch');

      // Durable state: the failed owner is terminal, nothing holds the queue.
      final failedItem = runtime.workItems.findByRequestId(
        sessionId,
        'req-fails',
      );
      expect(failedItem?.state, SessionWorkState.cancelled);
      expect(runtime.findActiveWorkItem(sessionId), isNull);
      expect(orchestrator.isSessionBusy(sessionId), isFalse);
      expect(
        recovery.activeNotice(sessionId),
        isNull,
        reason: 'no blocked notice advertises a Retry that cannot work',
      );

      // The next message is admitted and executed, not queued behind it.
      await orchestrator.handleEvent(think(sessionId, 'req-next'));
      final next = await terminalFor('req-next');
      expect(next.message.metadata?['error_code'], isNull);
      expect(next.message.content, contains('ok'));
      expect(classifications('req-next'), ['think']);
      expect(adapter.calls, 1);
      expect(
        runtime.workItems.findByRequestId(sessionId, 'req-next')?.state,
        SessionWorkState.completed,
      );
    },
  );

  test('work queued behind a pre-start failure drains in FIFO order', () async {
    const sessionId = 's-g2-fifo';
    await createSession(sessionId);

    // Hold the session busy so the failing turn and its follow-up queue in
    // order, then release it and let the queue drain.
    orchestrator.debugMarkSessionBusy(sessionId);
    await orchestrator.handleEvent(
      think(sessionId, 'req-q-fails', executionRoot: missingExecutionRoot),
    );
    await orchestrator.handleEvent(think(sessionId, 'req-q-next'));
    await Future<void>.delayed(Duration.zero);
    expect(classifications('req-q-fails'), ['queue']);
    expect(classifications('req-q-next'), ['queue']);
    orchestrator.debugClearSessionBusy(sessionId);
    orchestrator.debugExitCompactionBarrier(sessionId);

    final failed = await terminalFor('req-q-fails');
    expect(failed.message.metadata?['error_code'], 'turn_failed');
    final next = await terminalFor('req-q-next');
    expect(next.message.content, contains('ok'));
    expect(
      runtime.workItems.findByRequestId(sessionId, 'req-q-fails')?.state,
      SessionWorkState.cancelled,
    );
    expect(
      runtime.workItems.findByRequestId(sessionId, 'req-q-next')?.state,
      SessionWorkState.completed,
    );
    expect(runtime.findActiveWorkItem(sessionId), isNull);
  });

  test('a failed resume stays blocked but resumable: the orchestrator records '
      'the suspended state so Retry can claim it', () async {
    final sessionId = sessions
        .createSession(modelId, providerId: providerId)
        .sessionId;
    runtime.admitWorkItem(
      workItemId: 'work-resume',
      sessionId: sessionId,
      requestId: 'req-resume',
      providerInstanceId: providerId,
      modelId: modelId,
      payload: {'message': 'resume me'},
    );
    final recorded = <String?>[];
    final executor = SessionTurnExecutor(
      emitResponse: responses.add,
      getPersistedState: () => runtime,
    );
    final resumeRequest = request(
      sessionId,
      'req-resume',
      message: 'resume me',
      executionRoot: missingExecutionRoot,
    );
    await executor.runTurn(
      event: think(
        sessionId,
        'req-resume',
        message: 'resume me',
        executionRoot: missingExecutionRoot,
      ),
      turnRequest: resumeRequest,
      agentRunner: getIt<AgentRunner>(param1: sessionId),
      workItemId: 'work-resume',
      isResume: true,
      onRecoveryRequired: (_, request, _, workItemId) =>
          recorded.add(workItemId),
      onTurnComplete: () {},
    );

    expect(
      runtime.findWorkItem('work-resume')?.state,
      SessionWorkState.blocked,
    );
    expect(
      recovery.activeNotice(sessionId)?.status,
      RuntimeNoticeStatus.blocked,
    );
    expect(recorded, [
      'work-resume',
    ], reason: 'a blocked resume must own a SuspendedRun so Retry works');
  });
}
