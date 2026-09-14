import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_snapshot_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:test/test.dart';

void main() {
  const sessionId = 'promotion-session';
  const workItemId = 'promotion-work';
  const runId = 'promotion-run';
  const generation = 7;
  const toolCallId = 'tool-1';
  late AgentStateDatabase state;
  late SessionWorkItemRepository workItems;
  late SessionExecutionStateCoordinator coordinator;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    workItems = SessionWorkItemRepository(state);
    coordinator = SessionExecutionStateCoordinator(
      state: state,
      workItems: workItems,
      snapshots: SessionExecutionSnapshotRepository(state),
    );
    state.db.execute(
      '''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES (?, ?, ?, ?)
      ''',
      [sessionId, 'model', '2026-09-14', '2026-09-14'],
    );
    coordinator.enqueueWorkItem(
      workItemId: workItemId,
      sessionId: sessionId,
      requestId: 'request',
      state: SessionWorkState.running,
    );
    expect(
      coordinator.bindRunOwnership(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
      ),
      isTrue,
    );
  });

  tearDown(() => state.dispose());

  ToolExecutionResult richResult() => ToolExecutionResult(
    blocks: [
      ToolTextBlock(text: 'snapshot survives source deletion'),
      ToolImageBlock(
        dataBase64: base64.encode(const [4, 5, 6]),
        mimeType: 'image/png',
        width: 1,
        height: 1,
        detail: ToolImageDetail.high,
      ),
    ],
  );

  Message messageFor(ToolExecutionResult result) => Message(
    role: MessageRole.tool,
    toolCallId: toolCallId,
    toolResult: result,
    metadata: const {'tool_call_id': toolCallId, 'is_error': false},
  );

  void stage(ToolExecutionResult result) {
    final active = workItems.findActiveWorkItem(sessionId)!;
    final metadata = Map<String, dynamic>.from(active.continuationMetadata);
    metadata['completed_tool_results_v2'] = {
      toolCallId: {
        'schema_version': 2,
        'session_id': sessionId,
        'work_item_id': workItemId,
        'run_id': runId,
        'generation': generation,
        'tool_call_id': toolCallId,
        'result': result.toJson(),
      },
    };
    workItems.transitionWorkItemState(
      workItemId: workItemId,
      fromState: active.state,
      toState: active.state,
      continuationMetadata: metadata,
    );
  }

  int messageCount() =>
      state.db.select(
            'SELECT COUNT(*) AS count FROM messages WHERE session_id = ?',
            [sessionId],
          ).first['count']
          as int;

  test('crash-window promotion is atomic and exactly once', () {
    final result = richResult();
    stage(result);

    // Crash-before-promotion state: the inline snapshot is durable while the
    // canonical history row and its revision are still absent.
    expect(messageCount(), 0);
    expect(
      workItems
          .findActiveWorkItem(sessionId)!
          .continuationMetadata['completed_tool_results_v2'],
      isNotNull,
    );

    expect(
      coordinator.promoteCompletedToolResult(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
        toolCallId: toolCallId,
        historyMessage: messageFor(result),
      ),
      isTrue,
    );
    expect(messageCount(), 1);
    expect(SessionHistoryRevisionRepository(state).read(sessionId)!.value, 1);
    expect(
      workItems
          .findActiveWorkItem(sessionId)!
          .continuationMetadata['completed_tool_results_v2'],
      isNull,
    );

    // Crash-after-promotion retry observes the durable terminal and does not
    // append another message or revision.
    expect(
      coordinator.promoteCompletedToolResult(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
        toolCallId: toolCallId,
        historyMessage: messageFor(result),
      ),
      isTrue,
    );
    expect(messageCount(), 1);
    expect(SessionHistoryRevisionRepository(state).read(sessionId)!.value, 1);
  });

  test('stale owner cannot consume or append a checkpoint', () {
    final result = richResult();
    stage(result);

    expect(
      coordinator.promoteCompletedToolResult(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: 'stale-run',
        generation: generation,
        toolCallId: toolCallId,
        historyMessage: messageFor(result),
      ),
      isFalse,
    );
    expect(messageCount(), 0);
    expect(
      workItems
          .findActiveWorkItem(sessionId)!
          .continuationMetadata['completed_tool_results_v2'],
      isNotNull,
    );
  });

  test('promotion uses snapshot after its source changes or is deleted', () {
    final sourceDirectory = Directory.systemTemp.createTempSync(
      'sanad-rich-checkpoint-source-',
    );
    final source = File('${sourceDirectory.path}/image.png')
      ..writeAsBytesSync(const [4, 5, 6]);
    final stored = richResult();
    stage(stored);
    source.writeAsBytesSync(const [9, 9, 9]);
    final changed = ToolExecutionResult.text('changed source contents');

    expect(
      coordinator.promoteCompletedToolResult(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
        toolCallId: toolCallId,
        historyMessage: messageFor(changed),
      ),
      isFalse,
    );
    expect(messageCount(), 0);
    source.deleteSync();
    expect(
      coordinator.promoteCompletedToolResult(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
        toolCallId: toolCallId,
        historyMessage: messageFor(stored),
      ),
      isTrue,
    );
    final persisted = Message.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(
              state.db.select(
                    'SELECT data FROM messages WHERE session_id = ?',
                    [sessionId],
                  ).single['data']
                  as String,
            )
            as Map,
      ),
    );
    expect(persisted.toolResult!.toJson(), stored.toJson());
    sourceDirectory.deleteSync(recursive: true);
  });
}
