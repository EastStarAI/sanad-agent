import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/secrets/secret_acquisition.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

/// Plan 84: a secret-request response is accepted only from the owner, its
/// values go straight to the vault, and only a value-free decision reaches the
/// tool, the in-memory resolution record or the durable checkpoint.
void main() {
  const sessionId = 'secret-bridge-session';
  const secretValue = 'dummy-bridge-secret-84';
  const fields = [
    {'name': 'DEMO_TOKEN', 'label': 'Token', 'masked': true, 'required': true},
    {'name': 'DEMO_USER', 'label': 'User', 'masked': false, 'required': false},
  ];

  late Directory home;
  late MemoryAgentSecretStore store;
  late SecretVaults vaults;
  late PlatformRuntimeBridge bridge;

  setUp(() async {
    await getIt.reset();
    getIt.allowReassignment = true;
    SessionManager.resetForTesting();
    home = Directory(
      Directory.systemTemp
          .createTempSync('sanad-secret-bridge')
          .resolveSymbolicLinksSync(),
    );
    setSanadHomeOverride(home.path);
    await SanadHomeBootstrap.identity().prepare();
    store = MemoryAgentSecretStore();
    vaults = await SecretVaults.open(store: store);
    bridge = PlatformRuntimeBridge(
      secretAcquisition: SecretAcquisition(
        vault: UserSecretVault(vaults: () => vaults),
      ),
    );
    bridge.attachResponseSink((_) {});
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    home.deleteSync(recursive: true);
  });

  CanonicalEvent response(
    String requestId,
    Map<String, dynamic> body, {
    CommandAuthority authority = CommandAuthority.owner,
  }) => CanonicalEvent(
    type: CanonicalEventTypes.toolPermissionResponse,
    sessionId: sessionId,
    payload: {
      'request_id': requestId,
      'session_id': sessionId,
      ...body,
      CommandAuthority.payloadKey: authority.value,
    },
  );

  Future<Map<String, dynamic>> pendingRequest(String requestId) =>
      bridge.requestToolPermission(
        sessionId: sessionId,
        payload: {
          'request_id': requestId,
          'tool_name': SecretToolNames.request,
          'reason': 'connect',
          'fields': fields,
        },
      );

  group('live waiter', () {
    test(
      'an owner save stores the values and hands the tool names only',
      () async {
        final pending = pendingRequest('req-save');
        final outcome = await bridge.handlePermissionResponse(
          response('req-save', {
            'allowed': true,
            'decision': 'allow',
            SecretAcquisition.valuesKey: {'DEMO_TOKEN': secretValue},
          }),
        );

        expect(outcome.isSuccess, isTrue, reason: outcome.errorMessage);
        final decision = await pending;
        expect(jsonEncode(decision), isNot(contains(secretValue)));
        expect(decision[SecretAcquisition.outcomeKey], 'stored');
        expect(decision[SecretAcquisition.namesKey], ['DEMO_TOKEN']);
        expect(vaults.custom.read('DEMO_TOKEN'), secretValue);

        // A duplicate is already resolved, and the retained record is clean.
        final duplicate = await bridge.handlePermissionResponse(
          response('req-save', {
            'allowed': true,
            SecretAcquisition.valuesKey: {'DEMO_TOKEN': 'dummy-other'},
          }),
        );
        expect(duplicate.errorCode, 'ALREADY_RESOLVED');
        expect(vaults.custom.read('DEMO_TOKEN'), secretValue);
      },
    );

    test(
      'a non-owner response is refused and the request stays pending',
      () async {
        var completed = false;
        final pending = pendingRequest('req-unverified')
          ..then((_) => completed = true);
        final outcome = await bridge.handlePermissionResponse(
          response('req-unverified', {
            'allowed': true,
            SecretAcquisition.valuesKey: {'DEMO_TOKEN': secretValue},
          }, authority: CommandAuthority.unverified),
        );
        expect(outcome.errorCode, 'PERMISSION_DENIED');
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        expect(vaults.custom.ids, isEmpty);

        await bridge.handlePermissionResponse(
          response('req-unverified', {'allowed': false, 'decision': 'deny'}),
        );
        expect((await pending)[SecretAcquisition.outcomeKey], 'skipped');
      },
    );

    test(
      'values for unrequested names or a missing required value are refused',
      () async {
        final pending = pendingRequest('req-invalid');
        for (final values in [
          {'DEMO_TOKEN': secretValue, 'OTHER_NAME': 'dummy-x'},
          {'DEMO_USER': 'dummy-user'},
          {'DEMO_TOKEN': ''},
          {'DEMO_TOKEN': 7},
        ]) {
          final outcome = await bridge.handlePermissionResponse(
            response('req-invalid', {
              'allowed': true,
              SecretAcquisition.valuesKey: values,
            }),
          );
          expect(outcome.errorCode, 'INVALID_SECRET_VALUES', reason: '$values');
        }
        final answer = await bridge.handlePermissionResponse(
          response('req-invalid', {'allowed': true, 'answer': '{}'}),
        );
        expect(answer.errorCode, 'INVALID_INTERVENTION_KIND');
        expect(vaults.custom.ids, isEmpty);

        await bridge.handlePermissionResponse(
          response('req-invalid', {'allowed': false}),
        );
        await pending;
      },
    );

    test(
      'a vault failure resolves the request as failed without a value',
      () async {
        store.available = false;
        final pending = pendingRequest('req-fail');
        final outcome = await bridge.handlePermissionResponse(
          response('req-fail', {
            'allowed': true,
            SecretAcquisition.valuesKey: {'DEMO_TOKEN': secretValue},
          }),
        );
        expect(outcome.isSuccess, isTrue);
        final decision = await pending;
        expect(decision[SecretAcquisition.outcomeKey], 'failed');
        expect(jsonEncode(decision), isNot(contains(secretValue)));
      },
    );
  });

  group('persisted checkpoint after restart', () {
    late AgentStateDatabase state;
    late PersistedRuntimeStateRepository persisted;
    late _ClaimingResumeService resume;
    const requestId = 'req-persisted';
    const toolCallId = 'call-persisted';

    setUp(() async {
      state = AgentStateDatabase.inMemory();
      persisted = PersistedRuntimeStateRepository.fromState(state);
      getIt.registerSingleton<AgentStateDatabase>(state);
      getIt.registerSingleton<PersistedRuntimeStateRepository>(persisted);
      state.db.execute('''
        INSERT INTO sessions (session_id, model, created_at, updated_at)
        VALUES ('$sessionId', 'model-a', '2026-10-21', '2026-10-21')
        ''');
      final sessionManager = SessionManager();
      getIt.registerSingleton<SessionManager>(sessionManager);
      final checkpoints = SuspendedCheckpointStore(
        sessionManager: sessionManager,
      );
      getIt.registerSingleton<SuspendedCheckpointStore>(checkpoints);
      resume = _ClaimingResumeService(persisted, checkpoints);
      getIt.registerSingleton<SuspendedResumeService>(resume);

      sessionManager.saveSessionHistory(sessionId, [
        Message(role: MessageRole.user, content: 'connect'),
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: toolCallId,
              name: SecretToolNames.request,
              arguments: const {'reason': 'connect', 'fields': fields},
            ),
          ],
        ),
      ]);
      final now = DateTime.now().toUtc();
      await checkpoints.save(
        SuspendedCheckpoint(
          checkpointId: 'secret-$requestId',
          sessionId: sessionId,
          requestId: requestId,
          toolCallId: toolCallId,
          toolName: SecretToolNames.request,
          status: 'awaiting_permission',
          toolArguments: const {'reason': 'connect', 'fields': fields},
          permissionPayload: const {
            'request_id': requestId,
            'tool_name': SecretToolNames.request,
            'reason': 'connect',
            'fields': fields,
          },
          createdAt: now,
          updatedAt: now,
        ),
      );
      persisted.insertWorkItem(
        SessionWorkItem(
          workItemId: 'work-persisted',
          sessionId: sessionId,
          requestId: 'turn-1',
          sequence: 1,
          state: SessionWorkState.waiting,
          attempt: 0,
          continuationMetadata: {
            'owner_run_id': 'run-1',
            'owner_generation': 1,
            'checkpoint_kind': AgentRunner.checkpointKindAfterToolResult,
            'currently_executing_tools': [toolCallId],
          },
          createdAt: now,
          updatedAt: now,
        ),
      );
    });

    tearDown(() => state.dispose());

    test(
      'the durable resolved decision and the resume input carry no value',
      () async {
        final outcome = await bridge.handlePermissionResponse(
          response(requestId, {
            'allowed': true,
            SecretAcquisition.valuesKey: {'DEMO_TOKEN': secretValue},
          }),
        );

        expect(outcome.isSuccess, isTrue, reason: outcome.errorMessage);
        expect(resume.decisions, hasLength(1));
        expect(
          jsonEncode(resume.decisions.single),
          isNot(contains(secretValue)),
        );
        expect(resume.decisions.single[SecretAcquisition.outcomeKey], 'stored');
        final rows = state.db.select(
          'SELECT resolved_decision, status FROM suspended_checkpoints',
        );
        expect(rows.single['status'], 'decision_ready');
        expect(
          '${rows.single['resolved_decision']}',
          isNot(contains(secretValue)),
        );
        expect(vaults.custom.read('DEMO_TOKEN'), secretValue);
      },
    );

    test('a non-owner response never reaches the resume service', () async {
      final outcome = await bridge.handlePermissionResponse(
        response(requestId, {
          'allowed': true,
          SecretAcquisition.valuesKey: {'DEMO_TOKEN': secretValue},
        }, authority: CommandAuthority.unverified),
      );
      expect(outcome.errorCode, 'PERMISSION_DENIED');
      expect(resume.decisions, isEmpty);
      expect(vaults.custom.ids, isEmpty);
    });
  });
}

/// Claims through the real durable aggregate, then reports the claim.
class _ClaimingResumeService implements SuspendedResumeService {
  _ClaimingResumeService(this._persisted, this._checkpoints);

  final PersistedRuntimeStateRepository _persisted;
  final SuspendedCheckpointStore _checkpoints;
  final decisions = <Map<String, dynamic>>[];

  @override
  Future<bool> resumeFromDecision({
    required String requestId,
    required Map<String, dynamic> decision,
    required SuspendedResponseEmitter emitResponse,
    SuspendedDecisionClaimed? onClaimed,
  }) async {
    final checkpoint = await _checkpoints.getByRequestId(requestId);
    final claim = _persisted.claimSuspendedDecision(
      checkpoint: checkpoint!,
      decision: decision,
    );
    if (claim == null) return false;
    decisions.add(decision);
    await onClaimed?.call();
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
