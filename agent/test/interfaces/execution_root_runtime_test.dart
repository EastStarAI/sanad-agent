import 'dart:io';

import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/canonical_to_agent.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:test/test.dart';

import 'interfaces_test.mocks.dart';

class RecordingRuntimeContextBuilder extends RuntimeContextBuilder {
  String? lastWorkspacePath;
  String? lastWorkspaceName;

  RecordingRuntimeContextBuilder();

  @override
  Future<String?> build({
    required String workspacePath,
    String? workspaceName,
    ToolsRegistry? registry,
  }) async {
    lastWorkspacePath = workspacePath;
    lastWorkspaceName = workspaceName;
    return 'Custom runtime context for $workspaceName at $workspacePath';
  }

  @override
  String buildWithoutWorkspace() {
    return 'No workspace context';
  }
}

void main() {
  group('Workspace and temporary execution targeting', () {
    late Directory tempDir;
    late Directory logicalWorkspaceDir;
    late Directory executionRootDir;
    late LocalWorkspaceRuntimeService workspaceService;
    late RecordingRuntimeContextBuilder contextBuilder;
    late LocalRuntimeCatalog catalog;
    late LocalRuntimeOrchestrator orchestrator;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('exec-root-orchestrator-');
      logicalWorkspaceDir = Directory(p.join(tempDir.path, 'logical-ws'))
        ..createSync();
      executionRootDir = Directory(p.join(tempDir.path, 'isolated-worktree'))
        ..createSync();

      workspaceService = LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: logicalWorkspaceDir.path,
      );
      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspaceService,
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      );
      contextBuilder = RecordingRuntimeContextBuilder();
      orchestrator = LocalRuntimeOrchestrator(
        workspaceService,
        catalog,
        runtimeContextBuilder: contextBuilder,
      );
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'buildSessionMetadata preserves workspace identity and execution_root',
      () async {
        final request = AgentTurnRequest(
          sessionId: 'sess-test-meta',
          message: 'hello',
          workspaceId: logicalWorkspaceDir.path,
          metadata: {'execution_root': executionRootDir.path},
        );

        final metadata = await orchestrator.buildSessionMetadata(request);
        expect(metadata, containsPair('execution_root', executionRootDir.path));
        expect(metadata['workspace_id'], isNotNull);
        expect(metadata['workspace_path'], equals(logicalWorkspaceDir.path));
      },
    );

    test(
      'AgentTurnRequest keeps workspace identity and execution root distinct',
      () {
        final request = AgentTurnRequest(
          sessionId: 'sess-request-defense',
          message: 'hello',
          workspaceId: 'ws-authoritative',
          metadata: {
            'workspace_id': 'ws-legacy',
            'execution_root': executionRootDir.path,
          },
        );

        expect(request.effectiveWorkspaceId, equals('ws-authoritative'));
        expect(request.executionRoot, equals(executionRootDir.path));
        expect(
          request.toMetadata(),
          containsPair('workspace_id', 'ws-authoritative'),
        );
        expect(
          request.toMetadata(),
          containsPair('execution_root', executionRootDir.path),
        );

        final rootOnly = AgentTurnRequest(
          sessionId: 'sess-request-root-only',
          message: 'hello',
          metadata: {'execution_root': executionRootDir.path},
        );
        expect(rootOnly.effectiveWorkspaceId, isNull);
        expect(rootOnly.executionRoot, equals(executionRootDir.path));
        expect(rootOnly.toMetadata(), isNot(contains('workspace_id')));
        expect(
          rootOnly.toMetadata(),
          containsPair('execution_root', executionRootDir.path),
        );
      },
    );

    test('gateway flattens session metadata into the turn request', () {
      final event = CanonicalToAgent.translate({
        'command': 'think',
        'payload': {
          'session_id': 'sess-gateway-root-only',
          'message': 'hello',
          'session_metadata': {'execution_root': executionRootDir.path},
        },
      }, 'local_gateway');

      expect(event, isNotNull);
      expect(event!.turnRequest!.executionRoot, equals(executionRootDir.path));
      expect(event.turnRequest!.metadata, isNot(contains('session_metadata')));
    });

    test(
      'LocalRuntimeCatalog.buildTools uses execution_root without registering a workspace',
      () async {
        final registry = ToolsRegistry();
        final requestWithExecRoot = AgentTurnRequest(
          sessionId: 'sess-exec-root',
          message: 'run test',
          metadata: {'execution_root': executionRootDir.path},
        );

        final tools = await catalog.buildTools(
          registry: registry,
          request: requestWithExecRoot,
        );

        final shellTools = tools.whereType<ShellExecuteTool>().toList();
        expect(shellTools, isNotEmpty);
        expect(shellTools.first.workspacePath, equals(executionRootDir.path));
      },
    );

    test(
      'LocalRuntimeCatalog.buildTools targets execution_root while retaining workspace identity',
      () async {
        final registry = ToolsRegistry();
        final requestWithBoth = AgentTurnRequest(
          sessionId: 'sess-logical-ws',
          message: 'run test',
          workspaceId: logicalWorkspaceDir.path,
          metadata: {'execution_root': executionRootDir.path},
        );

        final tools = await catalog.buildTools(
          registry: registry,
          request: requestWithBoth,
        );

        final shellTools = tools.whereType<ShellExecuteTool>().toList();
        expect(shellTools, isNotEmpty);
        expect(shellTools.first.workspacePath, equals(executionRootDir.path));
      },
    );

    test(
      'LocalRuntimeOrchestrator.buildRuntimeContext targets execution_root with workspace identity',
      () async {
        final request = AgentTurnRequest(
          sessionId: 'sess-ctx-test',
          message: 'test context',
          workspaceId: logicalWorkspaceDir.path,
          metadata: {'execution_root': executionRootDir.path},
        );

        final result = await orchestrator.buildRuntimeContext(request);
        expect(result, isNotNull);
        expect(contextBuilder.lastWorkspacePath, equals(executionRootDir.path));
        expect(
          contextBuilder.lastWorkspaceName,
          equals(p.basename(executionRootDir.path)),
        );
      },
    );
  });

  group('WorkspacePathResolver execution root normalization', () {
    late Directory tempDir;
    late Directory existingSubdir;
    late File existingFile;
    final resolver = WorkspacePathResolver();

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('exec-root-resolver-');
      existingSubdir = Directory(p.join(tempDir.path, 'nested', 'target'))
        ..createSync(recursive: true);
      existingFile = File(p.join(tempDir.path, 'regular_file.txt'))
        ..writeAsStringSync('not a directory');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('returns null for null or empty/whitespace input', () {
      expect(resolver.validateAndNormalizeExecutionRoot(null), isNull);
      expect(resolver.validateAndNormalizeExecutionRoot(''), isNull);
      expect(resolver.validateAndNormalizeExecutionRoot('   '), isNull);
    });

    test(
      'normalizes relative execution_root to canonical absolute directory',
      () {
        final cwd = Directory.current.path;
        final relativeTarget = p.relative(existingSubdir.path, from: cwd);

        final normalized = resolver.validateAndNormalizeExecutionRoot(
          relativeTarget,
        );
        expect(normalized, isNotNull);
        expect(p.isAbsolute(normalized!), isTrue);
        expect(
          Directory(normalized).resolveSymbolicLinksSync(),
          equals(existingSubdir.resolveSymbolicLinksSync()),
        );
      },
    );

    test('fails closed when execution_root path does not exist', () {
      final nonExistent = p.join(tempDir.path, 'missing_worktree');
      expect(
        () => resolver.validateAndNormalizeExecutionRoot(nonExistent),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('Execution root directory does not exist'),
          ),
        ),
      );
    });

    test(
      'fails closed when execution_root is a file instead of a directory',
      () {
        expect(
          () => resolver.validateAndNormalizeExecutionRoot(existingFile.path),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.message,
              'message',
              contains('is not a directory'),
            ),
          ),
        );
      },
    );
  });

  group(
    'SuspendedResumeService preserves temporary execution_root across restart',
    () {
      late Directory tempDir;
      late Directory executionRootDir;
      late Directory logicalWorkspaceDir;
      late AgentStateDatabase stateDb;
      late MockSessionManager mockSessionManager;
      late MockAgentRunner mockAgentRunner;
      late LocalWorkspaceRuntimeService workspaceService;
      late LocalRuntimeCatalog catalog;
      late RecordingRuntimeContextBuilder contextBuilder;
      late PermissionManager permissionManager;

      setUp(() async {
        await getIt.reset();
        SessionManager.resetForTesting();
        getIt.allowReassignment = true;

        tempDir = Directory.systemTemp.createTempSync('exec-root-restart-');
        logicalWorkspaceDir = Directory(p.join(tempDir.path, 'logical-ws'))
          ..createSync();
        executionRootDir = Directory(p.join(tempDir.path, 'isolated-worktree'))
          ..createSync();

        stateDb = AgentStateDatabase.inMemory();
        getIt.registerSingleton<AgentStateDatabase>(stateDb);

        mockAgentRunner = MockAgentRunner();
        mockSessionManager = MockSessionManager();

        when(mockAgentRunner.registry).thenReturn(ToolsRegistry());
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
        when(mockAgentRunner.runtimeMs).thenReturn(10);
        when(mockAgentRunner.activeModel).thenReturn('mock-model');
        when(mockAgentRunner.activeModelDisplay).thenReturn('Mock Model');
        when(mockAgentRunner.activeProvider).thenReturn('mock-provider');
        when(mockAgentRunner.currentModelStepId).thenReturn('model-step-test');
        when(
          mockAgentRunner.getContextUsageSnapshot(),
        ).thenAnswer((_) async => null);
        when(mockAgentRunner.getContextTokens()).thenAnswer((_) async => 100);
        when(
          mockAgentRunner.attachMetadataToLastAssistantMessage(any),
        ).thenReturn(null);

        getIt.registerFactoryParam<AgentRunner, String, void>(
          (sessionId, _) => mockAgentRunner,
        );

        workspaceService = LocalWorkspaceRuntimeService(
          sanadHomePath: tempDir.path,
          currentWorkingDirectory: logicalWorkspaceDir.path,
        );
        getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspaceService);

        catalog = LocalRuntimeCatalog(
          workspaceRuntimeService: workspaceService,
          mcpRuntimeManager: _NoopMcpRuntimeManager(),
        );
        contextBuilder = RecordingRuntimeContextBuilder();

        permissionManager = PermissionManager(
          policyStore: const WorkspacePolicyStore(),
          platformRuntimeBridge: PlatformRuntimeBridge(),
          checkpointStore: SuspendedCheckpointStore(
            sessionManager: mockSessionManager,
          ),
        );
        getIt.registerSingleton<PermissionManager>(permissionManager);
      });

      tearDown(() async {
        await getIt.reset();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test(
        'reconstructed SuspendedResumeService recovers execution_root from metadata and builds context and tools from it',
        () async {
          const sessionId = 'session-exec-restart';
          const requestId = 'req-exec-restart';
          const toolCallId = 'call-exec-restart';
          final now = DateTime.now().toUtc();

          final checkpoint = SuspendedCheckpoint(
            checkpointId: 'checkpoint-exec-1',
            sessionId: sessionId,
            requestId: requestId,
            toolCallId: toolCallId,
            toolName: 'shell_execute',
            status: 'awaiting_permission',
            toolArguments: const {'command': 'echo hello'},
            permissionPayload: const {'tool_name': 'shell_execute'},
            createdAt: now,
            updatedAt: now,
          );

          when(
            mockSessionManager.getSuspendedCheckpointByRequestId(requestId),
          ).thenReturn(checkpoint);
          when(
            mockSessionManager.deleteSuspendedCheckpointByRequestId(requestId),
          ).thenReturn(null);
          when(
            mockSessionManager.claimSuspendedCheckpointDecision(
              requestId: anyNamed('requestId'),
              status: anyNamed('status'),
            ),
          ).thenReturn(true);
          when(mockSessionManager.getSessionMetadata(sessionId)).thenReturn({
            'execution_root': executionRootDir.path,
            'model': 'test-model',
          });

          when(
            mockAgentRunner.resumeAfterToolCall(
              toolCallId: toolCallId,
              toolName: 'shell_execute',
              arguments: const {'command': 'echo hello'},
              runtimeSystemPrompt: anyNamed('runtimeSystemPrompt'),
              forcedOutput: anyNamed('forcedOutput'),
              forcedIsError: anyNamed('forcedIsError'),
              onToolEvent: anyNamed('onToolEvent'),
              onThoughtDelta: anyNamed('onThoughtDelta'),
              onReasoningDelta: anyNamed('onReasoningDelta'),
            ),
          ).thenAnswer((_) => Stream.value('Resumed response'));

          // Reconstruct SuspendedResumeService anew (simulating daemon startup/reconstruction)
          final reconstructedService = SuspendedResumeService(
            checkpointStore: SuspendedCheckpointStore(
              sessionManager: mockSessionManager,
            ),
            runtimeCatalog: catalog,
            runtimeContextBuilder: contextBuilder,
            workspaceRuntimeService: workspaceService,
            permissionManager: permissionManager,
            sessionManager: mockSessionManager,
          );

          final resumed = await reconstructedService.resumeFromDecision(
            requestId: requestId,
            decision: {
              'session_id': sessionId,
              'allowed': false,
              'comment': 'Deny execution for test',
            },
            emitResponse: (_) async {},
          );

          expect(resumed, isTrue);

          // Verify that runtime context was built targeting the execution_root
          expect(
            contextBuilder.lastWorkspacePath,
            equals(executionRootDir.path),
          );
          expect(
            contextBuilder.lastWorkspaceName,
            equals(p.basename(executionRootDir.path)),
          );

          // Verify that tools registered on the agent runner targeted the execution_root
          final shellTools = mockAgentRunner.registry.allTools
              .whereType<ShellExecuteTool>()
              .toList();
          expect(shellTools, isNotEmpty);
          expect(shellTools.first.workspacePath, equals(executionRootDir.path));
        },
      );
    },
  );
}

/// Deterministic MCP facade for suites that build tools without an ambient
/// prepared Sanad home; the suites under test do not exercise MCP discovery.
class _NoopMcpRuntimeManager extends McpRuntimeManager {
  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}
