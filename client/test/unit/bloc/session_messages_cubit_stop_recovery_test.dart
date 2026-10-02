import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
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
  late ConversationCacheStore conversationCacheStore;
  late ConversationCacheRepository conversationCacheRepository;
  late FakeDevicePreferencesRepository preferencesRepository;
  late DeviceCapabilitiesStore capabilitiesStore;
  late WorkspaceToolRuntimeContext workspaceRuntimeContext;
  late DeviceConfig agent1;
  late DeviceConfig agent2;
  late Session session;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;

  setUp(() {
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
    conversationCacheStore = ConversationCacheStore();
    conversationCacheRepository = ConversationCacheRepository(
      cache: conversationCacheStore,
      transport: conversationRepository,
    );
    preferencesRepository = FakeDevicePreferencesRepository();
    final resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilitiesStore = DeviceCapabilitiesStore(resolver);
    workspaceRuntimeContext = WorkspaceToolRuntimeContext();

    agent1 = DeviceConfig(id: 'agent-1', name: 'Agent 1', isOnline: true);
    agent2 = DeviceConfig(id: 'agent-2', name: 'Agent 2', isOnline: true);
    agentRepository.seedAgents([agent1, agent2], activeAgentId: agent1.id);

    session = Session(
      id: 'session-1',
      title: 'Session 1',
      deviceId: agent1.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    conversationRepository.seedSessions(agent1, [session]);

    agentCubit.emitState(DeviceActive(activeAgent: agent1, agents: [agent1, agent2]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
      preferencesRepository: preferencesRepository,
      capabilitiesStore: capabilitiesStore,
      workspaceRuntimeContext: workspaceRuntimeContext,
    );
  });

  tearDown(() async {
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    socket.dispose();
  });

  group('SessionMessagesCubit stop recovery acknowledgment', () {
    test('does not leak subscriptions across multiple agent state switches and acknowledges exactly once', () async {
      await sessionCubit.selectSession(session);
      await Future<void>.delayed(Duration.zero);

      // Simulate switching active agents back and forth 10 times
      for (var i = 0; i < 10; i++) {
        agentCubit.emitState(DeviceActive(activeAgent: agent2, agents: [agent1, agent2]));
        await Future<void>.delayed(Duration.zero);
        agentCubit.emitState(DeviceActive(activeAgent: agent1, agents: [agent1, agent2]));
        await Future<void>.delayed(Duration.zero);
      }

      // Mark stop pending in cache with an owner token
      const stopRequestId = 'stop-req-1';
      const ownerToken = 'token-123';
      await conversationCacheRepository.markStopRecoveryPendingAndFlush(
        agent1.id,
        session.id,
        stopRequestId,
        ownerToken: ownerToken,
      );

      // Emit a single stop draft recovery event
      conversationRepository.emitStopRecovery(
        StopDraftRecovery(
          sessionId: session.id,
          stopRequestId: stopRequestId,
          recoveryReason: 'user_stop',
          inputs: const [
            RecoveredInput(
              requestId: 'user-input-1',
              source: 'pending_steer',
              text: 'Recovered draft text',
              receivedAt: null,
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Verification: exactly ONE acknowledgment sent, NOT 11 or 21!
      expect(conversationRepository.acknowledgeStopRecoveryCalls, equals(1));
      expect(conversationRepository.acknowledgedStopRecoveries.length, equals(1));
      expect(conversationRepository.acknowledgedStopRecoveries.first['stopRequestId'], equals(stopRequestId));
      expect(conversationRepository.acknowledgedStopRecoveries.first['recoveryOwnerToken'], equals(ownerToken));
    });

    test('deduplicates duplicate in-flight stop recovery events with same stopRequestId', () async {
      await sessionCubit.selectSession(session);
      await Future<void>.delayed(Duration.zero);

      const stopRequestId = 'stop-req-2';
      const ownerToken = 'token-456';
      await conversationCacheRepository.markStopRecoveryPendingAndFlush(
        agent1.id,
        session.id,
        stopRequestId,
        ownerToken: ownerToken,
      );

      final recovery = StopDraftRecovery(
        sessionId: session.id,
        stopRequestId: stopRequestId,
        recoveryReason: 'user_stop',
        inputs: const [
          RecoveredInput(
            requestId: 'user-input-2',
            source: 'pending_steer',
            text: 'Draft text',
            receivedAt: null,
          ),
        ],
      );

      // Emit duplicate events concurrently
      conversationRepository.emitStopRecovery(recovery);
      conversationRepository.emitStopRecovery(recovery);
      conversationRepository.emitStopRecovery(recovery);
      await Future<void>.delayed(Duration.zero);

      expect(conversationRepository.acknowledgeStopRecoveryCalls, equals(1));
    });

    test('ignores user_stop recovery if alreadyApplied in session draft', () async {
      await sessionCubit.selectSession(session);
      await Future<void>.delayed(Duration.zero);

      const stopRequestId = 'stop-req-3';
      const ownerToken = 'token-789';
      await conversationCacheRepository.markStopRecoveryPendingAndFlush(
        agent1.id,
        session.id,
        stopRequestId,
        ownerToken: ownerToken,
      );

      // Pre-apply this stopRequestId
      await conversationCacheRepository.prependStopRecoveryAndFlush(
        agent1.id,
        session.id,
        stopRequestId: stopRequestId,
        texts: ['Previously applied'],
      );

      // Reset calls counter
      conversationRepository.acknowledgeStopRecoveryCalls = 0;

      conversationRepository.emitStopRecovery(
        StopDraftRecovery(
          sessionId: session.id,
          stopRequestId: stopRequestId,
          recoveryReason: 'user_stop',
          inputs: const [
            RecoveredInput(
              requestId: 'user-input-3',
              source: 'pending_steer',
              text: 'Late duplicate draft text',
              receivedAt: null,
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Should be rejected because alreadyApplied == true
      expect(conversationRepository.acknowledgeStopRecoveryCalls, equals(0));
    });
  });
}
