import 'dart:async';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/infrastructure/devices/models/device_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/conversations/data/repositories/socket_conversation_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import '../../helpers/fake_device_preferences_repository.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../mocks/mock_socket_service.dart';
import '../../helpers/fake_socket.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeSanadSocketService localSocket;
  late _FakeDeviceRepository repository;
  late _TestDeviceCubit agentCubit;
  late _FakeDeviceClientRegistry clientRegistry;
  late ConversationRepository conversationRepository;
  late _FakeDeviceClient client;
  late DeviceConfig agent;
  late Session session;

  setUp(() {
    socket = FakeSanadSocketService();
    localSocket = FakeSanadSocketService();
    repository = _FakeDeviceRepository();
    clientRegistry = _FakeDeviceClientRegistry();
    agentCubit = _TestDeviceCubit(
      socketService: socket,
      agentRepository: repository,
      agentClientRegistry: clientRegistry,
    );
    conversationRepository = SocketConversationRepository(clientRegistry);
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    session = Session(
      id: 'session-1',
      title: 'First session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    client = _FakeDeviceClient(config: agent, controller: socket, initialSessions: [session]);
    agentCubit.registerClient(agent.id, client);
    repository.seedAgents([agent], activeAgentId: agent.id);
  });

  tearDown(() async {
    await agentCubit.close();
    socket.dispose();
    localSocket.dispose();
  });

  test('does not request sessions before socket is connected', () async {
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(client.getSessionsCalls, 0);
    expect(cubit.state.agentSessions[agent.id], isNull);

    await cubit.close();
  });

  test('loads sessions for agents after socket is connected', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(client.getSessionsCalls, 1);
    expect(cubit.state.agentSessions[agent.id], [session]);
    expect(cubit.state.loadingSessions[agent.id], isNull);

    await cubit.close();
  });

  test('production cache path projects authoritative sections into state', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cacheStore = ConversationCacheStore();
    final cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(cacheStore.activeDeviceId, agent.id);
    expect(cubit.state.agentSessions[agent.id], [session]);

    cacheRepository.applySessionDeleted(agent.id, session.id);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.agentSessions[agent.id], isEmpty);

    await cubit.close();
    cacheStore.dispose();
  });

  test('production cache path exposes persisted snapshot while device is offline', () async {
    final offlineAgent = agent.copyWith(isOnline: false);
    final cachedSession = session.copyWith(deviceId: offlineAgent.id);
    final cacheStore = ConversationCacheStore();
    final generation = cacheStore.advanceGeneration(offlineAgent.id, null);
    cacheStore.applySectionRefreshed(
      offlineAgent.id,
      null,
      [cachedSession],
      nextCursor: null,
      hasMore: false,
      generation: generation,
    );
    cacheStore.setActiveDevice(offlineAgent.id);
    final cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );
    agentCubit.emitState(
      DeviceActive(activeAgent: offlineAgent, agents: [offlineAgent]),
    );

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );

    expect(cubit.state.agentSessions[offlineAgent.id], [cachedSession]);
    expect(client.getSessionsCalls, 0);

    await cubit.close();
    cacheStore.dispose();
  });

  test('pending steer acceptance clears only its matching session draft', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cacheRepository = ConversationCacheRepository(
      cache: ConversationCacheStore(),
      transport: conversationRepository,
    );
    cacheRepository.setSessionDraft(
      agent.id,
      session.id,
      ConversationDraft.empty().copyWith(text: 'steer me'),
    );
    cacheRepository.markSessionDraftAwaitingAcceptance(
      agent.id,
      session.id,
      'steer-request',
    );
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);

    cubit.handleGlobalSessionEventForTesting({
      'device_id': agent.id,
      'event': 'session.pending_steer_changed',
      'payload': {
        'session_id': session.id,
        'request_id': 'steer-request',
        'state': 'pending',
        'received_at': DateTime(2026, 1, 2).toIso8601String(),
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(cacheRepository.sessionDraft(agent.id, session.id), isNull);

    await cubit.close();
  });

  test('does not load sessions for offline agents during bootstrap', () async {
    final offlineAgent = agent.copyWith(id: 'agent-offline', name: 'Computer', isOnline: false);
    final offlineClient = _FakeDeviceClient(config: offlineAgent, controller: socket, initialSessions: const []);
    agentCubit.registerClient(offlineAgent.id, offlineClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent, offlineAgent]));

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(client.getSessionsCalls, 1);
    expect(offlineClient.getSessionsCalls, 0);

    await cubit.close();
  });

  test('does not infer pending permission state from session metadata', () async {
    socket.setConnected(true);
    final pendingSession = session.copyWith(metadata: const {'has_pending_permission_request': true});
    client.initialSessions
      ..clear()
      ..add(pendingSession);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.hasPendingSuspension(agent.id, pendingSession.id), isFalse);

    await cubit.close();
  });

  test('does not infer runtime recovery state from session metadata', () async {
    socket.setConnected(true);
    final blockedSession = session.copyWith(
      metadata: const {
        'has_runtime_recovery_notice': true,
        'runtime_recovery_status': 'blocked',
      },
    );
    client.initialSessions
      ..clear()
      ..add(blockedSession);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.hasPendingSuspension(agent.id, blockedSession.id), isFalse);

    await cubit.close();
  });

  test('SessionSidebarCubit tracks active device from cache repository', () async {
    final secondAgent = DeviceConfig(id: 'agent-2', name: 'Computer');
    final store = ConversationCacheStore();
    final cacheRepository = ConversationCacheRepository(
      cache: store,
      transport: conversationRepository,
    );

    final cubit = SessionSidebarCubit(cacheRepository: cacheRepository);

    // No device selected initially.
    expect(cubit.state.activeDeviceId, isNull);

    // Selecting a device updates the sidebar state.
    cacheRepository.selectDevice(agent.id);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.activeDeviceId, agent.id);

    // Switching device updates the active device.
    cacheRepository.selectDevice(secondAgent.id);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.activeDeviceId, secondAgent.id);

    await cubit.close();
  });

  test('reloads sessions when an agent status changes to online', () async {
    socket.setConnected(true);
    final offlineAgent = agent.copyWith(isOnline: false);
    final onlineAgent = agent.copyWith(isOnline: true);

    agentCubit.emitState(DeviceActive(activeAgent: offlineAgent, agents: [offlineAgent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(client.getSessionsCalls, 0);

    agentCubit.emitState(DeviceActive(activeAgent: onlineAgent, agents: [onlineAgent]));
    await Future<void>.delayed(Duration.zero);

    expect(client.getSessionsCalls, 1);

    await cubit.close();
  });

  test('local cache does not refresh through stale cloud-online state while local transport is down', () async {
    socket.setConnected(true);
    final localAgent = DeviceConfig(
      id: DeviceInventoryIds.localDevice,
      name: 'Sanad Agent (Macos)',
      isOnline: true,
      metadata: const {'is_local_reachable': false},
    );
    final localClient = _FakeDeviceClient(
      config: localAgent,
      controller: socket,
      initialSessions: [session.copyWith(deviceId: localAgent.id)],
    );
    agentCubit.registerClient(localAgent.id, localClient);
    agentCubit.emitState(DeviceActive(activeAgent: localAgent, agents: [localAgent]));
    final store = ConversationCacheStore()..setActiveDevice(localAgent.id);
    store.applySessionCreated(localAgent.id, session.copyWith(deviceId: localAgent.id));
    final cacheRepository = ConversationCacheRepository(
      cache: store,
      transport: conversationRepository,
    );

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);

    expect(localClient.getSessionsCalls, 0);
    expect(cacheRepository.sessionsForDevice(localAgent.id), hasLength(1));

    await cubit.close();
    store.dispose();
  });

  test('selectSession defers activation to atomic history loading', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    await cubit.selectSession(session);

    expect(cubit.state.selectedSession, session);
    expect(client.activatedSessionId, isNull);
    expect(client.loadedHistorySessionIds, isEmpty);

    await cubit.close();
  });

  test('adoptForkedSession adds the child and selects it', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);
    await cubit.selectSession(session);

    final child = Session(
      id: 'child-1',
      title: '(1) Test Session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 8, 30),
      updatedAt: DateTime(2026, 8, 30),
    );
    await cubit.adoptForkedSession(child);

    expect(cubit.state.selectedSession?.id, 'child-1');
    expect(
      cubit.state.agentSessions[agent.id]?.map((item) => item.id),
      containsAll([session.id, 'child-1']),
    );
    expect(
      cubit.state.agentSessions[agent.id]?.first.id,
      'child-1',
      reason: 'the adopted fork must appear at the top of the sidebar',
    );

    await cubit.close();
  });

  test('authoritative attention stream toggles sidebar pending state', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    client.emitAttention({
      session.id: SessionAttentionState(
        sessionId: session.id,
        executionSnapshot: SessionExecutionSnapshot.virtualIdle(session.id),
        runtimeNotice: null,
        pendingSuspendedRequest: DeviceSuspendedRequest.fromJson({
          'request_id': 'permission-1',
          'session_id': session.id,
          'tool_name': 'shell_execute',
        }),
      ),
    });
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.hasPendingSuspension(agent.id, session.id), isTrue);

    client.emitAttention({
      session.id: SessionAttentionState(
        sessionId: session.id,
        executionSnapshot: SessionExecutionSnapshot.virtualIdle(session.id),
        runtimeNotice: null,
        pendingSuspendedRequest: null,
      ),
    });
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.hasPendingSuspension(agent.id, session.id), isFalse);

    await cubit.close();
  });

  test('SessionMessagesCubit loads history for the selected session', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, session.id);
    expect(client.loadedHistorySessionIds, [session.id]);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('SessionMessagesCubit coalesces older loads and preserves history on failure', () async {
    socket.setConnected(true);
    client.historyHasMoreValue = true;
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);
    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);
    expect(messagesCubit.state.hasOlderHistory, isTrue);

    final completer = Completer<List<CanonicalEvent>>();
    client.olderHistoryCompleter = completer;
    final first = messagesCubit.loadOlderHistory();
    final second = messagesCubit.loadOlderHistory();
    expect(client.loadedOlderHistorySessionIds, [session.id]);
    completer.complete(const []);
    await Future.wait([first, second]);

    final retainedMessages = messagesCubit.state.messages;
    client.olderHistoryCompleter = null;
    client.olderHistoryError = StateError('network');
    await messagesCubit.loadOlderHistory();

    expect(messagesCubit.state.messages, retainedMessages);
    expect(messagesCubit.state.olderHistoryError, isNotNull);
    expect(messagesCubit.state.hasOlderHistory, isTrue);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('replay result projects the authoritative history revision', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);
    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);

    client.replayResult = const TurnReplayResult(
      outcome: 'accepted',
      safety: TurnReplaySafety.safe,
      requiresConfirmation: false,
      historyRevision: 5,
    );
    final accepted = await messagesCubit.replayTurn(
      targetRequestId: 'request-1',
      targetMessageId: 'message-1',
      targetTurnId: 'turn-1',
      action: TurnReplayAction.retry,
    );
    expect(accepted.isAccepted, isTrue);
    expect(sessionCubit.state.selectedSession?.historyRevision, 5);

    client.replayResult = const TurnReplayResult(
      outcome: 'stale_turn_boundary',
      safety: TurnReplaySafety.safe,
      requiresConfirmation: false,
      historyRevision: 9,
    );
    final rejected = await messagesCubit.replayTurn(
      targetRequestId: 'request-2',
      targetMessageId: 'message-2',
      targetTurnId: 'turn-2',
      action: TurnReplayAction.retry,
    );
    expect(rejected.isAccepted, isFalse);
    expect(sessionCubit.state.selectedSession?.historyRevision, 9);
    expect(
      sessionCubit.state.agentSessions.values
          .expand((sessions) => sessions)
          .firstWhere((candidate) => candidate.id == session.id)
          .historyRevision,
      9,
    );

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test(
    'live runtime notice updates active presentation and sidebar without leaking from background sessions',
    () async {
      final background = Session(
        id: 'session-2',
        title: 'Background',
        deviceId: agent.id,
        createdAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 2),
      );
      client.initialSessions.add(background);
      socket.setConnected(true);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      final sessionCubit = SessionCubit(
        agentCubit: agentCubit,
        socketService: socket,
        conversationRepository: conversationRepository,
      );
      final messagesCubit = SessionMessagesCubit(
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        conversationRepository: conversationRepository,
        preferencesRepository: FakeDevicePreferencesRepository(),
      );
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session);
      await Future<void>.delayed(Duration.zero);

      const activeNotice = RuntimeNotice(
        sessionId: 'session-1',
        requestId: 'notice-1',
        status: 'blocked',
        reason: 'provider_error',
        title: 'Active recovery',
        actions: ['retry'],
      );
      const backgroundNotice = RuntimeNotice(
        sessionId: 'session-2',
        requestId: 'notice-2',
        status: 'blocked',
        reason: 'provider_error',
        title: 'Background recovery',
        actions: ['retry'],
      );
      client.emitAttention({
        session.id: SessionAttentionState(
          sessionId: session.id,
          executionSnapshot: SessionExecutionSnapshot.virtualIdle(session.id),
          runtimeNotice: activeNotice,
          pendingSuspendedRequest: null,
        ),
        background.id: SessionAttentionState(
          sessionId: background.id,
          executionSnapshot: SessionExecutionSnapshot.virtualIdle(background.id),
          runtimeNotice: backgroundNotice,
          pendingSuspendedRequest: null,
        ),
      });
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.runtimeNotice, activeNotice);
      expect(
        sessionCubit.state.attentionStateFor(agent.id, background.id)?.runtimeNotice,
        backgroundNotice,
      );

      client.emitAttention({
        session.id: SessionAttentionState(
          sessionId: session.id,
          executionSnapshot: SessionExecutionSnapshot.virtualIdle(session.id),
          runtimeNotice: null,
          pendingSuspendedRequest: null,
        ),
        background.id: SessionAttentionState(
          sessionId: background.id,
          executionSnapshot: SessionExecutionSnapshot.virtualIdle(background.id),
          runtimeNotice: backgroundNotice,
          pendingSuspendedRequest: null,
        ),
      });
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.runtimeNotice, isNull);
      expect(messagesCubit.state.activeSessionId, session.id);

      await messagesCubit.close();
      await sessionCubit.close();
    },
  );

  test('live attention cannot bypass an atomic history swap', () async {
    final sessionB = Session(
      id: 'session-b',
      title: 'B',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );
    client.initialSessions.add(sessionB);
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);
    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);
    expect(messagesCubit.state.activeSessionId, session.id);

    final delayedClient = _FakeDelayedClient(
      config: agent,
      controller: socket,
      initialSessions: [session, sessionB],
      historyDelay: Duration.zero,
    );
    agentCubit.registerClient(agent.id, delayedClient);
    await sessionCubit.selectSession(sessionB);
    expect(messagesCubit.state.requestedSessionId, sessionB.id);

    const noticeA = RuntimeNotice(
      sessionId: 'session-1',
      requestId: 'notice-a',
      status: 'blocked',
      reason: 'provider_error',
      title: 'A notice',
      actions: ['retry'],
    );
    const noticeB = RuntimeNotice(
      sessionId: 'session-b',
      requestId: 'notice-b',
      status: 'blocked',
      reason: 'provider_error',
      title: 'B notice',
      actions: ['retry'],
    );
    delayedClient.emitAttention({
      session.id: SessionAttentionState(
        sessionId: session.id,
        executionSnapshot: SessionExecutionSnapshot.virtualIdle(session.id),
        runtimeNotice: noticeA,
        pendingSuspendedRequest: null,
      ),
      sessionB.id: SessionAttentionState(
        sessionId: sessionB.id,
        executionSnapshot: SessionExecutionSnapshot.virtualIdle(sessionB.id),
        runtimeNotice: noticeB,
        pendingSuspendedRequest: null,
      ),
    });
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, session.id);
    expect(messagesCubit.state.runtimeNotice, isNull);

    delayedClient.completeHistory();
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, sessionB.id);
    expect(messagesCubit.state.requestedSessionId, isNull);
    expect(messagesCubit.state.runtimeNotice, noticeB);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('switching sessions replaces route and thinking context instead of leaking prior values', () async {
    final richSession = Session(
      id: 'session-rich',
      title: 'Rich context',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
      modelProvider: 'provider-rich',
      model: 'model-rich',
      thinkingMode: 'deep',
    );
    final emptySession = Session(
      id: 'session-empty',
      title: 'Empty context',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 3),
      updatedAt: DateTime(2026, 1, 3),
    );
    final contextClient = _FakeDeviceClient(
      config: agent,
      controller: socket,
      initialSessions: [richSession, emptySession],
    );
    agentCubit.registerClient(agent.id, contextClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    await sessionCubit.selectSession(richSession);
    await Future<void>.delayed(Duration.zero);
    expect(messagesCubit.state.nextMessageProviderId, 'provider-rich');
    expect(messagesCubit.state.nextMessageModel, 'model-rich');
    expect(messagesCubit.state.nextMessageThinkingMode, 'deep');

    await sessionCubit.selectSession(emptySession);
    await Future<void>.delayed(Duration.zero);
    expect(messagesCubit.state.nextMessageProviderId, isNull);
    expect(messagesCubit.state.nextMessageModel, isNull);
    expect(messagesCubit.state.nextMessageThinkingMode, isNull);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('normalizes bridge sessions before selection and history load', () async {
    final computerAgent = DeviceConfig(id: 'agent-computer', name: 'Computer', isOnline: true);
    final computerSession = Session(
      id: 'session-1',
      title: 'Computer session',
      createdAt: DateTime(2026, 1, 3),
      updatedAt: DateTime(2026, 1, 3),
    );
    final computerClient = _FakeDeviceClient(
      config: computerAgent,
      controller: socket,
      initialSessions: [computerSession],
    );

    socket.setConnected(true);
    agentCubit.registerClient(computerAgent.id, computerClient);
    repository.seedAgents([agent, computerAgent], activeAgentId: computerAgent.id);
    agentCubit.emitState(DeviceActive(activeAgent: computerAgent, agents: [agent, computerAgent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    final normalizedSession = sessionCubit.state.agentSessions[computerAgent.id]!.single;
    expect(normalizedSession.deviceId, computerAgent.id);

    await sessionCubit.selectSession(normalizedSession);
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, computerSession.id);
    expect(computerClient.loadedHistorySessionIds, [computerSession.id]);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  // ── Gate E2: Atomic Session Presentation ──

  test('E2: atomic session switch sets requestedSessionId and clears it after history loads', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, isNull);
    expect(messagesCubit.state.requestedSessionId, isNull);
    expect(messagesCubit.state.isHistoryLoading, isFalse);

    await sessionCubit.selectSession(session);

    // After selectSession, microtask queue has: session state listener →
    // _handleSessionStateChange → emit with requestedSessionId →
    // _loadHistoryForAtomicSwap → microtask continuation → atomic swap
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, session.id);
    expect(messagesCubit.state.requestedSessionId, isNull);
    expect(messagesCubit.state.isHistoryLoading, isFalse);
    expect(client.loadedHistorySessionIds, contains(session.id));

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E2: failure during history load keeps presented session and sets error', () async {
    final failingClient = _FakeFailingClient(
      config: agent,
      controller: socket,
      initialSessions: [session],
    );
    agentCubit.registerClient(agent.id, failingClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    // Select the session (fake will throw during loadSessionHistory)
    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);

    // Presented session should remain, error should be set
    expect(messagesCubit.state.activeSessionId, isNull);
    expect(messagesCubit.state.historyLoadError, isNotNull);
    expect(messagesCubit.state.isHistoryLoading, isFalse);
    expect(messagesCubit.state.requestedSessionId, session.id);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E2: failed history load can retry without replacing presentation', () async {
    final retryingClient = _FakeFailOnceClient(
      config: agent,
      controller: socket,
      initialSessions: [session],
    );
    agentCubit.registerClient(agent.id, retryingClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);
    expect(messagesCubit.state.historyLoadError, isNotNull);
    expect(messagesCubit.state.activeSessionId, isNull);

    messagesCubit.retryHistoryLoad();
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.historyLoadError, isNull);
    expect(messagesCubit.state.requestedSessionId, isNull);
    expect(messagesCubit.state.activeSessionId, session.id);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E2: rapid session switching A→B→C shows only C', () async {
    final sessionA = Session(
      id: 'session-a',
      title: 'A',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final sessionB = Session(
      id: 'session-b',
      title: 'B',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );
    final sessionC = Session(
      id: 'session-c',
      title: 'C',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 3),
      updatedAt: DateTime(2026, 1, 3),
    );

    final clientA = _FakeDeviceClient(
      config: agent,
      controller: socket,
      initialSessions: [sessionA, sessionB, sessionC],
    );
    agentCubit.registerClient(agent.id, clientA);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    // Rapidly switch A→B→C
    await sessionCubit.selectSession(sessionA);
    await sessionCubit.selectSession(sessionB);
    await sessionCubit.selectSession(sessionC);
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, sessionC.id);
    expect(messagesCubit.state.requestedSessionId, isNull);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E2: generation token rejects stale history responses from superseded requests', () async {
    final sessionA = Session(
      id: 'session-a',
      title: 'A',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final sessionB = Session(
      id: 'session-b',
      title: 'B',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );

    final controlledClient = _FakeControlledClient(
      config: agent,
      controller: socket,
      initialSessions: [sessionA, sessionB],
    );
    agentCubit.registerClient(agent.id, controlledClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    // Start selecting session A (won't complete until we resolve the completer)
    unawaited(sessionCubit.selectSession(sessionA));
    // Before history loads for A, switch to B
    await sessionCubit.selectSession(sessionB);
    // Now allow A's history to complete (should be discarded by generation check)
    controlledClient.completeHistory();
    await Future<void>.delayed(Duration.zero);

    // A's stale response must not have set activeSessionId to A
    expect(messagesCubit.state.activeSessionId, sessionB.id);
    expect(messagesCubit.state.requestedSessionId, isNull);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E2: delayed loading indicator shown after threshold', () async {
    final delayedClient = _FakeDelayedClient(
      config: agent,
      controller: socket,
      initialSessions: [session],
      historyDelay: Duration.zero,
    );
    agentCubit.registerClient(agent.id, delayedClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    await sessionCubit.selectSession(session);

    // Before the 300ms threshold, no delayed loading indicator
    expect(messagesCubit.state.isHistoryLoading, isTrue);
    expect(messagesCubit.state.showDelayedLoading, isFalse);

    // Wait past the 300ms threshold
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(messagesCubit.state.showDelayedLoading, isTrue);

    // Complete the history fetch
    delayedClient.completeHistory();
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.showDelayedLoading, isFalse);
    expect(messagesCubit.state.isHistoryLoading, isFalse);
    expect(messagesCubit.state.activeSessionId, session.id);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E3: late history cannot resurrect a session after New Conversation', () async {
    final delayedClient = _FakeDelayedClient(
      config: agent,
      controller: socket,
      initialSessions: [session],
      historyDelay: Duration.zero,
    );
    agentCubit.registerClient(agent.id, delayedClient);

    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    await sessionCubit.selectSession(session);
    expect(messagesCubit.state.requestedSessionId, session.id);

    await sessionCubit.startNewChat(agent);
    delayedClient.completeHistory();
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, isNull);
    expect(messagesCubit.state.requestedSessionId, isNull);
    expect(messagesCubit.state.visualState.isNewConversation, isTrue);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('E3: deleting retained presentation does not cancel newer requested session', () async {
    final sessionB = Session(
      id: 'session-b',
      title: 'B',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );
    client.initialSessions.add(sessionB);
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);
    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);
    expect(messagesCubit.state.activeSessionId, session.id);

    final delayedClient = _FakeDelayedClient(
      config: agent,
      controller: socket,
      initialSessions: [session, sessionB],
      historyDelay: Duration.zero,
    );
    agentCubit.registerClient(agent.id, delayedClient);
    await sessionCubit.selectSession(sessionB);
    expect(messagesCubit.state.requestedSessionId, sessionB.id);

    messagesCubit.invalidateDeletedSession(agent.id, session.id);
    delayedClient.completeHistory();
    await Future<void>.delayed(Duration.zero);

    expect(messagesCubit.state.activeSessionId, sessionB.id);
    expect(messagesCubit.state.requestedSessionId, isNull);

    await messagesCubit.close();
    await sessionCubit.close();
  });

  test('client sessionCreated stream inserts new sessions without duplicates', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    final newSession = Session(
      id: 'session-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );

    client.emitSessionCreated(newSession);
    client.emitSessionCreated(newSession);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.agentSessions[agent.id]?.map((t) => t.id), ['session-2', 'session-1']);

    await cubit.close();
  });

  test('processing state follows ProcessingStore snapshots from the repository', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    client.emitProcessing(DeviceProcessingSnapshot(sessionIds: {session.id}));
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.processingSessionIds, {
      agent.id: {session.id},
    });

    client.emitProcessing(const DeviceProcessingSnapshot());
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.processingSessionIds, isEmpty);

    await cubit.close();
  });

  test('switching session keeps processing scoped by agent and session id', () async {
    final secondSession = Session(
      id: 'session-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );
    client.initialSessions.add(secondSession);
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    client.emitProcessing(DeviceProcessingSnapshot(sessionIds: {session.id}));
    await Future<void>.delayed(Duration.zero);
    await cubit.selectSession(secondSession);

    expect(cubit.state.selectedSession?.id, secondSession.id);
    expect(cubit.state.isSessionProcessing(agent.id, session.id), isTrue);
    expect(cubit.state.isSessionProcessing(agent.id, secondSession.id), isFalse);

    await cubit.close();
  });

  test('deleteSession delegates to client and refreshes the agent sessions', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    client.initialSessions.removeWhere((item) => item.id == session.id);
    await cubit.deleteSession(agent: agent, session: session);

    expect(client.deletedSessionIds, [session.id]);
    expect(cubit.state.agentSessions[agent.id], isEmpty);

    await cubit.close();
  });

  test('deleteSession clears selectedSession if it is the one being deleted', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    await Future<void>.delayed(Duration.zero);

    await cubit.selectSession(session);
    expect(cubit.state.selectedSession, session);

    client.initialSessions.removeWhere((item) => item.id == session.id);
    await cubit.deleteSession(agent: agent, session: session);

    expect(cubit.state.selectedSession, isNull);
    expect(client.deletedSessionIds, [session.id]);

    await cubit.close();
  });

  test('session_updated from the local socket updates the visible session title', () async {
    socket.setConnected(true);
    localSocket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final resolver = DeviceConnectionCoordinator(
      cloudSocketService: socket,
      localSocketService: localSocket,
      currentDeviceId: 'test-device-id',
    );
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      connectionCoordinator: resolver,
    );
    await Future<void>.delayed(Duration.zero);

    localSocket.debugEmitEvent({
      'type': 'device_event',
      'event': 'session_updated',
      'device_id': agent.id,
      'payload': {
        'session_id': session.id,
        'title': 'Renamed locally',
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.agentSessions[agent.id]?.single.title, 'Renamed locally');

    resolver.dispose();
    await cubit.close();
  });

  test('startNewChat for another agent clears that agent previous visible messages', () async {
    final secondAgent = DeviceConfig(id: 'agent-2', name: 'Computer');
    final oldMessage = CanonicalEvent(
      id: 'old-final',
      kind: EventKind.finalAnswer,
      text: 'old conversation',
      timestamp: DateTime(2026, 1, 4),
    );
    final secondClient = _FakeDeviceClient(
      config: secondAgent,
      controller: socket,
      initialSessions: const [],
      initialMessages: [oldMessage],
    );

    socket.setConnected(true);
    agentCubit.registerClient(secondAgent.id, secondClient);
    repository.seedAgents([agent, secondAgent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent, secondAgent]));
    final sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    final messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    await Future<void>.delayed(Duration.zero);

    await sessionCubit.startNewChat(secondAgent);
    await Future<void>.delayed(Duration.zero);

    expect(sessionCubit.state.selectedSession, isNull);
    expect(secondClient.beginNewSessionCalls, 1);
    expect(messagesCubit.state.messages, isEmpty);
    expect(messagesCubit.state.activeSessionId, isNull);

    await messagesCubit.close();
    await sessionCubit.close();
    secondClient.dispose();
  });

  test('resetForLogout clears cached agents and active agent selection', () async {
    repository.seedAgents([agent], activeAgentId: agent.id);

    await agentCubit.resetForLogout();

    expect(repository.agents, isEmpty);
    expect(repository.getActiveAgent(), isNull);
    expect(agentCubit.state, isA<DeviceNoActive>());
  });

  test('resetForLogout retains local clients that remain in the post-logout inventory', () async {
    final localAgent = DeviceConfig(
      id: 'local-agent',
      name: 'This device',
      hardwareId: 'device-1',
      isOnline: true,
    );
    final localClient = _FakeDeviceClient(
      config: localAgent,
      controller: socket,
      initialSessions: const [],
    );
    repository.seedAgents([localAgent], activeAgentId: localAgent.id);
    repository.postClearAgents = [localAgent];
    agentCubit.registerClient(localAgent.id, localClient);

    await agentCubit.resetForLogout();

    expect(repository.agents, [localAgent]);
    expect(agentCubit.state, isA<DeviceActive>());
    expect((agentCubit.state as DeviceActive).activeAgent.id, localAgent.id);
    expect((agentCubit.agentClientRegistry as _FakeDeviceClientRegistry).contains(localAgent.id), isTrue);
  });

  test('E3: current session deletion with back stack fallback selects previous session', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final session2 = Session(
      id: 'session-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );

    final historyCtrl = ConversationHistoryController();
    historyCtrl.setInitial(
      ConversationDestination.session(deviceId: agent.id, sessionId: session.id),
    );
    historyCtrl.navigateTo(
      ConversationDestination.session(deviceId: agent.id, sessionId: session2.id),
    );

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      historyController: historyCtrl,
    );
    await Future<void>.delayed(Duration.zero);

    await cubit.selectSession(session2);
    expect(cubit.state.selectedSession?.id, 'session-2');

    client.initialSessions.removeWhere((item) => item.id == session2.id);
    await cubit.deleteSession(agent: agent, session: session2);

    expect(cubit.state.selectedSession?.id, session.id);
    expect(historyCtrl.snapshot.current?.sessionId, session.id);

    await cubit.close();
  });

  test('E3: session_deleted event with current session fallback to New Conversation', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final historyCtrl = ConversationHistoryController();
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      historyController: historyCtrl,
    );
    await Future<void>.delayed(Duration.zero);

    await cubit.selectSession(session);
    expect(cubit.state.selectedSession, session);

    socket.debugEmitEvent({
      'type': 'device_event',
      'event': 'session_deleted',
      'device_id': agent.id,
      'payload': {'session_id': session.id},
    });
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.selectedSession, isNull);
    expect(historyCtrl.snapshot.current?.isNewConversation, isTrue);
    expect(historyCtrl.snapshot.current?.deviceId, agent.id);

    await cubit.close();
  });

  test('E3: non-current session deletion does not affect selectedSession', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final session2 = Session(
      id: 'session-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );
    client.initialSessions
      ..clear()
      ..addAll([session, session2]);

    final historyCtrl = ConversationHistoryController();
    historyCtrl.setInitial(
      ConversationDestination.session(deviceId: agent.id, sessionId: session.id),
    );
    historyCtrl.navigateTo(
      ConversationDestination.session(deviceId: agent.id, sessionId: session2.id),
    );

    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      historyController: historyCtrl,
    );
    await Future<void>.delayed(Duration.zero);

    await cubit.selectSession(session2);
    expect(cubit.state.selectedSession?.id, 'session-2');

    client.initialSessions.removeWhere((item) => item.id == session.id);
    await cubit.deleteSession(agent: agent, session: session);

    // selectedSession should remain session-2 (non-current deletion)
    expect(cubit.state.selectedSession?.id, 'session-2');
    expect(historyCtrl.snapshot.current?.sessionId, 'session-2');

    await cubit.close();
  });

  test('E4: selectSession syncs with history controller', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final session2 = Session(
      id: 'session-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );

    final historyCtrl = ConversationHistoryController();
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      historyController: historyCtrl,
    );
    await Future<void>.delayed(Duration.zero);

    // First selection sets initial
    await cubit.selectSession(session);
    expect(historyCtrl.snapshot.current?.sessionId, session.id);
    expect(historyCtrl.snapshot.backStack, isEmpty);

    // Second selection pushes first to back
    await cubit.selectSession(session2);
    expect(historyCtrl.snapshot.current?.sessionId, session2.id);
    expect(historyCtrl.snapshot.backStack.length, 1);
    expect(historyCtrl.snapshot.backStack.last.sessionId, session.id);

    await cubit.close();
  });

  test('startNewChat restores the last selected session context per device', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final contextualSession = session.copyWith(
      workspaceId: 'workspace-a',
      modelProvider: 'provider-a',
      model: 'model-a',
      thinkingMode: 'deep',
    );
    final cacheStore = ConversationCacheStore();
    cacheStore.applyWorkspacesRefreshed(
      agent.id,
      const [DeviceWorkspace(id: 'workspace-a', name: 'A', path: '/a')],
      generation: cacheStore.advanceWorkspacesGeneration(agent.id),
    );
    cacheStore.applySessionCreated(agent.id, contextualSession);
    cacheStore.recordLastDestination(
      ConversationDestination.session(
        deviceId: agent.id,
        sessionId: contextualSession.id,
      ),
    );
    cacheStore.setNewConversationDraft(
      agent.id,
      text: 'keep my draft',
      permissionMode: 'fullAccess',
    );
    final cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);
    cacheStore.applyWorkspacesRefreshed(
      agent.id,
      const [DeviceWorkspace(id: 'workspace-a', name: 'A', path: '/a')],
      generation: cacheStore.advanceWorkspacesGeneration(agent.id),
    );
    cacheStore.applySessionCreated(agent.id, contextualSession);
    cacheStore.recordLastDestination(
      ConversationDestination.session(
        deviceId: agent.id,
        sessionId: contextualSession.id,
      ),
    );
    await cubit.selectSession(contextualSession);

    await cubit.startNewChat(agent);
    await Future<void>.delayed(Duration.zero);

    final draft = cacheRepository.newConversationDraft(agent.id);
    expect(draft.text, 'keep my draft');
    expect(draft.workspaceId, 'workspace-a');
    expect(draft.providerId, 'provider-a');
    expect(draft.model, 'model-a');
    expect(draft.thinkingMode, 'deep');
    expect(draft.permissionMode, isNull);
    expect(cacheRepository.snapshot.contexts[agent.id]?.lastSelectedSessionId, contextualSession.id);
    expect(
      cacheRepository.lastDestination(agent.id),
      ConversationDestination.newConversation(
        deviceId: agent.id,
        workspaceId: 'workspace-a',
      ),
    );
    expect(cubit.state.selectedSession, isNull);
    expect(client.beginNewSessionCalls, 1);

    // Applying the canonical route after the UI intent must not initialize the
    // same new-conversation presentation a second time.
    await cubit.startNewChat(agent, workspaceId: 'workspace-a');
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.selectedSession, isNull);
    expect(client.beginNewSessionCalls, 1);

    await cubit.close();
  });

  test('workspace New Session overrides only workspace and clears inherited permission', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    final contextualSession = session.copyWith(
      workspaceId: 'workspace-a',
      modelProvider: 'provider-a',
      model: 'model-a',
      thinkingMode: 'deep',
    );
    final cacheStore = ConversationCacheStore();
    cacheStore.applyWorkspacesRefreshed(
      agent.id,
      const [DeviceWorkspace(id: 'workspace-a', name: 'A', path: '/a')],
      generation: cacheStore.advanceWorkspacesGeneration(agent.id),
    );
    cacheStore.applySessionCreated(agent.id, contextualSession);
    cacheStore.recordLastDestination(
      ConversationDestination.session(
        deviceId: agent.id,
        sessionId: contextualSession.id,
      ),
    );
    cacheStore.setNewConversationDraft(agent.id, permissionMode: 'fullAccess');
    final cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);
    cacheStore.applyWorkspacesRefreshed(
      agent.id,
      const [DeviceWorkspace(id: 'workspace-a', name: 'A', path: '/a')],
      generation: cacheStore.advanceWorkspacesGeneration(agent.id),
    );
    cacheStore.applySessionCreated(agent.id, contextualSession);
    cacheStore.recordLastDestination(
      ConversationDestination.session(
        deviceId: agent.id,
        sessionId: contextualSession.id,
      ),
    );
    await cubit.selectSession(contextualSession);

    await cubit.startNewChat(agent, workspaceId: 'workspace-b');

    final draft = cacheRepository.newConversationDraft(agent.id);
    expect(draft.workspaceId, 'workspace-b');
    expect(draft.providerId, 'provider-a');
    expect(draft.model, 'model-a');
    expect(draft.thinkingMode, 'deep');
    expect(draft.permissionMode, isNull);
    expect(
      cacheRepository.lastDestination(agent.id),
      ConversationDestination.newConversation(
        deviceId: agent.id,
        workspaceId: 'workspace-b',
      ),
    );

    await cubit.close();
  });

  test('E4: startNewChat syncs with history controller', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final historyCtrl = ConversationHistoryController();
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      historyController: historyCtrl,
    );
    await Future<void>.delayed(Duration.zero);

    // Select a session first
    await cubit.selectSession(session);
    expect(historyCtrl.snapshot.current?.sessionId, session.id);

    // Start new chat pushes to history
    await cubit.startNewChat(agent);
    expect(historyCtrl.snapshot.current?.isNewConversation, isTrue);
    expect(historyCtrl.snapshot.current?.deviceId, agent.id);
    expect(historyCtrl.snapshot.backStack.length, 1);
    expect(historyCtrl.snapshot.backStack.last.sessionId, session.id);

    await cubit.close();
  });

  test('E4: restart recovery: cache persists last selected session for HomeScreen restore', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final cacheStore = ConversationCacheStore();
    final cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );

    // Simulate last selected session being persisted
    cacheStore.recordLastDestination(
      ConversationDestination.session(
        deviceId: agent.id,
        sessionId: session.id,
      ),
    );

    final historyCtrl = ConversationHistoryController();
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      historyController: historyCtrl,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Cache has the last selected session id; the session is loaded
    expect(cubit.state.agentSessions[agent.id]?.any((s) => s.id == session.id), isTrue);

    // Simulate HomeScreen restoring the session after restart
    final restoredSession = Session(
      id: session.id,
      title: 'Loading...',
      deviceId: agent.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await cubit.selectSession(restoredSession);
    expect(cubit.state.selectedSession?.id, session.id);
    expect(historyCtrl.snapshot.current?.sessionId, session.id);

    await cubit.close();
    cacheStore.dispose();
  });

  test('restart recovery keeps New Conversation selected with or without workspace', () async {
    socket.setConnected(true);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final destinations = [
      ConversationDestination.newConversation(deviceId: agent.id),
      ConversationDestination.newConversation(
        deviceId: agent.id,
        workspaceId: 'workspace-1',
      ),
    ];

    for (final destination in destinations) {
      final cacheStore = ConversationCacheStore();
      cacheStore.applySessionCreated(agent.id, session);
      cacheStore.recordLastDestination(
        ConversationDestination.session(
          deviceId: agent.id,
          sessionId: session.id,
        ),
      );
      cacheStore.recordLastDestination(destination);
      final cacheRepository = ConversationCacheRepository(
        cache: cacheStore,
        transport: conversationRepository,
      );
      final cubit = SessionCubit(
        agentCubit: agentCubit,
        socketService: socket,
        conversationRepository: conversationRepository,
        conversationCacheRepository: cacheRepository,
      );

      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.selectedSession, isNull);
      expect(cacheRepository.lastDestination(agent.id), destination);
      expect(
        cacheRepository.snapshot.contexts[agent.id]?.lastSelectedSessionId,
        session.id,
      );

      await cubit.close();
      cacheStore.dispose();
    }
  });

  test('switching devices restores the new device last selected session in the sidebar', () async {
    socket.setConnected(true);

    // Two devices, each with its own session.
    final deviceA = agent;
    final deviceB = DeviceConfig(
      id: 'device-b',
      name: 'Device B',
      isOnline: true,
    );
    final sessionA = session; // belongs to deviceA
    final sessionB = Session(
      id: 'session-b',
      title: 'Session B',
      deviceId: deviceB.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final cacheStore = ConversationCacheStore();
    cacheStore.applySessionCreated(deviceA.id, sessionA);
    cacheStore.applySessionCreated(deviceB.id, sessionB);
    // Both devices were previously viewing their own session.
    cacheStore.recordLastDestination(
      ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id),
    );
    cacheStore.recordLastDestination(
      ConversationDestination.session(deviceId: deviceB.id, sessionId: sessionB.id),
    );
    final cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );

    // Start active on device A with session A selected.
    agentCubit.emitState(DeviceActive(activeAgent: deviceA, agents: [deviceA, deviceB]));
    final cubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.selectedSession?.id, sessionA.id);
    expect(cubit.state.selectedSession?.deviceId, deviceA.id);

    // Switch the active device to B (cache active device follows).
    cacheRepository.selectDevice(deviceB.id);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // The selection must move to device B's own last session, not stay on A's.
    expect(cubit.state.selectedSession?.deviceId, deviceB.id);
    expect(cubit.state.selectedSession?.id, sessionB.id);

    await cubit.close();
    cacheStore.dispose();
  });
}

class _TestDeviceCubit extends DeviceCubit {
  _TestDeviceCubit({
    required super.socketService,
    required super.agentRepository,
    required super.agentClientRegistry,
  });

  void registerClient(String deviceId, DeviceClient client) {
    (agentClientRegistry as _FakeDeviceClientRegistry).registerClient(deviceId, client);
  }

  void emitState(DeviceState state) {
    emit(state);
  }
}

class _FakeDeviceClientRegistry implements IDeviceClientRegistry, ConversationClientRegistry {
  final Map<String, DeviceClient> _clientsByAgentId = {};

  void registerClient(String deviceId, DeviceClient client) {
    _clientsByAgentId[deviceId] = client;
  }

  bool contains(String deviceId) => _clientsByAgentId.containsKey(deviceId);

  @override
  DeviceClient getOrCreateClientForAgent(DeviceConfig config) {
    return _clientsByAgentId[config.id]!;
  }

  @override
  ConversationClient getOrCreateConversationClientForAgent(DeviceConfig config) {
    return getOrCreateClientForAgent(config) as ConversationClient;
  }

  @override
  void retainClientsFor(List<DeviceConfig> agents) {
    final liveAgentIds = agents.map((agent) => agent.id).toSet();
    _clientsByAgentId.removeWhere((id, _) => !liveAgentIds.contains(id));
  }

  @override
  void clear() {
    _clientsByAgentId.clear();
  }

  @override
  void dispose() {
    clear();
  }
}

class _FakeDeviceRepository implements IDeviceRepository {
  final _agentsController = StreamController<List<DeviceConfig>>.broadcast();
  List<DeviceConfig> _agents = [];
  String? _activeAgentId;
  List<DeviceConfig>? postClearAgents;

  void seedAgents(List<DeviceConfig> agents, {String? activeAgentId}) {
    _agents = agents;
    _activeAgentId = activeAgentId;
  }

  @override
  List<DeviceConfig> get agents => _agents;

  @override
  Stream<List<DeviceConfig>> get onAgentsUpdate => _agentsController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<List<DeviceConfig>> fetchAgents() async {
    _agentsController.add(_agents);
    return _agents;
  }

  @override
  DeviceConfig? getActiveAgent() {
    final activeAgentId = _activeAgentId;
    if (activeAgentId == null) return null;
    return _agents.where((agent) => agent.id == activeAgentId).firstOrNull;
  }

  @override
  String? getActiveAgentId() => _activeAgentId;

  @override
  Future<void> setActiveAgent(String? deviceId) async {
    _activeAgentId = deviceId;
  }

  @override
  void createAgent(String name, {String type = 'computer'}) {}

  @override
  Future<void> renameAgent(DeviceConfig device, String name) async {}

  @override
  void deleteAgent(String deviceId) {}

  @override
  Future<void> clearAgents() async {
    _agents = postClearAgents ?? [];
    _activeAgentId = null;
    _agentsController.add(_agents);
  }

  @override
  void dispose() {
    unawaited(_agentsController.close());
  }
}

class _FakeDeviceClient extends DeviceClient implements ConversationClient {
  @override
  final DeviceConfig config;

  @override
  final SanadSocketService controller;

  final List<Session> initialSessions;
  final List<CanonicalEvent> _currentMessages;
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  final _sessionsController = StreamController<List<Session>>.broadcast();
  final _sessionCreatedController = StreamController<Session>.broadcast();
  final _sessionUpdatedController = StreamController<Session>.broadcast();
  final _sessionDeletedController = StreamController<String>.broadcast();
  final _messagesController = StreamController<List<CanonicalEvent>>.broadcast();
  final _queuedMessagesController = StreamController<List<CanonicalEvent>>.broadcast();
  final _processingController = StreamController<DeviceProcessingSnapshot>.broadcast();
  final _pendingSuspendedController = StreamController<DeviceSuspendedRequest?>.broadcast();
  final _runtimeNoticeController = StreamController<RuntimeNotice?>.broadcast();
  final _attentionController = StreamController<Map<String, SessionAttentionState>>.broadcast();
  Map<String, SessionAttentionState> _currentAttentionStates = const {};

  int getSessionsCalls = 0;
  String? activatedSessionId;
  final List<String> loadedHistorySessionIds = [];
  final List<String> loadedOlderHistorySessionIds = [];
  bool historyHasMoreValue = false;
  String? historyNextCursorValue;
  Completer<List<CanonicalEvent>>? olderHistoryCompleter;
  Object? olderHistoryError;
  final List<String> deletedSessionIds = [];
  int beginNewSessionCalls = 0;
  DeviceProcessingSnapshot _processingSnapshot = const DeviceProcessingSnapshot();
  DeviceSuspendedRequest? _pendingSuspendedRequest;
  TurnReplayResult replayResult = const TurnReplayResult(
    outcome: 'accepted',
    safety: TurnReplaySafety.safe,
    requiresConfirmation: false,
  );

  _FakeDeviceClient({
    required this.config,
    required this.controller,
    required this.initialSessions,
    List<CanonicalEvent> initialMessages = const [],
  }) : _currentMessages = List<CanonicalEvent>.from(initialMessages);

  @override
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  @override
  bool get isConnected => controller.isConnected;

  @override
  void sendCommand({
    required String command,
    Map<String, dynamic>? payload,
  }) {}

  @override
  Future<Map<String, dynamic>?> request({
    required String command,
    required Map<String, dynamic> payload,
    required String requestId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return null;
  }

  @override
  Stream<List<Session>> get sessions => _sessionsController.stream;

  @override
  Stream<Session> get sessionCreated => _sessionCreatedController.stream;

  @override
  Stream<List<CanonicalEvent>> get messages => _messagesController.stream;

  @override
  Stream<List<CanonicalEvent>> get queuedMessages => _queuedMessagesController.stream;

  @override
  Stream<DeviceProcessingSnapshot> get processing => _processingController.stream;

  @override
  Stream<DeviceSuspendedRequest?> get pendingSuspendedRequest => _pendingSuspendedController.stream;

  @override
  Stream<RuntimeNotice?> get runtimeNotice => _runtimeNoticeController.stream;

  @override
  Stream<StopDraftRecovery> get stopRecoveries => const Stream.empty();

  @override
  Stream<Map<String, SessionAttentionState>> get attentionStates => _attentionController.stream;

  @override
  Stream<Map<String, SessionRouteSnapshot>> get routeSnapshots => const Stream.empty();

  @override
  List<CanonicalEvent> get currentMessages => List.unmodifiable(_currentMessages);

  @override
  List<CanonicalEvent> get currentQueuedMessages => const [];

  @override
  bool get isProcessing => _processingSnapshot.isProcessing;

  @override
  bool get isCurrentConversationProcessing => false;

  @override
  DeviceSuspendedRequest? get currentPendingSuspendedRequest => _pendingSuspendedRequest;

  @override
  RuntimeNotice? get currentRuntimeNotice => null;

  @override
  Map<String, SessionAttentionState> get currentAttentionStates => _currentAttentionStates;

  @override
  Map<String, SessionRouteSnapshot> get currentRouteSnapshots => const {};

  void emitAttention(Map<String, SessionAttentionState> attention) {
    _currentAttentionStates = Map.unmodifiable(attention);
    _attentionController.add(_currentAttentionStates);
  }

  @override
  bool isSessionProcessing(String? sessionId) => _processingSnapshot.isSessionProcessing(sessionId);

  @override
  void activateSession(String sessionId) {
    activatedSessionId = sessionId;
  }

  @override
  void beginNewSession() {
    beginNewSessionCalls += 1;
    _currentMessages.clear();
    _messagesController.add(currentMessages);
  }

  @override
  Future<String?> sendMessage(
    String message, {
    String? sessionId,
    String? workspaceId,
    String? context,
    String? providerId,
    String? model,
    String? thinkingMode,
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  }) async => 'test-request';

  @override
  Future<void> steerMessage(
    String message, {
    required String requestId,
    required String sessionId,
  }) async {}

  @override
  Future<String?> deleteQueuedMessage({required String requestId, required String sessionId}) async => null;

  @override
  Future<String?> cancelPendingSteer({required String requestId, required String sessionId}) async => null;

  @override
  Future<String?> stop({
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  }) async => requestId;

  @override
  Future<String?> claimStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  }) async => commandRequestId ?? 'claim-$stopRequestId';

  @override
  Future<void> acknowledgeStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  }) async {}

  @override
  Future<TurnReplayResult> replayTurn({
    required String sessionId,
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
    required TurnReplayAction action,
    String? message,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
    bool confirmedReplayUnsafe = false,
    bool confirmedDropSteers = false,
  }) async => replayResult;

  @override
  Future<SessionForkResult> forkSession({
    required String sessionId,
    required String targetMessageId,
    required String targetTurnId,
  }) async => const SessionForkResult(outcome: 'accepted');

  @override
  Future<SessionCompactResult> compactSession({
    required String sessionId,
  }) async => const SessionCompactResult(outcome: 'accepted');

  @override
  Future<void> retryRuntimeNotice({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  }) async {}

  @override
  Future<void> continueWithProvider({
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  }) async {}

  @override
  Future<void> updateSessionPreferences({
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {}

  @override
  Future<SessionQueryResult> getSessions({SessionQueryRequest? query}) async {
    if (!controller.isConnected) {
      return SessionQueryResult(sessions: initialSessions, hasMore: false);
    }
    getSessionsCalls += 1;
    _sessionsController.add(List<Session>.from(initialSessions));
    return SessionQueryResult(sessions: initialSessions, hasMore: false);
  }

  @override
  Future<SessionQueryResult> refreshSessions({SessionQueryRequest? query}) async {
    return getSessions(query: query);
  }

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) async {
    loadedHistorySessionIds.add(sessionId);
    return const [];
  }

  @override
  Future<List<CanonicalEvent>> loadOlderSessionHistory(String sessionId) async {
    loadedOlderHistorySessionIds.add(sessionId);
    final error = olderHistoryError;
    if (error != null) throw error;
    final completer = olderHistoryCompleter;
    if (completer != null) return completer.future;
    return _currentMessages;
  }

  @override
  Future<List<CanonicalEvent>> loadAnchoredSessionHistory(
    String sessionId,
    String anchorEventId,
  ) => loadSessionHistory(sessionId);

  @override
  Future<List<CanonicalEvent>> loadNewerSessionHistory(String sessionId) async {
    return _currentMessages;
  }

  @override
  bool get historyHasMore => historyHasMoreValue;

  @override
  String? get historyNextCursor => historyNextCursorValue;

  @override
  bool get historyHasNewer => false;

  @override
  String? get historyNextNewerCursor => null;

  @override
  Future<Session> createSession({
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<DeviceWorkspace>> getWorkspaces() async {
    return const [];
  }

  @override
  Future<List<SlashCommandEntry>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) async {
    return const [];
  }

  @override
  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({
    String? workspaceId,
    String? path,
  }) async {
    return const WorkspaceTreeSnapshot(
      workspaceId: '/repo',
      rootPath: '/repo',
      path: '/repo',
      parentPath: null,
      entries: [],
      truncated: false,
    );
  }

  @override
  Future<DeviceWorkspace> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> removeWorkspace({required String workspaceId}) async {
    throw UnimplementedError();
  }

  @override
  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> createFolder({
    required String parentPath,
    required String name,
  }) async {}

  @override
  Future<void> renameFolder({required String path, required String newName}) async {}

  @override
  Future<void> deleteFolder({required String path}) async {}

  @override
  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) async {
    _pendingSuspendedRequest = allow ? null : _pendingSuspendedRequest;
    _pendingSuspendedController.add(_pendingSuspendedRequest);
  }

  @override
  Future<void> updateSessionTitle(String sessionId, String title) async {}

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedSessionIds.add(sessionId);
  }

  void emitSessionCreated(Session session) {
    _sessionCreatedController.add(session);
  }

  void emitProcessing(DeviceProcessingSnapshot snapshot) {
    _processingSnapshot = snapshot;
    _processingController.add(snapshot);
  }

  @override
  Future<WorkspacePolicy> getWorkspacePolicy(String workspacePath) async {
    return const WorkspacePolicy();
  }

  @override
  Future<WorkspacePolicy> setWorkspacePermissionMode({
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  }) async {
    return const WorkspacePolicy();
  }

  @override
  Stream<WorkspacePolicy> watchWorkspacePolicy(String workspaceId) {
    return const Stream.empty();
  }

  @override
  void dispose() {
    unawaited(_eventsController.close());
    unawaited(_sessionsController.close());
    unawaited(_sessionCreatedController.close());
    unawaited(_sessionUpdatedController.close());
    unawaited(_sessionDeletedController.close());
    unawaited(_messagesController.close());
    unawaited(_queuedMessagesController.close());
    unawaited(_processingController.close());
    unawaited(_pendingSuspendedController.close());
    unawaited(_runtimeNoticeController.close());
  }
}

class _FakeFailingClient extends _FakeDeviceClient {
  _FakeFailingClient({
    required super.config,
    required super.controller,
    required super.initialSessions,
  });

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) async {
    loadedHistorySessionIds.add(sessionId);
    throw Exception('History load failed');
  }
}

class _FakeFailOnceClient extends _FakeDeviceClient {
  bool _shouldFail = true;

  _FakeFailOnceClient({
    required super.config,
    required super.controller,
    required super.initialSessions,
  });

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) async {
    loadedHistorySessionIds.add(sessionId);
    if (_shouldFail) {
      _shouldFail = false;
      throw Exception('History load failed once');
    }
    return const [];
  }
}

class _FakeDelayedClient extends _FakeDeviceClient {
  Duration historyDelay;
  final _historyCompleter = Completer<void>();

  _FakeDelayedClient({
    required super.config,
    required super.controller,
    required super.initialSessions,
    this.historyDelay = const Duration(milliseconds: 500),
  });

  void completeHistory() {
    if (!_historyCompleter.isCompleted) {
      _historyCompleter.complete();
    }
  }

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) async {
    loadedHistorySessionIds.add(sessionId);
    await Future<void>.delayed(historyDelay);
    await _historyCompleter.future;
    return const [];
  }
}

class _FakeControlledClient extends _FakeDeviceClient {
  final _historyCompleter = Completer<void>();

  _FakeControlledClient({
    required super.config,
    required super.controller,
    required super.initialSessions,
  });

  void completeHistory() {
    if (!_historyCompleter.isCompleted) {
      _historyCompleter.complete();
    }
  }

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(String sessionId) async {
    loadedHistorySessionIds.add(sessionId);
    await _historyCompleter.future;
    return const [];
  }
}
