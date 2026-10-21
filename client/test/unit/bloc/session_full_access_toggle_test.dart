import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_workspace_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';

import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/fake_device_preferences_repository.dart';
import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_socket.dart';

class _SecurityClient implements WorkspaceSecurityClient {
  final updates = <Map<String, Object?>>[];
  Object? nextError;
  Object? secondError;
  WorkspacePolicy fresh = const WorkspacePolicy(revision: 12);
  int reads = 0;

  @override
  Future<WorkspacePolicy> read(DeviceConfig device, String workspaceId) async {
    reads++;
    return fresh;
  }

  @override
  Stream<WorkspacePolicy> watch(DeviceConfig device, String workspaceId) =>
      const Stream.empty();

  @override
  Future<WorkspacePolicy> update(
    DeviceConfig device,
    String workspaceId, {
    int? expectedRevision,
    WorkspacePermissionMode? permissionMode,
    WorkspaceExecutionMode? executionMode,
    WorkspaceHostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async {
    updates.add({
      'device': device.id,
      'workspace_id': workspaceId,
      'expected_revision': expectedRevision,
      'permission_mode': permissionMode?.value,
    });
    final error = nextError;
    if (error != null) {
      nextError = secondError;
      secondError = null;
      throw error;
    }
    return WorkspacePolicy(
      permissionMode: permissionMode ?? WorkspacePermissionMode.defaultMode,
      revision: (expectedRevision ?? 0) + 1,
    );
  }
}

void main() {
  late FakeSanadSocketService socket;
  late TestDeviceCubit agentCubit;
  late FakeConversationRepository repository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;
  late _SecurityClient security;
  late DeviceConfig agent;

  setUp(() async {
    socket = FakeSanadSocketService()..setConnected(true);
    final agents = FakeDeviceRepository();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agents,
      agentClientRegistry: FakeDeviceClientRegistry(),
    );
    agent = DeviceConfig(
      id: 'local-hardware-1',
      hardwareId: 'local-hardware-1',
      name: 'Local Agent',
      isOnline: true,
    );
    agents.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    repository = FakeConversationRepository();
    repository.seededWorkspacePolicies['/local/project'] = const WorkspacePolicy(
      revision: 5,
    );
    security = _SecurityClient();
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: repository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: repository,
      preferencesRepository: FakeDevicePreferencesRepository(),
      capabilitiesStore: DeviceCapabilitiesStore(
        createTestResolver(cloudSocket: socket, localSocket: socket),
      ),
      workspaceRuntimeContext: WorkspaceToolRuntimeContext(),
      workspaceSecurityClient: security,
    );
    await pumpEventQueue();
    final session = Session(
      id: 'sess-toggle',
      title: 'Toggle',
      deviceId: agent.id,
      workspaceId: 'exec_root:/local/project',
      workspacePath: '/local/project',
      metadata: const {'execution_root': '/local/project'},
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    repository.seedSessions(agent, [session]);
    await sessionCubit.selectSession(session);
    await pumpEventQueue();
  });

  tearDown(() async {
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    socket.dispose();
  });

  test('the Full Access toggle uses the device command client with the seen revision', () async {
    await messagesCubit.setWorkspacePermissionMode(WorkspacePermissionMode.fullAccess);
    await pumpEventQueue();
    expect(security.updates.single, {
      'device': agent.id,
      'workspace_id': 'exec_root:/local/project',
      'expected_revision': 5,
      'permission_mode': 'full_access',
    });
    expect(repository.setPermissionModeRequests, isEmpty);
    expect(messagesCubit.state.permissionMode, WorkspacePermissionMode.fullAccess);

    await messagesCubit.setWorkspacePermissionMode(WorkspacePermissionMode.defaultMode);
    await pumpEventQueue();
    expect(security.updates.last['expected_revision'], 6);
  });

  test('a rejected toggle reports the Agent reason and keeps the Agent state', () async {
    security.nextError = StateError('Workspace policy changed (revision 9). Refresh and retry.');
    await messagesCubit.setWorkspacePermissionMode(WorkspacePermissionMode.fullAccess);
    await pumpEventQueue();
    expect(messagesCubit.state.error, contains('Refresh and retry'));
    expect(messagesCubit.state.permissionMode, WorkspacePermissionMode.defaultMode);
  });

  test('a policy change made elsewhere updates the composer chip and revision', () async {
    repository.emitWorkspacePolicyChange(
      'exec_root:/local/project',
      const WorkspacePolicy(
        permissionMode: WorkspacePermissionMode.fullAccess,
        revision: 9,
      ),
    );
    await pumpEventQueue();
    expect(messagesCubit.state.permissionMode, WorkspacePermissionMode.fullAccess);
    await messagesCubit.setWorkspacePermissionMode(WorkspacePermissionMode.defaultMode);
    await pumpEventQueue();
    expect(security.updates.single['expected_revision'], 9);
  });

  test('a stale revision re-fetches and retries the toggle once', () async {
    security.nextError = DeviceCommandException('changed', code: 'stale_revision');
    final failure = await messagesCubit.setWorkspacePermissionMode(
      WorkspacePermissionMode.fullAccess,
    );
    await pumpEventQueue();
    expect(failure, isNull);
    expect(security.reads, 1);
    expect(security.updates.map((u) => u['expected_revision']), [5, 12]);
    expect(messagesCubit.state.permissionMode, WorkspacePermissionMode.fullAccess);
  });

  test('a toggle that stays stale reports a visible failure', () async {
    security
      ..nextError = DeviceCommandException('changed', code: 'stale_revision')
      ..secondError = DeviceCommandException('changed', code: 'stale_revision');
    final failure = await messagesCubit.setWorkspacePermissionMode(
      WorkspacePermissionMode.fullAccess,
    );
    expect(failure, WorkspacePolicyChangeFailure.staleRevision);
    expect(security.updates, hasLength(2));
  });

  test('any other rejection reports a visible failure', () async {
    security.nextError = DeviceCommandException('nope', code: 'permission_denied');
    final failure = await messagesCubit.setWorkspacePermissionMode(
      WorkspacePermissionMode.fullAccess,
    );
    expect(failure, WorkspacePolicyChangeFailure.failed);
    expect(security.reads, 0);
  });
}
