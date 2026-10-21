// Reproduction/regression coverage for issue #213: a pending
// `system_ask_user` question (or permission request) must survive an abrupt
// daemon stop and restart, restoring as a durable interactive wait — never as
// the ambiguous-interruption error result.
//
// Unlike the mocked preservation tests in interfaces_test.dart, this suite
// binds a real SessionManager + SuspendedCheckpointStore to an in-memory state
// database so the exact persisted shapes written by the real runtime flow
// through startup recovery.

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

import '../interfaces_test.mocks.dart';

void main() {
  const sessionId = 'repro-213-session';
  const workItemId = 'repro-213-work';
  const toolCallId = 'repro-213-ask-call';
  const requestId = 'repro-213-request';

  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository persisted;
  late SessionManager sessionManager;
  late SuspendedCheckpointStore checkpointStore;

  setUp(() {
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    persisted = PersistedRuntimeStateRepository.fromState(state);
    SessionManager.resetForTesting();
    getIt.registerSingleton<AgentStateDatabase>(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(persisted);
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(
        ProviderInstanceRepository(state),
        ProviderRateLimiter(),
      )..attachPersistedState(persisted),
    );
    state.db.execute('''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES ('$sessionId', 'model-a', '2026-10-15', '2026-10-15')
      ''');

    sessionManager = SessionManager();
    getIt.registerSingleton<SessionManager>(sessionManager);
    checkpointStore = SuspendedCheckpointStore(sessionManager: sessionManager);
    getIt.registerSingleton<SuspendedCheckpointStore>(checkpointStore);
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (_, _) => MockAgentRunner(),
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  /// Seeds the durable state exactly as the real runtime leaves it after an
  /// abrupt kill while `system_ask_user` awaits the user: the assistant batch
  /// sits in history without a tool result, the work item is `running` with
  /// the ask tool call in `currently_executing_tools`, and the tool's
  /// suspended checkpoint is still `awaiting_permission`.
  Future<void> seedKilledMidAsk({
    SessionWorkState workItemState = SessionWorkState.running,
    String toolName = 'system_ask_user',
    bool withCheckpoint = true,
    String checkpointStatus = 'awaiting_permission',
  }) async {
    sessionManager.saveSessionHistory(sessionId, [
      Message(
        role: MessageRole.user,
        content: 'build the thing',
        metadata: const {'request_id': 'turn-request-1'},
      ),
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(
            id: toolCallId,
            name: toolName,
            arguments: const {
              'questions': [
                {'question': 'Which target?', 'options': <String>[]},
              ],
            },
          ),
        ],
      ),
    ]);

    final now = DateTime.now().toUtc();
    if (withCheckpoint) {
      await checkpointStore.save(
        SuspendedCheckpoint(
          checkpointId: 'ask-$requestId',
          sessionId: sessionId,
          requestId: requestId,
          toolCallId: toolCallId,
          toolName: toolName,
          status: checkpointStatus,
          resolvedDecision: checkpointStatus == 'decision_ready'
              ? const {'answer': 'staging'}
              : null,
          toolArguments: const {
            'questions': [
              {'question': 'Which target?', 'options': <String>[]},
            ],
          },
          permissionPayload: const {
            'request_id': requestId,
            'tool_name': 'system_ask_user',
            'tool_call_id': toolCallId,
            'questions': [
              {'question': 'Which target?', 'options': <String>[]},
            ],
          },
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    persisted.insertWorkItem(
      SessionWorkItem(
        workItemId: workItemId,
        sessionId: sessionId,
        requestId: 'turn-request-1',
        sequence: 1,
        state: workItemState,
        attempt: 0,
        payload: const {'message': 'build the thing'},
        continuationMetadata: {
          'owner_run_id': 'run-repro-213',
          'owner_generation': 1,
          'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
          'currently_executing_tools': [toolCallId],
          'tool_replay_safety': {toolCallId: false},
          'tool_started_at': {toolCallId: now.toIso8601String()},
        },
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Runs startup recovery and returns the restorer's log messages.
  Future<List<String>> restoreCapturingRestorerLogs([
    SessionRunOrchestrator? orchestrator,
  ]) async {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final messages = <String>[];
    final subscription = Logger.root.onRecord
        .where((record) => record.loggerName == 'SessionRecoveryRestorer')
        .listen((record) => messages.add(record.message));
    try {
      await (orchestrator ?? SessionRunOrchestrator()).restorePersistedState();
    } finally {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    }
    return messages;
  }

  bool historyHasToolResultFor(String id) => sessionManager
      .getSession(sessionId)!
      .messages
      .any(
        (message) =>
            message.role == MessageRole.tool && message.toolCallId == id,
      );

  test(
    'abrupt kill mid-ask restores as interactive wait without synthetic error',
    () async {
      await seedKilledMidAsk();

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();

      final workItem = persisted.findWorkItem(workItemId);
      expect(workItem?.state, SessionWorkState.waiting);
      expect(
        workItem
            ?.continuationMetadata['auto_recover_interrupted_tools_as_unknown'],
        isNull,
      );

      final checkpoint = await checkpointStore.getByRequestId(requestId);
      expect(checkpoint?.status, 'awaiting_permission');

      expect(historyHasToolResultFor(toolCallId), isFalse);
      expect(orchestrator.hasSuspendedEvent(sessionId), isTrue);
    },
  );

  test('restored interactive wait stays answerable after restart', () async {
    await seedKilledMidAsk();
    final orchestrator = SessionRunOrchestrator();
    await orchestrator.restorePersistedState();

    // The pending question stays discoverable for clients after restart.
    final pending = await checkpointStore.getByRequestId(requestId);
    expect(pending?.toolName, 'system_ask_user');
    expect(pending?.sessionId, sessionId);
    expect(
      (pending?.permissionPayload['questions'] as List?)?.length,
      greaterThan(0),
    );
  });

  test(
    'abrupt kill while claiming the wait does not terminalize the pending ask',
    () async {
      // A second abrupt stop can land the durable owner in `resuming` while
      // the user has still not answered: the claim was recorded but the tool
      // call never re-ran. The pending question must survive as a wait.
      await seedKilledMidAsk(workItemState: SessionWorkState.resuming);

      final logs = await restoreCapturingRestorerLogs();
      expect(
        logs,
        contains(
          'Reclassifying interrupted interactive wait for work item '
          '$workItemId to waiting before reclaim.',
        ),
      );

      final workItem = persisted.findWorkItem(workItemId);
      expect(
        workItem
            ?.continuationMetadata['auto_recover_interrupted_tools_as_unknown'],
        isNull,
        reason:
            'a pending interactive wait must not be recovered as an '
            'unknown-outcome tool',
      );
      expect(workItem?.state, SessionWorkState.waiting);
      expect(
        (await checkpointStore.getByRequestId(requestId))?.status,
        'awaiting_permission',
      );
      expect(historyHasToolResultFor(toolCallId), isFalse);
    },
  );

  test('abrupt kill while reclaiming a resolved decision still reaches the '
      'decision-ready branch', () async {
    // The suspended set also contains `decision_ready` ids, so the
    // unresolved-wait guard must not shadow the decision-ready branch: an
    // answered decision keeps its own outcome (`waiting`, answer intact)
    // and its own diagnostic.
    await seedKilledMidAsk(
      workItemState: SessionWorkState.resuming,
      checkpointStatus: 'decision_ready',
    );

    // Production wires the persisted-decision resumer, which is what makes
    // startup list `decision_ready` checkpoints at all. It accepts the reclaim
    // without claiming so the reclassified state stays observable.
    final logs = await restoreCapturingRestorerLogs(
      SessionRunOrchestrator(
        resumePersistedSuspendedDecision:
            ({required checkpoint, required emitResponse}) async => true,
      ),
    );

    expect(
      logs,
      contains(
        'Reclassifying interrupted resolved input for work item '
        '$workItemId to waiting before reclaim.',
      ),
    );
    expect(
      logs.where((m) => m.contains('Reclassifying interrupted interactive')),
      isEmpty,
    );
    final workItem = persisted.findWorkItem(workItemId);
    expect(workItem?.state, SessionWorkState.waiting);
    expect(
      workItem
          ?.continuationMetadata['auto_recover_interrupted_tools_as_unknown'],
      isNull,
    );
    expect(
      (await checkpointStore.getByRequestId(requestId))?.status,
      'decision_ready',
    );
    expect(historyHasToolResultFor(toolCallId), isFalse);
  });

  test(
    'abrupt kill mid-permission-prompt restores the prompt as a wait',
    () async {
      await seedKilledMidAsk(
        workItemState: SessionWorkState.resuming,
        toolName: 'shell_execute',
      );

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();

      final workItem = persisted.findWorkItem(workItemId);
      expect(
        workItem
            ?.continuationMetadata['auto_recover_interrupted_tools_as_unknown'],
        isNull,
      );
      expect(workItem?.state, SessionWorkState.waiting);
      expect(
        (await checkpointStore.getByRequestId(requestId))?.status,
        'awaiting_permission',
      );
    },
  );

  test(
    'a side-effecting tool without a user-input checkpoint is not restored as '
    'a wait',
    () async {
      // Regression guard for the safe-recovery behavior of #124: only tools
      // owned by an unresolved user-input checkpoint may be restored as waits.
      // A crashed non-idempotent tool with no checkpoint stays blocked instead.
      await seedKilledMidAsk(
        workItemState: SessionWorkState.blocked,
        toolName: 'shell_execute',
        withCheckpoint: false,
      );

      final orchestrator = SessionRunOrchestrator();
      await orchestrator.restorePersistedState();

      final workItem = persisted.findWorkItem(workItemId);
      expect(workItem?.state, SessionWorkState.blocked);
      expect(
        workItem
            ?.continuationMetadata['auto_recover_interrupted_tools_as_unknown'],
        isNull,
      );
    },
  );
}
