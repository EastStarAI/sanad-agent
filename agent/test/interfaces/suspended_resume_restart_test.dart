import 'package:mockito/mockito.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:test/test.dart';

import 'interfaces_test.mocks.dart';

void main() {
  group('SuspendedResumeService restart recovery', () {
    late AgentStateDatabase stateDb;
    late PersistedRuntimeStateRepository repo;
    late MockAgentRunner mockAgentRunner;
    late MockSessionManager mockSessionManager;
    late MockSessionDB mockSessionDb;
    late LocalRuntimeCatalog runtimeCatalog;
    late LocalWorkspaceRuntimeService workspaceRuntimeService;

    setUp(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      getIt.allowReassignment = true;

      stateDb = AgentStateDatabase.inMemory();
      repo = PersistedRuntimeStateRepository(stateDb.db);
      getIt.registerSingleton<AgentStateDatabase>(stateDb);
      getIt.registerSingleton<PersistedRuntimeStateRepository>(repo);

      mockAgentRunner = MockAgentRunner();
      mockSessionManager = MockSessionManager();
      mockSessionDb = MockSessionDB();

      when(mockSessionManager.db).thenReturn(mockSessionDb);
      when(mockSessionDb.saveSession(any)).thenReturn(null);
      when(mockSessionManager.getSessionMetadata(any)).thenReturn(null);
      when(mockSessionManager.saveSessionMetadata(any, any)).thenReturn(null);

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
      when(mockAgentRunner.runtimeMs).thenReturn(50);
      when(mockAgentRunner.activeModel).thenReturn('mock-model');
      when(mockAgentRunner.activeModelDisplay).thenReturn('Mock Model');
      when(mockAgentRunner.activeProvider).thenReturn('mock-provider');
      when(mockAgentRunner.currentModelStepId).thenReturn('step-restart-1');
      when(mockAgentRunner.getContextTokens()).thenAnswer((_) async => 100);
      when(
        mockAgentRunner.getContextUsageSnapshot(),
      ).thenAnswer((_) async => null);
      when(
        mockAgentRunner.attachMetadataToLastAssistantMessage(any),
      ).thenReturn(null);
      when(mockAgentRunner.registry).thenReturn(ToolsRegistry());
      when(mockAgentRunner.endAuthoritativeRun(any)).thenReturn(null);

      getIt.registerFactoryParam<AgentRunner, String, void>(
        (sessionId, _) => mockAgentRunner,
      );

      final skillRegistry = const SkillRegistry();
      workspaceRuntimeService = LocalWorkspaceRuntimeService(
        skillRegistry: skillRegistry,
        skillLoadService: SkillLoadService(registry: skillRegistry),
      );
      getIt.registerSingleton<LocalWorkspaceRuntimeService>(
        workspaceRuntimeService,
      );

      final permissionManager = PermissionManager(
        policyStore: const WorkspacePolicyStore(),
        platformRuntimeBridge: PlatformRuntimeBridge(),
        checkpointStore: SuspendedCheckpointStore(
          sessionManager: mockSessionManager,
        ),
      );
      getIt.registerSingleton<PermissionManager>(permissionManager);

      runtimeCatalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspaceRuntimeService,
        permissionManager: permissionManager,
        platformRuntimeBridge: PlatformRuntimeBridge(),
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      );
      getIt.registerSingleton<LocalRuntimeCatalog>(runtimeCatalog);
      getIt.registerSingleton<RuntimeContextBuilder>(
        const RuntimeContextBuilder(skillRegistry: SkillRegistry()),
      );
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      await getIt.reset();
      stateDb.dispose();
    });

    test(
      'resumePersistedDecision reclaims decision_ready checkpoint exactly once and resumes successfully',
      () async {
        final now = DateTime.now().toUtc();
        const sessionId = 'session-restart-ready';
        const toolCallId = 'call-restart-ready';
        const requestId = 'req-restart-ready';

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$sessionId', 'gpt-4o', ?, ?)",
          [now.toIso8601String(), now.toIso8601String()],
        );

        final readyCheckpoint = SuspendedCheckpoint(
          checkpointId: 'checkpoint-ready',
          sessionId: sessionId,
          requestId: requestId,
          toolCallId: toolCallId,
          toolName: 'system_ask_user',
          status: 'decision_ready',
          toolArguments: const {'questions': []},
          permissionPayload: const {'questions': []},
          resolvedDecision: const {'answer': 'resumed from persisted decision'},
          createdAt: now,
          updatedAt: now,
        );
        SessionDB.fromState(stateDb).saveSuspendedCheckpoint(readyCheckpoint);

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-restart-ready',
            sessionId: sessionId,
            requestId: 'turn-restart-ready',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            continuationMetadata: const {
              'owner_run_id': 'run-restart-ready',
              'owner_generation': 2,
              'currently_executing_tools': [toolCallId],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        when(
          mockSessionManager.getSuspendedCheckpointByRequestId(requestId),
        ).thenReturn(readyCheckpoint);
        when(
          mockSessionManager.deleteSuspendedCheckpointByRequestId(requestId),
        ).thenAnswer((_) {
          SessionDB.fromState(
            stateDb,
          ).deleteSuspendedCheckpointByRequestId(requestId);
        });

        when(
          mockAgentRunner.beginAuthoritativeRun(
            'run-restart-ready',
            workItemId: 'work-restart-ready',
            generation: 2,
          ),
        ).thenReturn(null);

        when(
          mockAgentRunner.resumeAfterToolCall(
            toolCallId: toolCallId,
            toolName: 'system_ask_user',
            arguments: readyCheckpoint.toolArguments,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            forcedOutput: 'resumed from persisted decision',
            forcedIsError: false,
            onToolEvent: anyNamed('onToolEvent'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) async* {
          yield 'reclaimed restart output';
        });

        final checkpointStore = SuspendedCheckpointStore(
          sessionManager: mockSessionManager,
        );
        final service = SuspendedResumeService(
          checkpointStore: checkpointStore,
          sessionManager: mockSessionManager,
          runtimeCatalog: runtimeCatalog,
          runtimeContextBuilder: const RuntimeContextBuilder(
            skillRegistry: SkillRegistry(),
          ),
          workspaceRuntimeService: workspaceRuntimeService,
          permissionManager: getIt<PermissionManager>(),
          persistedState: repo,
        );

        // 1. Fresh response on decision_ready checkpoint must be rejected (requires awaiting_permission)
        final freshRejected = await service.resumeFromDecision(
          requestId: requestId,
          decision: const {'answer': 'attempt fresh answer'},
          emitResponse: (_) async {},
        );
        expect(
          freshRejected,
          isFalse,
          reason: 'resumeFromDecision must reject decision_ready checkpoint',
        );

        // 2. resumePersistedDecision on decision_ready checkpoint must succeed and resume
        final responses = <GatewayResponse>[];
        final firstReclaimed = await service.resumePersistedDecision(
          requestId: requestId,
          decision: readyCheckpoint.resolvedDecision!,
          emitResponse: (resp) async => responses.add(resp),
        );
        expect(
          firstReclaimed,
          isTrue,
          reason:
              'resumePersistedDecision must succeed on decision_ready checkpoint',
        );
        expect(responses.last.isComplete, isTrue);
        expect(
          responses.last.message.content,
          equals('reclaimed restart output'),
        );
        expect(
          repo.findWorkItem('work-restart-ready')?.state,
          SessionWorkState.completed,
        );

        // 3. Persisted decision must be reclaimed exactly once
        when(
          mockSessionManager.getSuspendedCheckpointByRequestId(requestId),
        ).thenReturn(null);
        final secondReclaim = await service.resumePersistedDecision(
          requestId: requestId,
          decision: readyCheckpoint.resolvedDecision!,
          emitResponse: (_) async {},
        );
        expect(
          secondReclaim,
          isFalse,
          reason:
              'resumePersistedDecision must fail on second reclaim (exactly once)',
        );
      },
    );

    test(
      'resumeFromDecision requires awaiting_permission and resumePersistedDecision rejects awaiting_permission',
      () async {
        final now = DateTime.now().toUtc();
        const sessionId = 'session-awaiting-check';
        const toolCallId = 'call-awaiting-check';
        const requestId = 'req-awaiting-check';

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$sessionId', 'gpt-4o', ?, ?)",
          [now.toIso8601String(), now.toIso8601String()],
        );

        final awaitingCheckpoint = SuspendedCheckpoint(
          checkpointId: 'checkpoint-awaiting',
          sessionId: sessionId,
          requestId: requestId,
          toolCallId: toolCallId,
          toolName: 'system_ask_user',
          status: 'awaiting_permission',
          toolArguments: const {'questions': []},
          permissionPayload: const {'questions': []},
          createdAt: now,
          updatedAt: now,
        );
        SessionDB.fromState(
          stateDb,
        ).saveSuspendedCheckpoint(awaitingCheckpoint);

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-awaiting-check',
            sessionId: sessionId,
            requestId: 'turn-awaiting-check',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            continuationMetadata: const {
              'owner_run_id': 'run-awaiting-check',
              'owner_generation': 1,
              'currently_executing_tools': [toolCallId],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        when(
          mockSessionManager.getSuspendedCheckpointByRequestId(requestId),
        ).thenReturn(awaitingCheckpoint);
        when(
          mockSessionManager.deleteSuspendedCheckpointByRequestId(requestId),
        ).thenAnswer((_) {
          SessionDB.fromState(
            stateDb,
          ).deleteSuspendedCheckpointByRequestId(requestId);
        });

        when(
          mockAgentRunner.beginAuthoritativeRun(
            'run-awaiting-check',
            workItemId: 'work-awaiting-check',
            generation: 1,
          ),
        ).thenReturn(null);

        when(
          mockAgentRunner.resumeAfterToolCall(
            toolCallId: toolCallId,
            toolName: 'system_ask_user',
            arguments: awaitingCheckpoint.toolArguments,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            forcedOutput: 'fresh answer provided',
            forcedIsError: false,
            onToolEvent: anyNamed('onToolEvent'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) async* {
          yield 'fresh turn completed';
        });

        final checkpointStore = SuspendedCheckpointStore(
          sessionManager: mockSessionManager,
        );
        final service = SuspendedResumeService(
          checkpointStore: checkpointStore,
          sessionManager: mockSessionManager,
          runtimeCatalog: runtimeCatalog,
          runtimeContextBuilder: const RuntimeContextBuilder(
            skillRegistry: SkillRegistry(),
          ),
          workspaceRuntimeService: workspaceRuntimeService,
          permissionManager: getIt<PermissionManager>(),
          persistedState: repo,
        );

        // 1. resumePersistedDecision on awaiting_permission checkpoint must be rejected
        final persistedRejected = await service.resumePersistedDecision(
          requestId: requestId,
          decision: const {'answer': 'attempt persisted on awaiting'},
          emitResponse: (_) async {},
        );
        expect(
          persistedRejected,
          isFalse,
          reason:
              'resumePersistedDecision must reject awaiting_permission status',
        );

        // 2. resumeFromDecision on awaiting_permission checkpoint must succeed
        final freshResponses = <GatewayResponse>[];
        final freshSucceeded = await service.resumeFromDecision(
          requestId: requestId,
          decision: const {'answer': 'fresh answer provided'},
          emitResponse: (resp) async => freshResponses.add(resp),
        );
        expect(
          freshSucceeded,
          isTrue,
          reason:
              'resumeFromDecision must succeed on awaiting_permission checkpoint',
        );
        expect(freshResponses.last.isComplete, isTrue);
        expect(
          freshResponses.last.message.content,
          equals('fresh turn completed'),
        );
        expect(
          repo.findWorkItem('work-awaiting-check')?.state,
          SessionWorkState.completed,
        );
      },
    );

    test(
      'resumePersistedDecision preserves session affinity and kind validation',
      () async {
        final now = DateTime.now().toUtc();
        const askSessionId = 'session-ask-val';
        const permSessionId = 'session-perm-val';
        const askToolCallId = 'call-ask-check';
        const askRequestId = 'req-ask-check';
        const permToolCallId = 'call-perm-check';
        const permRequestId = 'req-perm-check';

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$askSessionId', 'gpt-4o', ?, ?)",
          [now.toIso8601String(), now.toIso8601String()],
        );
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('$permSessionId', 'gpt-4o', ?, ?)",
          [now.toIso8601String(), now.toIso8601String()],
        );

        final askCheckpoint = SuspendedCheckpoint(
          checkpointId: 'checkpoint-ask-val',
          sessionId: askSessionId,
          requestId: askRequestId,
          toolCallId: askToolCallId,
          toolName: 'system_ask_user',
          status: 'decision_ready',
          toolArguments: const {'questions': []},
          permissionPayload: const {'questions': []},
          resolvedDecision: const {'answer': 'valid answer'},
          createdAt: now,
          updatedAt: now,
        );
        SessionDB.fromState(stateDb).saveSuspendedCheckpoint(askCheckpoint);

        final permCheckpoint = SuspendedCheckpoint(
          checkpointId: 'checkpoint-perm-val',
          sessionId: permSessionId,
          requestId: permRequestId,
          toolCallId: permToolCallId,
          toolName: 'bash',
          status: 'decision_ready',
          toolArguments: const {'command': 'ls'},
          permissionPayload: const {'tool_name': 'bash'},
          resolvedDecision: const {'allowed': true},
          createdAt: now,
          updatedAt: now,
        );
        SessionDB.fromState(stateDb).saveSuspendedCheckpoint(permCheckpoint);

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-ask-val',
            sessionId: askSessionId,
            requestId: 'turn-ask-val',
            sequence: 0,
            state: SessionWorkState.waiting,
            attempt: 0,
            continuationMetadata: const {
              'owner_run_id': 'run-ask-val',
              'owner_generation': 1,
              'currently_executing_tools': [askToolCallId],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'work-perm-val',
            sessionId: permSessionId,
            requestId: 'turn-perm-val',
            sequence: 1,
            state: SessionWorkState.waiting,
            attempt: 0,
            continuationMetadata: const {
              'owner_run_id': 'run-perm-val',
              'owner_generation': 1,
              'currently_executing_tools': [permToolCallId],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        when(
          mockSessionManager.getSuspendedCheckpointByRequestId(askRequestId),
        ).thenReturn(askCheckpoint);
        when(
          mockSessionManager.getSuspendedCheckpointByRequestId(permRequestId),
        ).thenReturn(permCheckpoint);

        when(
          mockAgentRunner.beginAuthoritativeRun(
            'run-perm-val',
            workItemId: 'work-perm-val',
            generation: 1,
          ),
        ).thenReturn(null);

        when(
          mockAgentRunner.resumeAfterToolCall(
            toolCallId: permToolCallId,
            toolName: 'bash',
            arguments: permCheckpoint.toolArguments,
            runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
            forcedOutput: null,
            forcedIsError: false,
            onToolEvent: anyNamed('onToolEvent'),
            onThoughtDelta: anyNamed('onThoughtDelta'),
            onReasoningDelta: anyNamed('onReasoningDelta'),
          ),
        ).thenAnswer((_) async* {
          yield 'tool executed and resumed';
        });

        final checkpointStore = SuspendedCheckpointStore(
          sessionManager: mockSessionManager,
        );
        final service = SuspendedResumeService(
          checkpointStore: checkpointStore,
          sessionManager: mockSessionManager,
          runtimeCatalog: runtimeCatalog,
          runtimeContextBuilder: const RuntimeContextBuilder(
            skillRegistry: SkillRegistry(),
          ),
          workspaceRuntimeService: workspaceRuntimeService,
          permissionManager: getIt<PermissionManager>(),
          persistedState: repo,
        );

        // 1. Cross-session rejection: mismatched session_id must return false
        final crossSessionResult = await service.resumePersistedDecision(
          requestId: askRequestId,
          decision: const {
            'session_id': 'mismatched-session-id',
            'answer': 'valid answer',
          },
          emitResponse: (_) async {},
        );
        expect(
          crossSessionResult,
          isFalse,
          reason: 'Cross-session decision must be rejected',
        );

        // 2. Ask User kind validation: missing or empty answer must return false
        final emptyAnswerResult = await service.resumePersistedDecision(
          requestId: askRequestId,
          decision: const {'answer': '   '},
          emitResponse: (_) async {},
        );
        expect(
          emptyAnswerResult,
          isFalse,
          reason: 'Empty answer must be rejected',
        );

        final wrongKindForAskUser = await service.resumePersistedDecision(
          requestId: askRequestId,
          decision: const {'allowed': true},
          emitResponse: (_) async {},
        );
        expect(
          wrongKindForAskUser,
          isFalse,
          reason: 'Allowed decision for ask-user question must be rejected',
        );

        // 3. Tool permission kind validation: missing allowed/decision must return false
        final wrongKindForTool = await service.resumePersistedDecision(
          requestId: permRequestId,
          decision: const {'answer': 'some answer'},
          emitResponse: (_) async {},
        );
        expect(
          wrongKindForTool,
          isFalse,
          reason: 'Answer decision for tool permission must be rejected',
        );

        // 4. Valid tool permission restart reclaim succeeds
        final toolResponses = <GatewayResponse>[];
        final toolReclaimSucceeded = await service.resumePersistedDecision(
          requestId: permRequestId,
          decision: const {'allowed': true},
          emitResponse: (resp) async => toolResponses.add(resp),
        );
        expect(
          toolReclaimSucceeded,
          isTrue,
          reason: 'Valid tool permission restart reclaim must succeed',
        );
        expect(toolResponses.last.isComplete, isTrue);
        expect(
          toolResponses.last.message.content,
          equals('tool executed and resumed'),
        );
        expect(
          repo.findWorkItem('work-perm-val')?.state,
          SessionWorkState.completed,
        );
      },
    );
  });
}

/// Deterministic MCP facade for suites that resume runtime context without an
/// ambient prepared Sanad home; the suites under test do not exercise MCP.
class _NoopMcpRuntimeManager extends McpRuntimeManager {
  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}
