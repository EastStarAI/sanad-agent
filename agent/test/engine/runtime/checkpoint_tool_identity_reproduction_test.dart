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

    mockTool = _CountingMockTool(toolName: 'shell_execute');
    registry = ToolsRegistry()..registerTool(mockTool);

    coordinator = ToolExecutionCoordinator(
      sessionId: 'test-session-97',
      registry: registry,
      sessionManager: SessionManager(),
      pluginManager: PluginManager(),
      checkpointCoordinator: ContinuationCheckpointCoordinator(
        sessionId: 'test-session-97',
      ),
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

  test(
    'reproduction: repeated tool call ID across model steps reuses checkpoint and skips execution',
    () async {
      final callbacks1 = _TestToolCallbacks();

      // Step 1: Model requests execution of shell_execute_0
      final step1ToolCall = ToolCall(
        id: 'shell_execute_0',
        name: 'shell_execute',
        arguments: const {'command': 'ls -la'},
      );

      await coordinator.executeToolCalls(
        [step1ToolCall],
        parallel: false,
        callbacks: callbacks1,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-1'),
      );

      expect(callbacks1.results, contains('shell_execute_0'));
      expect(
        callbacks1.results['shell_execute_0'],
        contains('execution_result_1: ls -la'),
      );
      expect(
        mockTool.invocationCount,
        1,
        reason: 'Tool must execute on initial call in step 1',
      );

      // Verify checkpoint was persisted into continuation metadata
      final metadataAfterStep1 = persisted
          .findActiveWorkItem('test-session-97')!
          .continuationMetadata;
      final completedResults =
          metadataAfterStep1['completed_tool_results'] as Map;
      expect(
        completedResults['shell_execute_0'],
        contains('execution_result_1: ls -la'),
      );

      // Step 2: Fresh model step (HTTP 200) outputs tool call with repeating synthetic ID shell_execute_0
      // but DIFFERENT intended command or arguments in step 2
      final callbacks2 = _TestToolCallbacks();
      final step2ToolCall = ToolCall(
        id: 'shell_execute_0',
        name: 'shell_execute',
        arguments: const {'command': 'echo second_turn'},
      );

      await coordinator.executeToolCalls(
        [step2ToolCall],
        parallel: false,
        callbacks: callbacks2,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-2'),
      );

      // Deterministic reproduction assertion:
      // The coordinator looks up completedResults[toolCall.id] without scoping to model_step_id,
      // arguments, or assistant message. It returns the step 1 result and does NOT invoke the tool!
      expect(
        mockTool.invocationCount,
        1,
        reason:
            'REPRODUCTION CONFIRMED: mock tool was NOT executed in step 2 because toolCall.id matched existing checkpoint',
      );
      expect(
        callbacks2.results['shell_execute_0'],
        contains('execution_result_1: ls -la'),
        reason:
            'REPRODUCTION CONFIRMED: stale output from step 1 was returned for step 2 call',
      );
    },
  );
}
