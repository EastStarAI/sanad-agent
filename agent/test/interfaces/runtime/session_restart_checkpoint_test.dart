import 'dart:async';
import 'dart:convert';

import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_agent/engine/runtime/tool_execution_coordinator.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/plugins/plugin_manager.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository persisted;

  setUp(() {
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    persisted = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<AgentStateDatabase>(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(persisted);
    state.db.execute('''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES ('restart-session', 'model-a', '2026-07-19', '2026-07-19')
      ''');
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  test(
    'controlled restart waits for the active tool result checkpoint',
    () async {
      persisted.executionState.enqueueWorkItem(
        workItemId: 'restart-work',
        sessionId: 'restart-session',
        state: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindInitialModelRequest,
          'currently_executing_tools': ['restart-tool-call'],
        },
      );
      final orchestrator = SessionRunOrchestrator();

      final waiting = orchestrator.waitForControlledRestartCheckpoint(
        timeout: const Duration(seconds: 1),
        pollInterval: const Duration(milliseconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await _isCompleted(waiting), isFalse);

      persisted.transitionWorkItemState(
        workItemId: 'restart-work',
        fromState: SessionWorkState.running,
        toState: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
          'currently_executing_tools': [],
          'completed_tool_results': {
            'restart-tool-call': {'output': 'Daemon exiting for restart...'},
          },
        },
      );

      await expectLater(
        waiting,
        completion(
          isA<ControlledRestartCheckpointResult>().having(
            (result) => result.isSafe,
            'isSafe',
            isTrue,
          ),
        ),
      );
    },
  );

  test(
    'restart requester never hides unsafe work in another session',
    () async {
      state.db.execute('''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES ('other-session', 'model-a', '2026-07-19', '2026-07-19')
      ''');
      persisted.executionState.enqueueWorkItem(
        workItemId: 'requester-work',
        sessionId: 'restart-session',
        state: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindInitialModelRequest,
          'currently_executing_tools': ['restart-tool-call'],
        },
      );
      persisted.executionState.enqueueWorkItem(
        workItemId: 'other-work',
        sessionId: 'other-session',
        state: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindInitialModelRequest,
          'currently_executing_tools': ['other-unsafe-call'],
        },
      );
      final orchestrator = SessionRunOrchestrator();

      final result = await orchestrator.waitForControlledRestartCheckpoint(
        timeout: const Duration(milliseconds: 10),
        pollInterval: const Duration(milliseconds: 1),
        requesterSessionId: 'restart-session',
        requesterToolCallId: 'restart-tool-call',
      );

      expect(result.isSafe, isFalse);
      expect(result.blockers, hasLength(1));
      expect(result.blockers.single.sessionId, 'other-session');
      expect(result.blockers.single.toolCallIds, ['other-unsafe-call']);
    },
  );

  test(
    'durable deferred requester result permits the controlled restart',
    () async {
      persisted.executionState.enqueueWorkItem(
        workItemId: 'restart-work',
        sessionId: 'restart-session',
        state: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindInitialModelRequest,
          'currently_executing_tools': ['restart-tool-call'],
          'deferred_tool_results': {
            'restart-tool-call': {
              'kind': 'sanad_dev_switch',
              'transaction_id': 'switch-1',
              'manifest_path': '/tmp/home/dev/runtime-switch-58085.json',
              'requester_session_id': 'restart-session',
              'requester_tool_call_id': 'restart-tool-call',
            },
          },
        },
      );

      final result = await SessionRunOrchestrator()
          .waitForControlledRestartCheckpoint(
            timeout: const Duration(milliseconds: 10),
            pollInterval: const Duration(milliseconds: 1),
            requesterSessionId: 'restart-session',
            requesterToolCallId: 'restart-tool-call',
            requireRequesterCompletion: true,
          );

      expect(result.isSafe, isTrue);
    },
  );

  test(
    'deferred terminal result is persisted exactly once after restart',
    () async {
      persisted.executionState.enqueueWorkItem(
        workItemId: 'restart-work',
        sessionId: 'restart-session',
        state: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindInitialModelRequest,
          'currently_executing_tools': ['restart-tool-call'],
          'deferred_tool_results': {
            'restart-tool-call': {
              'kind': 'sanad_dev_switch',
              'transaction_id': 'switch-1',
              'manifest_path': '/tmp/home/dev/runtime-switch-58085.json',
              'requester_session_id': 'restart-session',
              'requester_tool_call_id': 'restart-tool-call',
            },
          },
        },
      );
      var manifestReads = 0;
      final coordinator = ToolExecutionCoordinator(
        sessionId: 'restart-session',
        registry: ToolsRegistry(),
        sessionManager: SessionManager(),
        pluginManager: PluginManager(),
        checkpointCoordinator: ContinuationCheckpointCoordinator(
          sessionId: 'restart-session',
        ),
        deferredToolResultResolver: DeferredToolResultResolver(
          environment: const {'SANAD_HOME': '/tmp/home'},
          readManifest: (_) async {
            manifestReads++;
            return jsonEncode(const {
              'id': 'switch-1',
              'requester_session_id': 'restart-session',
              'requester_tool_call_id': 'restart-tool-call',
              'target_worktree_name': 'target',
              'status': 'rolled_back',
            });
          },
        ),
      );
      final callbacks = _ToolCallbacks();
      final toolCall = ToolCall(
        id: 'restart-tool-call',
        name: 'shell_execute',
        arguments: const {},
      );

      await coordinator.executeToolCalls(
        [toolCall],
        parallel: false,
        callbacks: callbacks,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-1'),
      );
      await coordinator.executeToolCalls(
        [toolCall],
        parallel: false,
        callbacks: callbacks,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-1'),
      );

      final metadata = persisted
          .findActiveWorkItem('restart-session')!
          .continuationMetadata;
      expect(manifestReads, 1);
      expect(metadata['deferred_tool_results'], isNull);
      expect(
        (metadata['completed_tool_results'] as Map)['restart-tool-call'],
        contains('Switch rolled back'),
      );
      expect(callbacks.results, hasLength(1));
    },
  );

  test(
    'late tool completion cannot replace Stop-owned terminalization',
    () async {
      persisted.executionState.enqueueWorkItem(
        workItemId: 'restart-work',
        sessionId: 'restart-session',
        state: SessionWorkState.running,
        continuationMetadata: const {
          'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
        },
      );
      final tool = _HangingTool();
      final registry = ToolsRegistry()..registerTool(tool);
      final coordinator = ToolExecutionCoordinator(
        sessionId: 'restart-session',
        registry: registry,
        sessionManager: SessionManager(),
        pluginManager: PluginManager(),
        checkpointCoordinator: ContinuationCheckpointCoordinator(
          sessionId: 'restart-session',
        ),
      );
      final callbacks = _ToolCallbacks();
      final scope = RunCancellationScope(
        sessionId: 'restart-session',
        runId: 'run-cancelled',
        workItemId: 'restart-work',
        generation: 1,
      );

      final execution = coordinator.executeToolCalls(
        [ToolCall(id: 'late-call', name: 'hanging', arguments: const {})],
        parallel: false,
        callbacks: callbacks,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'step-1'),
        cancellationScope: scope,
      );
      await tool.started.future;
      scope.invalidate(reason: RunCancellationReason.userStop);
      tool.finish('late success');
      await execution;

      final metadata = persisted
          .findActiveWorkItem('restart-session')!
          .continuationMetadata;
      expect(metadata['currently_executing_tools'], ['late-call']);
      expect(
        (metadata['completed_tool_results'] as Map?)?.containsKey(
              'late-call',
            ) ??
            false,
        isFalse,
      );
      expect(callbacks.results, isEmpty);
    },
  );

  test('controlled restart drain refuses suspended resume claims', () async {
    final orchestrator = SessionRunOrchestrator();
    orchestrator.beginControlledRestartDrain();

    expect(
      await orchestrator.resumeSuspended(
        'restart-session',
        recoveryReason: 'manual_retry',
      ),
      ResumeSuspendedResult.restartDraining,
    );

    orchestrator.cancelControlledRestartDrain();
    expect(
      await orchestrator.resumeSuspended('restart-session'),
      ResumeSuspendedResult.missing,
    );
  });
}

class _ToolCallbacks implements ToolExecutionCallbacks {
  final Map<String, String> results = {};

  @override
  Future<void> addToolMessage(
    ToolCall toolCall,
    String result, {
    required bool isError,
  }) async {
    results[toolCall.id] = result;
  }

  @override
  void applyPendingSteerToToolResults(int numToolCalls) {}

  @override
  int currentHistoryLength() => results.length;

  @override
  bool isToolMessagePresent(String toolCallId) =>
      results.containsKey(toolCallId);

  @override
  void saveHistory() {}
}

class _HangingTool extends BaseTool {
  final Completer<void> started = Completer<void>();
  final Completer<String> _result = Completer<String>();

  @override
  ToolSchema get schema => ToolSchema(
    name: 'hanging',
    description: 'Test-only hanging tool.',
    parameters: const {'type': 'object'},
  );

  void finish(String result) => _result.complete(result);

  @override
  Future<String> execute(Map<String, dynamic> args, {ToolContext? context}) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }
}

Future<bool> _isCompleted<T>(Future<T> future) async {
  var completed = false;
  unawaited(future.then((_) => completed = true));
  await Future<void>.delayed(Duration.zero);
  return completed;
}
