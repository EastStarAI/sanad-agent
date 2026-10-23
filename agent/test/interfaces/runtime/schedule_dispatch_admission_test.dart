/// Schedule dispatch delivery (Task 139 Delta 1).
///
/// A schedule dispatch must always become **its own turn** — an immediate turn
/// when the conversation is idle, a queued turn that runs after the active one
/// when it is busy — and never a mid-turn steer.
///
/// The distinction is not cosmetic. A steered event never commits a root user
/// message row for its request identity, so `ScheduleRunObserver` can neither
/// anchor nor terminalize the run: the row would stay `running` forever with
/// `session_id`, `message_id`, and `duration_ms` NULL, and the run history could
/// never show an outcome or an "Open conversation" position.
///
/// These tests drive the real `SessionRunOrchestrator` admission and turn path
/// with a real `CronScheduler`, durable execution state, and a gated adapter, so
/// the whole correlation is exercised end to end.
library;

import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/schedule_task_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

/// Holds the first turn open so a dispatch can arrive while it is active.
///
/// The gate is opt-in: only a test that needs an active turn installs it, so a
/// schedule turn in an idle conversation is never held.
class _GatedAdapter implements LLMAdapter {
  Completer<void>? holdFirstTurn;
  int calls = 0;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    calls++;
    if (calls == 1) await holdFirstTurn?.future;
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
  const providerId = 'inst-schedule-dispatch';
  const modelId = 'schedule-dispatch-model';
  const activeRequestId = 'req-active-turn';

  late Directory tempDir;
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository runtime;
  late SessionManager sessions;
  late _GatedAdapter adapter;
  late SessionRunOrchestrator orchestrator;
  late CronScheduler scheduler;
  late List<GatewayEvent> dispatchedEvents;
  late StreamSubscription<GatewayEvent> schedulerSub;
  late List<GatewayResponse> responses;
  late StreamSubscription<GatewayResponse> responseSub;
  late String sessionId;

  /// The active turn's admission future, which completes when that turn ends.
  late Future<void> activeTurn;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('schedule_dispatch_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
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
        displayName: 'Schedule dispatch provider',
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
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(repo, ProviderRateLimiter())
        ..attachPersistedState(runtime),
    );

    final workspace = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
    );
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
    getIt.registerSingleton<LocalRuntimeCatalog>(
      LocalRuntimeCatalog(
        workspaceRuntimeService: workspace,
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      ),
    );
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(workspace, getIt<LocalRuntimeCatalog>()),
    );

    adapter = _GatedAdapter();
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (runnerSessionId, _) => AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: runnerSessionId,
      ),
    );
    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
    responses = [];
    responseSub = orchestrator.responses.listen(responses.add);

    final now = DateTime.utc(2026, 10, 24);
    sessionId = sessions.createSession(modelId, providerId: providerId).sessionId;
    sessions.db.saveSession(
      SessionState(
        sessionId: sessionId,
        model: modelId,
        providerId: providerId,
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );

    // The scheduler is the only writer of a run row and the only owner of its
    // turn correlation; it shares the one state connection the orchestrator
    // writes, so the run rows and the durable work items are the same database.
    scheduler = CronScheduler(sessionManager: sessions, db: sessions.db);
    getIt.registerSingleton<CronScheduler>(scheduler);
    await scheduler.initialize();
    dispatchedEvents = [];
    schedulerSub = scheduler.eventStream.listen(dispatchedEvents.add);
  });

  tearDown(() async {
    await schedulerSub.cancel();
    await scheduler.dispose();
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

  Future<void> waitFor(
    bool Function() condition, {
    required String reason,
    int attempts = 600,
  }) async {
    for (var i = 0; i < attempts && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: reason);
  }

  List<Map<String, dynamic>> canonical(String type, String requestId) =>
      responses
          .where(
            (response) =>
                response.message.metadata?['canonical_event_type'] == type &&
                (response.message.metadata?['canonical_payload']
                        as Map?)?['request_id'] ==
                    requestId,
          )
          .map(
            (response) => Map<String, dynamic>.from(
              response.message.metadata!['canonical_payload'] as Map,
            ),
          )
          .toList();

  List<String> classifications(String requestId) => canonical(
    'session.message_classified',
    requestId,
  ).map((payload) => payload['classification'] as String).toList();

  bool queuedEchoFor(String requestId) => responses.any(
    (response) =>
        response.message.metadata?['queued'] == true &&
        response.message.metadata?['request_id'] == requestId,
  );

  ScheduledTaskRun runRowOf(String scheduleId) =>
      sessions.db.scheduledTaskRuns.listRuns(scheduleId).runs.single;

  /// Starts one real turn and leaves it active on the adapter gate.
  ///
  /// The orchestrator's admission future completes with the turn itself, so it
  /// is held rather than awaited here; [finishActiveTurn] releases it.
  Future<void> startActiveTurn() async {
    adapter.holdFirstTurn = Completer<void>();
    activeTurn = orchestrator.handleEvent(
      GatewayEvent(
        sessionId: sessionId,
        platformId: 'cli_client',
        type: 'message',
        message: Message(role: MessageRole.user, content: 'Active work'),
        runId: activeRequestId,
        metadata: {
          'payload': {'session_id': sessionId, 'request_id': activeRequestId},
        },
      ),
    );
    await waitFor(
      () => adapter.calls == 1,
      reason: 'the active turn must reach the adapter',
    );
    expect(orchestrator.isSessionBusy(sessionId), isTrue);
    expect(
      adapter.holdFirstTurn!.isCompleted,
      isFalse,
      reason: 'the active turn must still be open',
    );
  }

  /// Releases the active turn and lets its admission settle.
  Future<void> finishActiveTurn() async {
    adapter.holdFirstTurn!.complete();
    await activeTurn;
  }

  /// Waits for a dispatched cron event and feeds it to the orchestrator exactly
  /// as the platform bridge does.
  Future<GatewayEvent> deliverNextDispatch() async {
    await waitFor(
      () => dispatchedEvents.isNotEmpty,
      reason: 'the schedule must dispatch an event',
    );
    final event = dispatchedEvents.single;
    expect(event.type, 'cron');
    await orchestrator.handleEvent(event);
    return event;
  }

  group('Task 139 Delta 1: a schedule dispatch is its own turn', () {
    test('a scheduled fire into a busy conversation is queued, not steered',
        () async {
      final schedule = scheduler.createSchedule(
        task: 'Summarise the open items',
        sessionId: sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'Z',
          atTime: '09:00',
        ),
      );

      await startActiveTurn();
      scheduler.executeTaskForTesting(schedule);
      final event = await deliverNextDispatch();
      final runId = event.runId!;

      // The dispatch waits for the active turn instead of joining it, and it
      // travels as non-steerable input so that is guaranteed by construction.
      expect(
        event.metadata['payload']?['delivery_intent'],
        MessageDeliveryIntent.queue.name,
        reason: 'a schedule dispatch is never steerable input',
      );
      expect(event.metadata['payload']?['request_id'], runId);
      await waitFor(
        () => classifications(runId).isNotEmpty,
        reason: 'the dispatch must be classified',
      );
      expect(classifications(runId), ['queue']);
      expect(queuedEchoFor(runId), isTrue);
      expect(
        classifications(runId),
        isNot(contains('steer')),
        reason: 'a steer would never commit the user message the run needs',
      );
      expect(
        adapter.calls,
        1,
        reason: 'the queued turn must not start while another owns the session',
      );

      final running = runRowOf(schedule.id);
      expect(running.status, ScheduledTaskRunStatus.running);
      expect(running.sessionId, isNull);
      expect(running.messageId, isNull);

      await finishActiveTurn();

      // The queued dispatch is promoted and runs as its own turn.
      await waitFor(
        () => adapter.calls == 2,
        reason: 'the queued schedule turn must run after the active one',
      );
      await waitFor(
        () => runRowOf(schedule.id).status.isTerminal,
        reason: 'the run must reach a terminal status',
      );

      final run = runRowOf(schedule.id);
      expect(run.id, runId);
      expect(run.trigger, ScheduledTaskRunTrigger.scheduled);
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.sessionId, sessionId);
      expect(run.messageId, isNotNull);
      expect(run.hasPosition, isTrue);
      expect(run.durationMs, isNotNull);
      expect(run.durationMs, greaterThanOrEqualTo(0));

      // The anchor is the run's own root user message.
      expect(
        sessions.db.messageRepository.activeRootRowIdForRequest(
          sessionId,
          runId,
        ),
        isNotNull,
        reason: 'the run identity must be the turn request identity',
      );
    });

    test('model run_now on its own continuous schedule during the active turn',
        () async {
      final tool = ScheduleTaskTool();
      final createResult = await tool.executeResult(
        {
          'action': 'create',
          'task': 'Summarise the open items',
          'kind': 'daily',
          'time': '09:00',
          'zone': 'Z',
        },
        context: ToolContext(sessionId: sessionId),
      );
      expect(createResult.isError, isFalse, reason: createResult.displayText);
      final schedule = scheduler.listSchedules().single;

      await startActiveTurn();
      final before = sessions.db.getScheduledTask(schedule.id)!;

      final runNow = await tool.executeResult(
        {'action': 'run_now', 'id': schedule.id},
        context: ToolContext(sessionId: sessionId),
      );
      expect(runNow.isError, isFalse, reason: runNow.displayText);

      final event = await deliverNextDispatch();
      final runId = event.runId!;
      await waitFor(
        () => classifications(runId).isNotEmpty,
        reason: 'the manual run must be classified',
      );
      expect(classifications(runId), ['queue']);
      expect(queuedEchoFor(runId), isTrue);

      // S21: a manual run never shifts the schedule or resumes it.
      final afterDispatch = sessions.db.getScheduledTask(schedule.id)!;
      expect(afterDispatch['next_run_at'], before['next_run_at']);
      expect(afterDispatch['last_run_at'], before['last_run_at']);
      expect(afterDispatch['last_status'], before['last_status']);
      expect(afterDispatch['enabled'], before['enabled']);

      await finishActiveTurn();
      await waitFor(
        () => adapter.calls == 2,
        reason: 'the manual run must execute as its own turn',
      );
      await waitFor(
        () => runRowOf(schedule.id).status.isTerminal,
        reason: 'the manual run must reach a terminal status',
      );

      final run = runRowOf(schedule.id);
      expect(run.trigger, ScheduledTaskRunTrigger.manual);
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.sessionId, sessionId);
      expect(run.messageId, isNotNull);
      expect(run.durationMs, isNotNull);

      final afterRun = sessions.db.getScheduledTask(schedule.id)!;
      expect(afterRun['next_run_at'], before['next_run_at']);
      expect(afterRun['last_run_at'], before['last_run_at']);
      expect(afterRun['last_status'], before['last_status']);
      expect(afterRun['enabled'], before['enabled']);
    });

    test('a scheduled fire into an idle conversation is unchanged', () async {
      final schedule = scheduler.createSchedule(
        task: 'Summarise the open items',
        sessionId: sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'Z',
          atTime: '09:00',
        ),
      );

      expect(orchestrator.isSessionBusy(sessionId), isFalse);
      scheduler.executeTaskForTesting(schedule);
      final event = await deliverNextDispatch();
      final runId = event.runId!;

      // Idle: the dispatch is an ordinary immediate turn, exactly as before.
      await waitFor(
        () => classifications(runId).isNotEmpty,
        reason: 'the dispatch must be classified',
      );
      expect(classifications(runId), ['think']);
      expect(queuedEchoFor(runId), isFalse);

      await waitFor(
        () => adapter.calls == 1,
        reason: 'an idle conversation starts the schedule turn immediately',
      );
      await waitFor(
        () => runRowOf(schedule.id).status.isTerminal,
        reason: 'the run must reach a terminal status',
      );

      final run = runRowOf(schedule.id);
      expect(run.trigger, ScheduledTaskRunTrigger.scheduled);
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.sessionId, sessionId);
      expect(run.messageId, isNotNull);
      expect(run.durationMs, isNotNull);
    });
  });
}
