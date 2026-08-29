import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/engine/runtime/tool_terminal_record.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:test/test.dart';

void main() {
  group('ToolTerminalRecord', () {
    test('cancelled record round-trips through checkpoint output', () {
      final startedAt = DateTime.parse('2026-08-29T00:00:00Z');
      final record = ToolTerminalRecord.cancelled(
        sessionId: 'session-1',
        toolCallId: 'call-1',
        toolName: 'shell_execute',
        runId: 'run-1',
        generation: 2,
        revision: 42,
        startedAt: startedAt,
      );

      final restored = ToolTerminalRecord.fromCheckpointOutput(
        record.toCheckpointOutput(arguments: const {'command': 'sleep 1'}),
      );

      expect(restored, isNotNull);
      expect(restored!.status, ToolTerminalStatus.cancelled);
      expect(restored.sessionId, 'session-1');
      expect(restored.message, ToolTerminalRecord.cancelledMessage);
      expect(restored.revision, 42);
      expect(restored.startedAt, startedAt);
      expect(restored.isTerminalCancelled, isTrue);
    });

    test('history metadata preserves cancelled status', () {
      final record = ToolTerminalRecord.cancelled(
        sessionId: 'session-2',
        toolCallId: 'call-2',
        toolName: 'shell_execute',
        runId: 'run-2',
        generation: 1,
      );

      final metadata = record.toHistoryMetadata(modelStepId: 'step-2');
      expect(metadata['status'], 'cancelled');
      expect(metadata['reason'], 'user_stop');
      expect(metadata['model_step_id'], 'step-2');
      expect(metadata['started_at'], isNotNull);
      expect(metadata['terminal_at'], isNotNull);
    });

    test('canonical live payload preserves the durable terminal identity', () {
      final record = ToolTerminalRecord.cancelled(
        sessionId: 'session-live',
        toolCallId: 'call-live',
        toolName: 'shell_execute',
        runId: 'run-live',
        modelStepId: 'step-live',
        generation: 3,
        revision: 17,
        startedAt: DateTime.parse('2026-08-29T00:00:00Z'),
        cleanupOutcome: 'cancelled',
      );
      final event = AgentToCanonical.translate(
        GatewayResponse(
          sessionId: 'session-live',
          message: Message(
            role: MessageRole.tool,
            content: record.message,
            toolCallId: record.toolCallId,
            metadata: record.toHistoryMetadata(modelStepId: 'step-live'),
          ),
          runId: record.runId,
          modelStepId: 'step-live',
          toolCallId: record.toolCallId,
          toolName: record.toolName,
          isToolResult: true,
          isToolError: true,
          isToolCancelled: true,
        ),
      );

      expect(event.payload, containsPair('status', 'cancelled'));
      expect(event.payload, containsPair('generation', 3));
      expect(event.payload, containsPair('revision', 17));
      expect(event.payload, containsPair('reason', 'user_stop'));
      expect(event.payload, containsPair('cleanup_outcome', 'cancelled'));
      expect(event.payload['started_at'], record.startedAt.toIso8601String());
      expect(event.payload['terminal_at'], record.terminalAt.toIso8601String());
    });
  });

  group('durable cancelled terminal commit', () {
    late AgentStateDatabase state;
    late PersistedRuntimeStateRepository repository;

    setUp(() {
      state = AgentStateDatabase.inMemory();
      repository = PersistedRuntimeStateRepository.fromState(state);
      state.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('session-terminal', 'test-model', '2026-08-29', '2026-08-29')",
      );
      repository.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-terminal',
          sessionId: 'session-terminal',
          requestId: 'request-terminal',
          sequence: 1,
          state: SessionWorkState.running,
          attempt: 0,
          payload: const {'message': 'run'},
          continuationMetadata: const {
            'owner_run_id': 'run-terminal',
            'owner_generation': 4,
            'currently_executing_tools': ['call-terminal'],
            'tool_started_at': {'call-terminal': '2026-08-29T00:00:00.000Z'},
          },
          createdAt: DateTime.parse('2026-08-29T00:00:00Z'),
          updatedAt: DateTime.parse('2026-08-29T00:00:00Z'),
        ),
      );
    });

    tearDown(() => state.dispose());

    test(
      'validates owner and commits checkpoint plus history exactly once',
      () {
        final record = ToolTerminalRecord.cancelled(
          sessionId: 'session-terminal',
          toolCallId: 'call-terminal',
          toolName: 'shell_execute',
          runId: 'run-terminal',
          modelStepId: 'step-terminal',
          generation: 4,
          revision: 91,
          startedAt: DateTime.parse('2026-08-29T00:00:00Z'),
        );
        final output = record.toCheckpointOutput(
          arguments: const {'command': 'sleep 10'},
        );
        final message = Message(
          role: MessageRole.tool,
          content: record.message,
          toolCallId: record.toolCallId,
          metadata: record.toHistoryMetadata(modelStepId: 'step-terminal'),
        );

        final stale = repository.executionState.commitCancelledToolTerminals(
          sessionId: 'session-terminal',
          workItemId: 'work-terminal',
          runId: 'run-terminal',
          generation: 3,
          checkpointOutputs: {'call-terminal': output},
          historyMessages: {'call-terminal': message},
        );
        expect(stale.outcome, ToolTerminalCommitOutcome.staleOwner);
        expect(
          repository
              .findActiveWorkItem('session-terminal')!
              .continuationMetadata['completed_tool_outputs'],
          isNull,
        );

        final committed = repository.executionState
            .commitCancelledToolTerminals(
              sessionId: 'session-terminal',
              workItemId: 'work-terminal',
              runId: 'run-terminal',
              generation: 4,
              checkpointOutputs: {'call-terminal': output},
              historyMessages: {'call-terminal': message},
            );
        expect(committed.outcome, ToolTerminalCommitOutcome.committed);
        expect(committed.committedToolCallIds, ['call-terminal']);

        final metadata = repository
            .findActiveWorkItem('session-terminal')!
            .continuationMetadata;
        final persistedOutput =
            (metadata['completed_tool_outputs'] as Map)['call-terminal'] as Map;
        expect(persistedOutput['status'], 'cancelled');
        expect(persistedOutput['session_id'], 'session-terminal');
        expect(persistedOutput['model_step_id'], 'step-terminal');
        expect(persistedOutput['revision'], 91);
        expect(metadata['currently_executing_tools'], isNull);
        expect(metadata['tool_started_at'], isNull);
        expect(
          SessionDB.fromState(state).getMessages('session-terminal'),
          hasLength(1),
        );

        final repeated = repository.executionState.commitCancelledToolTerminals(
          sessionId: 'session-terminal',
          workItemId: 'work-terminal',
          runId: 'run-terminal',
          generation: 4,
          checkpointOutputs: {'call-terminal': output},
          historyMessages: {'call-terminal': message},
        );
        expect(repeated.outcome, ToolTerminalCommitOutcome.noChange);
        expect(
          SessionDB.fromState(state).getMessages('session-terminal'),
          hasLength(1),
        );
      },
    );
  });
}
