import 'dart:async';

import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:test/test.dart';

class FakeSuspendedResumeService extends SuspendedResumeService {
  static final PermissionManager _permissionManager = PermissionManager(
    policyStore: const WorkspacePolicyStore(),
    platformRuntimeBridge: PlatformRuntimeBridge(),
    checkpointStore: SuspendedCheckpointStore(sessionManager: SessionManager()),
  );

  FakeSuspendedResumeService()
    : super(
        checkpointStore: SuspendedCheckpointStore(
          sessionManager: SessionManager(),
        ),
        sessionManager: SessionManager(),
        runtimeCatalog: LocalRuntimeCatalog(
          workspaceRuntimeService: LocalWorkspaceRuntimeService(
            skillRegistry: const SkillRegistry(),
            skillLoadService: SkillLoadService(registry: const SkillRegistry()),
          ),
          permissionManager: _permissionManager,
          platformRuntimeBridge: PlatformRuntimeBridge(),
        ),
        runtimeContextBuilder: const RuntimeContextBuilder(
          skillRegistry: SkillRegistry(),
        ),
        workspaceRuntimeService: LocalWorkspaceRuntimeService(
          skillRegistry: const SkillRegistry(),
          skillLoadService: SkillLoadService(registry: const SkillRegistry()),
        ),
        permissionManager: _permissionManager,
      );

  int callCount = 0;
  String? lastRequestId;
  Map<String, dynamic>? lastDecision;
  final List<GatewayResponse> emittedResponses = [];

  @override
  Future<bool> resumeFromDecision({
    required String requestId,
    required Map<String, dynamic> decision,
    required SuspendedResponseEmitter emitResponse,
    SuspendedDecisionClaimed? onClaimed,
  }) async {
    callCount++;
    await onClaimed?.call();
    lastRequestId = requestId;
    lastDecision = decision;
    final response = GatewayResponse(
      sessionId: 'thread-resume',
      message: Message(role: MessageRole.assistant, content: 'resumed'),
      isComplete: true,
      runId: 'resume-run-1',
    );
    emittedResponses.add(response);
    await emitResponse(response);
    return true;
  }
}

void main() {
  group('PlatformRuntimeBridge resume fallback', () {
    late AgentStateDatabase state;

    setUp(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      state = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(state);
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      await getIt.reset();
      state.dispose();
    });

    test(
      'routes permission replies to resume service when no in-memory waiter exists',
      () async {
        final bridge = PlatformRuntimeBridge();
        addTearDown(() => bridge.unregisterSession('thread-resume'));
        final resumeService = FakeSuspendedResumeService();
        final deliveredResponses = <GatewayResponse>[];
        final delivered = Completer<void>();

        getIt.registerSingleton<SuspendedResumeService>(resumeService);
        bridge.registerSessionHandlers(
          'thread-resume',
          responseEmitter: (response) async {
            deliveredResponses.add(response);
            if (deliveredResponses.length == 2 && !delivered.isCompleted) {
              delivered.complete();
            }
          },
        );

        final handled = bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            payload: {
              'request_id': 'permission-123',
              'allowed': true,
              'scope': 'workspace',
            },
            sessionId: 'thread-resume',
          ),
        );

        expect(handled, isTrue);
        await delivered.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError(
            'Expected two responses, received ${deliveredResponses.length}: '
            '${deliveredResponses.map((response) => response.message.metadata?['canonical_event_type']).toList()}',
          ),
        );

        expect(resumeService.callCount, equals(1));
        expect(resumeService.lastRequestId, equals('permission-123'));
        expect(resumeService.lastDecision?['allowed'], isTrue);
        expect(deliveredResponses, hasLength(2));
        expect(
          deliveredResponses.first.message.metadata?['canonical_event_type'],
          CanonicalEventTypes.toolPermissionResolved,
        );
        expect(deliveredResponses.last.sessionId, equals('thread-resume'));
        expect(deliveredResponses.last.message.content, equals('resumed'));
      },
    );
  });
}
