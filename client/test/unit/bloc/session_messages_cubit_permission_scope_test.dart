import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';

import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/fake_device_preferences_repository.dart';
import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_socket.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late FakeConversationRepository conversationRepository;
  late FakeDevicePreferencesRepository preferencesRepository;
  late DeviceCapabilitiesStore capabilitiesStore;
  late WorkspaceToolRuntimeContext workspaceRuntimeContext;
  late DeviceConfig localAgent;
  late DeviceConfig remoteAgent;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;

  setUp(() async {
    socket = FakeSanadSocketService();
    socket.setConnected(true);
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    conversationRepository = FakeConversationRepository();
    preferencesRepository = FakeDevicePreferencesRepository();
    final resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilitiesStore = DeviceCapabilitiesStore(resolver);
    workspaceRuntimeContext = WorkspaceToolRuntimeContext();

    localAgent = DeviceConfig(
      id: 'local-hardware-1',
      hardwareId: 'local-hardware-1',
      name: 'Local Agent',
      isOnline: true,
    );
    remoteAgent = DeviceConfig(
      id: 'remote-cloud-2',
      hardwareId: 'remote-hardware-2',
      name: 'Remote Agent',
      isOnline: true,
    );
    agentRepository.seedAgents([localAgent, remoteAgent], activeAgentId: localAgent.id);
    agentCubit.emitState(DeviceActive(activeAgent: localAgent, agents: [localAgent, remoteAgent]));

    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: preferencesRepository,
      capabilitiesStore: capabilitiesStore,
      workspaceRuntimeContext: workspaceRuntimeContext,
    );
    await pumpEventQueue();
  });

  tearDown(() async {
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    socket.dispose();
  });

  group('SessionMessagesCubit permission and device scope isolation', () {
    test('explicit downgrade from fullAccess to defaultMode updates state and policy store', () async {
      final sessionWithFullAccess = Session(
        id: 'sess-full-access',
        title: 'Full Access Session',
        deviceId: localAgent.id,
        workspaceId: 'exec_root:/local/project',
        workspacePath: '/local/project',
        metadata: {
          'execution_root': '/local/project',
          'allow_all_tools': true,
          'permission_mode': 'full_access',
        },
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      conversationRepository.seedSessions(localAgent, [sessionWithFullAccess]);
      await sessionCubit.selectSession(sessionWithFullAccess);
      await pumpEventQueue();

      expect(messagesCubit.state.selectedWorkspace, isNotNull);
      expect(messagesCubit.state.permissionMode, equals(WorkspacePermissionMode.fullAccess));

      // Explicit downgrade
      await messagesCubit.setWorkspacePermissionMode(WorkspacePermissionMode.defaultMode);
      await pumpEventQueue();
      expect(messagesCubit.state.permissionMode, equals(WorkspacePermissionMode.defaultMode));
      expect(conversationRepository.setPermissionModeRequests, hasLength(1));
      expect(
        conversationRepository.setPermissionModeRequests.first['mode'],
        equals(WorkspacePermissionMode.defaultMode),
      );
    });

    test('grant revocation/expiry in session metadata downgrades permissionMode back to defaultMode', () async {
      final sessionWithGrant = Session(
        id: 'sess-grant-expiry',
        title: 'Grant Expiry Session',
        deviceId: localAgent.id,
        workspaceId: 'exec_root:/local/project',
        workspacePath: '/local/project',
        metadata: {
          'execution_root': '/local/project',
          'allow_all_tools': true,
          'permission_mode': 'full_access',
        },
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      conversationRepository.seedSessions(localAgent, [sessionWithGrant]);
      await sessionCubit.selectSession(sessionWithGrant);
      await pumpEventQueue();

      expect(messagesCubit.state.permissionMode, equals(WorkspacePermissionMode.fullAccess));

      // Grant expires or is revoked: session update arrives with allow_all_tools false / default_mode
      final sessionRevoked = sessionWithGrant.copyWith(
        metadata: {
          'execution_root': '/local/project',
          'allow_all_tools': false,
          'permission_mode': 'default_mode',
        },
      );
      await sessionCubit.selectSession(sessionRevoked);
      await pumpEventQueue();

      expect(messagesCubit.state.permissionMode, equals(WorkspacePermissionMode.defaultMode));
    });

    test(
      'switching from session with allow_all_tools to normal session sharing workspace does not leak fullAccess authority',
      () async {
        const workspacePath = '/shared/workspace';
        const workspaceId = 'ws-shared-1';
        final workspace = DeviceWorkspace(
          id: workspaceId,
          name: 'Shared Workspace',
          path: workspacePath,
          trustState: 'untrusted',
        );
        conversationRepository.workspaces.add(workspace);

        final sessionA = Session(
          id: 'sess-a-yolo',
          title: 'Session A with YOLO',
          deviceId: localAgent.id,
          workspaceId: workspaceId,
          workspacePath: workspacePath,
          metadata: {'allow_all_tools': true, 'permission_mode': 'full_access'},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final sessionB = Session(
          id: 'sess-b-normal',
          title: 'Session B Normal',
          deviceId: localAgent.id,
          workspaceId: workspaceId,
          workspacePath: workspacePath,
          metadata: {},
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        conversationRepository.seedSessions(localAgent, [sessionA, sessionB]);

        // Select Session A
        await sessionCubit.selectSession(sessionA);
        await pumpEventQueue();
        expect(messagesCubit.state.permissionMode, equals(WorkspacePermissionMode.fullAccess));

        // Select Session B (shares same workspace, but no allow_all_tools)
        await sessionCubit.selectSession(sessionB);
        await pumpEventQueue();
        expect(messagesCubit.state.permissionMode, equals(WorkspacePermissionMode.defaultMode));
      },
    );

    test('device-less local session with execution root does not cross into remote agent', () async {
      final localSessionWithoutDeviceId = Session(
        id: 'sess-deviceless',
        title: 'Deviceless Local Session',
        deviceId: null,
        workspaceId: null,
        metadata: {'execution_root': '/local/isolated/root'},
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      conversationRepository.seedSessions(localAgent, [localSessionWithoutDeviceId]);

      // Active agent is localAgent -> resolves local execution root workspace
      await sessionCubit.selectSession(localSessionWithoutDeviceId);
      await pumpEventQueue();
      expect(messagesCubit.state.selectedWorkspace, isNotNull);
      expect(messagesCubit.state.selectedWorkspace?.id, equals('exec_root:/local/isolated/root'));

      // Switch active agent to remoteAgent -> execution root does not bleed to remote device
      agentCubit.emitState(DeviceActive(activeAgent: remoteAgent, agents: [localAgent, remoteAgent]));
      await pumpEventQueue();
      expect(messagesCubit.state.selectedWorkspace, isNull);
    });
    // Task 110 port guard: re-subscribing to an agent without a selected
    // session keeps that agent's manually selected workspace. Only a resolved
    // session workspace replaces it.
    test('agent re-subscribe without a selected session keeps the manual workspace', () async {
      final workspace = DeviceWorkspace(
        id: 'ws-manual-1',
        name: 'Manual Workspace',
        path: '/manual/workspace',
        trustState: 'untrusted',
      );
      socket.autoCapabilitiesPayload = const {
        'supports_workspaces': true,
        'supports_workspace_selection': true,
      };
      conversationRepository.workspaces.add(workspace);
      await messagesCubit.refreshWorkspaces();
      await pumpEventQueue();
      messagesCubit.selectWorkspace(workspace);
      await pumpEventQueue();
      expect(messagesCubit.state.selectedWorkspace?.id, workspace.id);

      agentCubit.emitState(DeviceActive(activeAgent: remoteAgent, agents: [localAgent, remoteAgent]));
      await pumpEventQueue();
      agentCubit.emitState(DeviceActive(activeAgent: localAgent, agents: [localAgent, remoteAgent]));
      await pumpEventQueue();

      expect(messagesCubit.state.selectedWorkspace?.id, workspace.id);
    });
  });
}
