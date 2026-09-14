import 'dart:convert';

import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:test/test.dart';

void main() {
  const sessionId = 'rich-checkpoint-session';
  const workItemId = 'rich-checkpoint-work';
  const runId = 'rich-checkpoint-run';
  const generation = 3;
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository repository;
  late ContinuationCheckpointCoordinator coordinator;

  setUp(() async {
    await getIt.reset();
    state = AgentStateDatabase.inMemory();
    repository = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(repository);
    state.db.execute(
      '''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES (?, ?, ?, ?)
      ''',
      [sessionId, 'model', '2026-09-14', '2026-09-14'],
    );
    repository.executionState.enqueueWorkItem(
      workItemId: workItemId,
      sessionId: sessionId,
      requestId: 'request',
      state: SessionWorkState.running,
    );
    expect(
      repository.executionState.bindRunOwnership(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
      ),
      isTrue,
    );
    coordinator = ContinuationCheckpointCoordinator(sessionId: sessionId);
  });

  tearDown(() async {
    await getIt.reset();
    state.dispose();
  });

  ToolExecutionResult richResult() => ToolExecutionResult(
    blocks: [
      ToolTextBlock(text: 'captured snapshot'),
      ToolImageBlock(
        dataBase64: base64.encode(const [1, 2, 3]),
        mimeType: 'image/png',
        width: 1,
        height: 1,
        detail: ToolImageDetail.original,
      ),
    ],
  );

  void replaceMetadata(Map<String, dynamic> metadata) {
    final active = repository.findActiveWorkItem(sessionId)!;
    repository.transitionWorkItemState(
      workItemId: active.workItemId,
      fromState: active.state,
      toState: active.state,
      continuationMetadata: metadata,
    );
  }

  test(
    'v2 owner envelope round-trips rich blocks and keeps output redacted',
    () {
      final result = richResult();
      coordinator.saveCheckpoint(
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'step-1'),
        checkpointKind:
            ContinuationCheckpointCoordinator.checkpointKindAfterToolResult,
        resumeHistoryLength: 0,
        additionalToolResults: const {'tool-1': 'captured snapshot'},
        additionalToolResultsV2: {'tool-1': result},
        additionalToolOutputs: {
          'tool-1': coordinator.toolOutputRecord(
            ToolCall(id: 'tool-1', name: 'view_image', arguments: const {}),
            'token=secret-value',
            isError: false,
            sentToProvider: false,
          ),
        },
      );

      final metadata = repository
          .findActiveWorkItem(sessionId)!
          .continuationMetadata;
      final envelope = Map<String, dynamic>.from(
        (metadata['completed_tool_results_v2'] as Map)['tool-1'] as Map,
      );
      expect(envelope['schema_version'], 2);
      expect(envelope['session_id'], sessionId);
      expect(envelope['work_item_id'], workItemId);
      expect(envelope['run_id'], runId);
      expect(envelope['generation'], generation);
      expect(
        jsonEncode(metadata['completed_tool_outputs']),
        isNot(contains('secret-value')),
      );
      expect(
        coordinator.restoreCompletedToolResultsV2()['tool-1']!.toJson(),
        result.toJson(),
      );
    },
  );

  test('corrupt rich payload degrades to a terminal marker without replay', () {
    coordinator.saveCheckpoint(
      ctx: (currentTurnStartIndex: 0, currentModelStepId: null),
      additionalToolResults: const {'tool-1': 'legacy snapshot'},
      additionalToolResultsV2: {'tool-1': richResult()},
    );
    final metadata = Map<String, dynamic>.from(
      repository.findActiveWorkItem(sessionId)!.continuationMetadata,
    );
    final rich = Map<String, dynamic>.from(
      metadata['completed_tool_results_v2'] as Map,
    );
    final envelope = Map<String, dynamic>.from(rich['tool-1'] as Map);
    envelope['result'] = {'schemaVersion': 1, 'blocks': 'invalid'};
    rich['tool-1'] = envelope;
    metadata['completed_tool_results_v2'] = rich;
    replaceMetadata(metadata);

    final restored = coordinator.restoreCompletedToolResultsV2()['tool-1']!;
    expect(restored.isError, isTrue);
    expect(
      restored.displayText,
      ContinuationCheckpointCoordinator.corruptToolResultMarker,
    );
  });

  test(
    'stale owner is rejected while legacy text-only metadata remains valid',
    () {
      coordinator.saveCheckpoint(
        ctx: (currentTurnStartIndex: 0, currentModelStepId: null),
        additionalToolResults: const {'tool-1': 'legacy snapshot'},
        additionalToolResultsV2: {'tool-1': richResult()},
      );
      final metadata = Map<String, dynamic>.from(
        repository.findActiveWorkItem(sessionId)!.continuationMetadata,
      );
      final rich = Map<String, dynamic>.from(
        metadata['completed_tool_results_v2'] as Map,
      );
      final envelope = Map<String, dynamic>.from(rich['tool-1'] as Map)
        ..['run_id'] = 'stale-run';
      rich['tool-1'] = envelope;
      metadata['completed_tool_results_v2'] = rich;
      replaceMetadata(metadata);
      expect(coordinator.restoreCompletedToolResultsV2, throwsStateError);

      metadata.remove('completed_tool_results_v2');
      replaceMetadata(metadata);
      expect(coordinator.restoreCompletedToolResultsV2(), isEmpty);
      expect(
        repository
            .findActiveWorkItem(sessionId)!
            .continuationMetadata['completed_tool_results'],
        {'tool-1': 'legacy snapshot'},
      );
    },
  );
}
