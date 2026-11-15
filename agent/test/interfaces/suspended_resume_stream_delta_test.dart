/// A suspended-resume continuation publishes through the same stream contract as
/// a live turn.
///
/// Two defects were possible here and both are cheap to hold shut: reasoning that
/// travelled as ordinary content would change the surface of a stream the user
/// was already reading, and a resumed delta without an ordinal would restart a
/// numbering the consumer had already advanced.
library;

import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:test/test.dart';

import 'interfaces_test.mocks.dart';

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}

void main() {
  late AgentStateDatabase stateDb;
  late PersistedRuntimeStateRepository repo;
  late MockAgentRunner runner;
  late MockSessionManager sessions;
  late SuspendedResumeService service;

  const sessionId = 'session-resume';
  const toolCallId = 'call-resume';
  const requestId = 'req-resume';
  late SuspendedCheckpoint checkpoint;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;

    stateDb = AgentStateDatabase.inMemory();
    repo = PersistedRuntimeStateRepository(stateDb.db);
    getIt.registerSingleton<AgentStateDatabase>(stateDb);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(repo);

    runner = MockAgentRunner();
    sessions = MockSessionManager();
    final sessionDb = MockSessionDB();
    when(sessions.db).thenReturn(sessionDb);
    when(sessionDb.saveSession(any)).thenReturn(null);
    when(sessions.getSessionMetadata(any)).thenReturn(null);
    when(sessions.saveSessionMetadata(any, any)).thenReturn(null);

    when(runner.accumulatedUsage).thenReturn({
      'prompt_tokens': 0,
      'completion_tokens': 0,
      'total_tokens': 0,
    });
    when(runner.lastUsage).thenReturn({
      'prompt_tokens': 0,
      'completion_tokens': 0,
      'total_tokens': 0,
    });
    when(runner.runtimeMs).thenReturn(50);
    when(runner.activeModel).thenReturn('mock-model');
    when(runner.activeModelDisplay).thenReturn('Mock Model');
    when(runner.activeProvider).thenReturn('mock-provider');
    when(runner.currentModelStepId).thenReturn('model_step_resumed');
    when(runner.getContextTokens()).thenAnswer((_) async => 100);
    when(runner.getContextUsageSnapshot()).thenAnswer((_) async => null);
    when(runner.attachMetadataToLastAssistantMessage(any)).thenReturn(null);
    when(runner.registry).thenReturn(ToolsRegistry());
    when(runner.endAuthoritativeRun(any)).thenReturn(null);
    getIt.registerFactoryParam<AgentRunner, String, void>(
      (sessionId, _) => runner,
    );

    final skillRegistry = const SkillRegistry();
    final workspaceRuntimeService = LocalWorkspaceRuntimeService(
      skillRegistry: skillRegistry,
      skillLoadService: SkillLoadService(registry: skillRegistry),
    );
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      workspaceRuntimeService,
    );
    final permissionManager = PermissionManager(
      policyStore: WorkspacePolicyStore(),
      platformRuntimeBridge: PlatformRuntimeBridge(),
      checkpointStore: SuspendedCheckpointStore(sessionManager: sessions),
    );
    getIt.registerSingleton<PermissionManager>(permissionManager);
    final runtimeCatalog = LocalRuntimeCatalog(
      workspaceRuntimeService: workspaceRuntimeService,
      permissionManager: permissionManager,
      platformRuntimeBridge: PlatformRuntimeBridge(),
      mcpRuntimeManager: _NoopMcpRuntimeManager(),
    );
    getIt.registerSingleton<LocalRuntimeCatalog>(runtimeCatalog);
    getIt.registerSingleton<RuntimeContextBuilder>(
      const RuntimeContextBuilder(skillRegistry: SkillRegistry()),
    );

    final now = DateTime.now().toUtc();
    stateDb.db.execute(
      "INSERT INTO sessions (session_id, model, created_at, updated_at) "
      "VALUES ('$sessionId', 'gpt-4o', ?, ?)",
      [now.toIso8601String(), now.toIso8601String()],
    );
    checkpoint = SuspendedCheckpoint(
      checkpointId: 'checkpoint-resume',
      sessionId: sessionId,
      requestId: requestId,
      toolCallId: toolCallId,
      toolName: 'system_ask_user',
      status: 'decision_ready',
      toolArguments: const {'questions': []},
      permissionPayload: const {'questions': []},
      resolvedDecision: const {'answer': 'continue'},
      createdAt: now,
      updatedAt: now,
    );
    SessionDB.fromState(stateDb).saveSuspendedCheckpoint(checkpoint);
    repo.insertWorkItem(
      SessionWorkItem(
        workItemId: 'work-resume',
        sessionId: sessionId,
        requestId: 'turn-resume',
        sequence: 0,
        state: SessionWorkState.waiting,
        attempt: 0,
        continuationMetadata: const {
          'owner_run_id': 'run-resume',
          'owner_generation': 2,
          'currently_executing_tools': [toolCallId],
        },
        createdAt: now,
        updatedAt: now,
      ),
    );
    when(sessions.getSuspendedCheckpointByRequestId(requestId))
        .thenReturn(checkpoint);
    when(sessions.deleteSuspendedCheckpointByRequestId(requestId))
        .thenAnswer((_) {
          SessionDB.fromState(stateDb)
              .deleteSuspendedCheckpointByRequestId(requestId);
        });
    when(
      runner.beginAuthoritativeRun(
        'run-resume',
        workItemId: 'work-resume',
        generation: 2,
      ),
    ).thenReturn(null);

    service = SuspendedResumeService(
      checkpointStore: SuspendedCheckpointStore(sessionManager: sessions),
      sessionManager: sessions,
      runtimeCatalog: runtimeCatalog,
      runtimeContextBuilder: const RuntimeContextBuilder(
        skillRegistry: SkillRegistry(),
      ),
      workspaceRuntimeService: workspaceRuntimeService,
      permissionManager: permissionManager,
      persistedState: repo,
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    stateDb.dispose();
  });

  test('resumed reasoning stays reasoning and every delta keeps its key ordinal',
      () async {
    when(
      runner.resumeAfterToolCall(
        toolCallId: toolCallId,
        toolName: 'system_ask_user',
        arguments: checkpoint.toolArguments,
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        forcedOutput: 'continue',
        forcedIsError: false,
        onToolEvent: anyNamed('onToolEvent'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).thenAnswer((invocation) async* {
      final onReasoning =
          invocation.namedArguments[#onReasoningDelta]
              as FutureOr<void> Function(String)?;
      await onReasoning?.call('resumed reasoning');
      yield 'first';
      yield 'second';
    });

    final responses = <GatewayResponse>[];
    final resumed = await service.resumePersistedDecision(
      requestId: requestId,
      decision: checkpoint.resolvedDecision!,
      emitResponse: (response) async => responses.add(response),
    );
    expect(resumed, isTrue);

    final deltas = responses
        .where((response) => !response.isComplete)
        .toList(growable: false);
    expect(deltas, hasLength(3));

    final canonical = deltas
        .map(AgentToCanonical.translate)
        .toList(growable: false);
    expect(
      canonical.map((event) => event.type).toList(),
      [
        CanonicalEventTypes.reasoningStream,
        CanonicalEventTypes.thoughtStream,
        CanonicalEventTypes.thoughtStream,
      ],
      reason: 'a resumed reasoning delta must not become ordinary text',
    );
    expect(
      canonical.map((event) => event.payload['content']).toList(),
      ['resumed reasoning', 'first', 'second'],
    );
    expect(
      canonical.map((event) => event.payload['stream_seq']).toList(),
      [1, 1, 2],
      reason: 'reasoning and content are separate stream keys',
    );
    expect(
      canonical.first.payload['model_step_id'],
      'model_step_resumed',
    );

    final terminal = responses.firstWhere((response) => response.isComplete);
    final terminalEvent = AgentToCanonical.translate(terminal);
    expect(terminalEvent.type, CanonicalEventTypes.finalAnswer);
    expect(terminalEvent.payload.containsKey('stream_seq'), isFalse);
    expect(terminal.streamSeq, isNull);
  });

  test('a resumed continuation allocates under a new model step, not a reused key',
      () async {
    // A restarted process still holds the checkpoint's step identity until the
    // continuation starts its own model step. The sample pins that this stale
    // identity is never the key a resumed delta allocates on.
    var stepId = 'model_step_from_checkpoint';
    when(runner.currentModelStepId).thenAnswer((_) => stepId);

    when(
      runner.resumeAfterToolCall(
        toolCallId: toolCallId,
        toolName: 'system_ask_user',
        arguments: checkpoint.toolArguments,
        runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
        forcedOutput: 'continue',
        forcedIsError: false,
        onToolEvent: anyNamed('onToolEvent'),
        onThoughtDelta: anyNamed('onThoughtDelta'),
        onReasoningDelta: anyNamed('onReasoningDelta'),
      ),
    ).thenAnswer((invocation) async* {
      // Mirrors RunnerStreamCoordinator.streamNextResponse: a continuation
      // begins a model step before the provider stream produces anything.
      stepId = 'model_step_after_restart';
      final onReasoning =
          invocation.namedArguments[#onReasoningDelta]
              as FutureOr<void> Function(String)?;
      await onReasoning?.call('fresh reasoning');
      yield 'first';
      yield 'second';
    });

    final responses = <GatewayResponse>[];
    final resumed = await service.resumePersistedDecision(
      requestId: requestId,
      decision: checkpoint.resolvedDecision!,
      emitResponse: (response) async => responses.add(response),
    );
    expect(resumed, isTrue);

    final canonical = responses
        .where((response) => !response.isComplete)
        .map(AgentToCanonical.translate)
        .toList(growable: false);
    expect(canonical, hasLength(3));
    expect(
      canonical.map((event) => event.payload['model_step_id']).toList(),
      everyElement('model_step_after_restart'),
      reason: 'a resumed delta must not reuse the checkpoint step key',
    );
    expect(
      canonical.map((event) => event.payload['stream_seq']).toList(),
      [1, 1, 2],
      reason: 'each fresh step starts its own keys at the first ordinal',
    );
    expect(
      canonical.any(
        (event) => event.payload['model_step_id'] == 'model_step_from_checkpoint',
      ),
      isFalse,
    );

    final terminal = responses.firstWhere((response) => response.isComplete);
    expect(
      AgentToCanonical.translate(terminal).payload['model_step_id'],
      'model_step_after_restart',
    );
  });
}
