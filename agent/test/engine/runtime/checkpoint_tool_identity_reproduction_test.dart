import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/engine/runtime/tool_execution_coordinator.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/plugins/plugin_manager.dart';
import 'package:test/test.dart';

/// Task 97b regression suite (Windows-first agent/client performance).
///
/// The 97a reproduction fixture proved that
/// [ToolExecutionCoordinator.executeToolCalls] reused `completed_tool_results`
/// keyed only by the provider tool-call id, so a new model step that repeated
/// the id (e.g. `shell_execute_0`) silently consumed the stale checkpoint
/// result and the loop never progressed.
///
/// The repair scopes completed-result reuse to the exact causal model step that
/// recorded the result (plus tool name). Genuinely-new calls that reuse a
/// provider id across steps or turns must execute exactly once. This suite
/// asserts the repaired behavior and the required recovery/side-effect
/// scenarios.
class _CountingMockTool extends BaseTool {
  int invocationCount = 0;
  final String toolName;

  _CountingMockTool({this.toolName = 'shell_execute'});

  @override
  ToolSchema get schema => ToolSchema(
    name: toolName,
    description: 'Test counting mock tool.',
    parameters: const {'type': 'object'},
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    invocationCount++;
    return 'execution_result_$invocationCount: ${args['command'] ?? 'default'}';
  }
}

class _TestToolCallbacks implements ToolExecutionCallbacks {
  final Map<String, String> results = {};
  final List<String> receivedOutputs = [];
  int historySaveCount = 0;

  @override
  Future<void> addToolMessage(
    ToolCall toolCall,
    String result, {
    required bool isError,
  }) async {
    results[toolCall.id] = result;
    receivedOutputs.add(result);
  }

  @override
  void applyPendingSteerToToolResults(int numToolCalls) {}

  @override
  int currentHistoryLength() => results.length;

  @override
  bool isToolMessagePresent(String toolCallId) =>
      results.containsKey(toolCallId);

  @override
  void saveHistory() {
    historySaveCount++;
  }
}

void main() {
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository persisted;
  late ToolsRegistry registry;
  late _CountingMockTool mockTool;
  late ToolExecutionCoordinator coordinator;
  late ContinuationCheckpointCoordinator checkpointCoordinator;
  late String workItemId;

  setUp(() {
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    persisted = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<AgentStateDatabase>(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(persisted);

    state.db.execute('''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES ('test-session-97', 'model-gemini', '2026-09-22', '2026-09-22')
    ''');

    persisted.executionState.enqueueWorkItem(
      workItemId: 'test-work-97',
      sessionId: 'test-session-97',
      state: SessionWorkState.running,
      continuationMetadata: const {},
    );
    workItemId = persisted.findActiveWorkItem('test-session-97')!.workItemId;

    mockTool = _CountingMockTool(toolName: 'shell_execute');
    registry = ToolsRegistry()..registerTool(mockTool);

    checkpointCoordinator = ContinuationCheckpointCoordinator(
      sessionId: 'test-session-97',
    );
    coordinator = ToolExecutionCoordinator(
      sessionId: 'test-session-97',
      registry: registry,
      sessionManager: SessionManager(),
      pluginManager: PluginManager(),
      checkpointCoordinator: checkpointCoordinator,
      deferredToolResultResolver: DeferredToolResultResolver(
        environment: {'SANAD_HOME': Directory.systemTemp.path},
      ),
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  Map<String, dynamic> metadata() =>
      persisted.findActiveWorkItem('test-session-97')!.continuationMetadata;

  Future<void> runBatch(
    List<ToolCall> toolCalls,
    _TestToolCallbacks callbacks, {
    required String modelStepId,
  }) {
    return coordinator.executeToolCalls(
      toolCalls,
      parallel: false,
      callbacks: callbacks,
      ctx: (currentTurnStartIndex: 0, currentModelStepId: modelStepId),
    );
  }

  ToolCall toolCall(Object id, String command) => ToolCall(
    id: id.toString(),
    name: 'shell_execute',
    arguments: {'command': command},
  );

  test(
    'regression: reused tool-call id across model steps with different arguments executes once per step and never returns a stale result',
    () async {
      final callbacks1 = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'ls -la')],
        callbacks1,
        modelStepId: 'model-step-1',
      );

      expect(
        callbacks1.results['shell_execute_0'],
        contains('execution_result_1: ls -la'),
      );
      expect(
        mockTool.invocationCount,
        1,
        reason: 'Tool must execute on its initial call in step 1',
      );

      var meta = metadata();
      final completedResults = meta['completed_tool_results'] as Map;
      expect(
        completedResults['shell_execute_0'],
        contains('execution_result_1: ls -la'),
      );
      final outputs = meta['completed_tool_outputs'] as Map;
      final step1Output = Map<String, dynamic>.from(
        outputs['shell_execute_0'] as Map,
      );
      expect(
        step1Output['model_step_id'],
        'model-step-1',
        reason: 'completed result must be tagged with its owning model step',
      );

      // Step 2: a fresh model step (new HTTP 200) emits the SAME synthetic id
      // but a DIFFERENT command. This is a genuinely new causal invocation and
      // must execute once — never reuse step 1's stale result.
      final callbacks2 = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'echo second_turn')],
        callbacks2,
        modelStepId: 'model-step-2',
      );

      expect(
        mockTool.invocationCount,
        2,
        reason: 'A new model step with a reused provider id must execute',
      );
      expect(
        callbacks2.results['shell_execute_0'],
        contains('execution_result_2: echo second_turn'),
      );
      expect(
        callbacks2.results['shell_execute_0'],
        isNot(contains('ls -la')),
        reason: 'step 2 must not receive step 1 stale output',
      );

      meta = metadata();
      final updatedOutputs = meta['completed_tool_outputs'] as Map;
      final step2Output = Map<String, dynamic>.from(
        updatedOutputs['shell_execute_0'] as Map,
      );
      expect(step2Output['model_step_id'], 'model-step-2');
    },
  );

  test(
    'no repeated request loop: N genuinely-new steps each execute once while same-step replay reuses (no duplicate side effect)',
    () async {
      // One genuine execution per distinct (model step, arguments).
      for (final (index, command) in [
        'ls -la',
        'echo turn_two',
        'echo turn_three',
      ].indexed) {
        final callbacks = _TestToolCallbacks();
        await runBatch(
          [toolCall('shell_execute_0', command)],
          callbacks,
          modelStepId: 'model-step-$index',
        );
        expect(
          mockTool.invocationCount,
          index + 1,
          reason: 'each distinct model step must execute exactly once',
        );
        expect(
          callbacks.results['shell_execute_0'],
          contains('execution_result_${index + 1}: $command'),
        );
      }

      // Replaying the LAST step's exact invocation (as a restart resume would
      // under the same restored model step) reuses the durable result and does
      // NOT re-run the tool.
      final resumed = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'echo turn_three')],
        resumed,
        modelStepId: 'model-step-2',
      );
      expect(
        mockTool.invocationCount,
        3,
        reason: 'same-checkpoint replay must not duplicate a side effect',
      );
      expect(
        resumed.results['shell_execute_0'],
        contains('execution_result_3: echo turn_three'),
      );
    },
  );

  test(
    'same-checkpoint replay under the same model step reuses the durable result and never re-runs the tool',
    () async {
      final first = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'cat data')],
        first,
        modelStepId: 'model-step-R',
      );
      expect(mockTool.invocationCount, 1);

      // Restart resume re-invokes the same assistant batch under the restored
      // model step; the durable result must be reused.
      final second = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'cat data')],
        second,
        modelStepId: 'model-step-R',
      );

      expect(
        mockTool.invocationCount,
        1,
        reason: 'durable result reuse must not re-execute the tool',
      );
      expect(
        second.results['shell_execute_0'],
        contains('execution_result_1: cat data'),
      );

      // The step id alone is not sufficient causal identity. If the same
      // provider id is reused with different arguments, it is a new invocation
      // and must execute rather than consume the prior result.
      final changedArguments = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'cat other-data')],
        changedArguments,
        modelStepId: 'model-step-R',
      );
      expect(mockTool.invocationCount, 2);
      expect(
        changedArguments.results['shell_execute_0'],
        contains('execution_result_2: cat other-data'),
      );
    },
  );

  test(
    'restart after a durable result reuses that result and does not re-run the completed tool',
    () async {
      await runBatch(
        [toolCall('shell_execute_0', 'git status')],
        _TestToolCallbacks(),
        modelStepId: 'model-step-A',
      );
      expect(
        mockTool.invocationCount,
        1,
        reason: 'initial durable execution happened once',
      );

      // A daemon restart resumes under the same restored model step and the
      // durable completed result is intact in the checkpoint.
      final result = metadata()['completed_tool_results'] as Map;
      expect(result['shell_execute_0'], contains('git status'));

      final resumed = _TestToolCallbacks();
      await runBatch(
        [toolCall('shell_execute_0', 'git status')],
        resumed,
        modelStepId: 'model-step-A',
      );
      expect(
        mockTool.invocationCount,
        1,
        reason: 'no re-execution of a tool that already has a durable result',
      );
      expect(resumed.results['shell_execute_0'], contains('git status'));
    },
  );

  test(
    'restart during a side-effecting tool produces a neutral outcome and never re-runs the non-idempotent tool',
    () async {
      // Simulate a crash mid-execution of a non-idempotent tool: it is marked
      // currently-executing but has NO durable result for the current step.
      final meta = Map<String, dynamic>.from(metadata())
        ..['currently_executing_tools'] = ['side_effect_0']
        ..remove('completed_tool_results')
        ..remove('completed_tool_outputs');
      persisted.transitionWorkItemState(
        workItemId: workItemId,
        fromState: SessionWorkState.running,
        toState: SessionWorkState.running,
        continuationMetadata: meta,
      );

      final callbacks = _TestToolCallbacks();
      await runBatch(
        [toolCall('side_effect_0', 'rm -rf x')],
        callbacks,
        modelStepId: 'model-step-B',
      );

      expect(
        mockTool.invocationCount,
        0,
        reason:
            'a non-idempotent tool that crashes without a durable result '
            'must never be re-executed',
      );
      expect(
        callbacks.results['side_effect_0'],
        contains('cannot be safely re-run'),
      );
    },
  );
}
