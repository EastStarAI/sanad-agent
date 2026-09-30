/// Integration-style flow test for the full conversation pipeline.
///
/// This test does NOT use real sockets, real Flutter widgets, or a DI container.
/// It wires the real Cubit chain together with fake collaborators to verify the
/// end-to-end data flow defined in the plan's "Target Conversation Flow" section:
///
///   1. Login / agent loaded (DeviceCubit emits DeviceActive)
///   2. Socket connected (SessionCubit loads sessions)
///   3. Agent loads sessions (repository returns seeded list)
///   4. User selects session (SessionMessagesCubit reacts, history loaded)
///   5. User sends message (ConversationInputCubit → repository)
///   6. Streaming socket event updates message list (repository emits → cubit)
///
/// Exit criterion: `fvm flutter test` passes.
library;

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/fake_device_preferences_repository.dart';
import '../../helpers/fake_socket.dart';

void main() {
  // ── Shared fixtures ──────────────────────────────────────────────────────

  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late FakeConversationRepository conversationRepository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;
  late ConversationInputCubit inputCubit;

  late DeviceConfig agent;
  late Session session1;
  late Session session2;
  const workspace = DeviceWorkspace(id: 'workspace-1', name: 'desktop-agent', path: '/repo');

  setUp(() {
    socket = FakeSanadSocketService();
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );

    conversationRepository = FakeConversationRepository();

    agent = DeviceConfig(id: 'agent-flow-1', name: 'SanadAgent', isOnline: true);

    session1 = Session(
      id: 'session-flow-1',
      title: 'First session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    session2 = Session(
      id: 'session-flow-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );

    // Seed two sessions for the agent in the fake repository
    conversationRepository.seedSessions(agent, [session1, session2]);
  });

  tearDown(() async {
    await inputCubit.close();
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    await conversationRepository.dispose();
    socket.dispose();
  });

  // ── Helper to wire the full chain ─────────────────────────────────────────

  void wire() {
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    inputCubit = ConversationInputCubit(messagesCubit: messagesCubit);
  }

  // ── Step 1 + 2: Login / socket connected → sessions loaded ─────────────────

  group('step 1-2: agent active + socket connected → sessions loaded', () {
    test('SessionCubit loads sessions once DeviceActive and socket connected', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

      wire();
      await Future<void>.delayed(Duration.zero);

      final sessions = sessionCubit.state.agentSessions[agent.id];
      expect(sessions, isNotNull, reason: 'Sessions should be loaded for the active agent');
      expect(sessions!.map((t) => t.id).toList(), containsAll([session1.id, session2.id]));
    });

    test('SessionCubit does NOT load sessions when socket is disconnected', () async {
      conversationRepository.transportReady = false;
      // Socket starts disconnected
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

      wire();
      await Future<void>.delayed(Duration.zero);

      expect(
        sessionCubit.state.agentSessions[agent.id],
        isNull,
        reason: 'Sessions must not be fetched before socket connects',
      );
    });

    test('SessionCubit loads sessions after socket reconnects mid-session', () async {
      conversationRepository.transportReady = false;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

      wire();
      await Future<void>.delayed(Duration.zero);
      expect(sessionCubit.state.agentSessions[agent.id], isNull);

      // Connect the socket, then trigger a refresh directly
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      await sessionCubit.refreshSessions();
      await Future<void>.delayed(Duration.zero);

      expect(sessionCubit.state.agentSessions[agent.id], isNotNull);
    });
  });

  // ── Step 3: Session selection ───────────────────────────────────────────────

  group('step 3: select session → messages cubit reacts', () {
    test('selecting a session updates SessionMessagesCubit.activeSessionId', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.activeSessionId, session1.id);
    });

    test('selecting a session calls loadSessionHistory on the repository', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      expect(conversationRepository.loadedHistorySessionIds, contains(session1.id));
    });

    test('replay confirmation resubmission re-reads the current route', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);
      messagesCubit.setNextMessagePreferences(
        providerId: 'provider-before',
        model: 'model-before',
        thinkingMode: 'balanced',
      );
      conversationRepository.replayResults.addAll(const [
        TurnReplayResult(
          outcome: 'confirmation_required',
          safety: TurnReplaySafety.unsafe,
          requiresConfirmation: true,
        ),
        TurnReplayResult(
          outcome: 'accepted',
          safety: TurnReplaySafety.unsafe,
          requiresConfirmation: false,
          historyRevision: 1,
        ),
      ]);

      final preflight = await messagesCubit.replayTurn(
        targetRequestId: 'request-root',
        targetMessageId: 'message-root',
        targetTurnId: 'turn-root',
        action: TurnReplayAction.retry,
      );
      expect(preflight.requiresConfirmation, isTrue);

      messagesCubit.setNextMessagePreferences(
        providerId: 'provider-after',
        model: 'model-after',
        thinkingMode: 'deep',
      );
      final accepted = await messagesCubit.replayTurn(
        targetRequestId: 'request-root',
        targetMessageId: 'message-root',
        targetTurnId: 'turn-root',
        action: TurnReplayAction.retry,
        confirmedReplayUnsafe: true,
      );
      expect(accepted.isAccepted, isTrue);

      final before = conversationRepository.replayRequests.first;
      final after = conversationRepository.replayRequests.last;
      expect(before['provider_instance_id'], 'provider-before');
      expect(before['model_id'], 'model-before');
      expect(before['thinking_mode'], 'balanced');
      expect(before['confirmed_replay_unsafe'], isFalse);
      expect(after['provider_instance_id'], 'provider-after');
      expect(after['model_id'], 'model-after');
      expect(after['thinking_mode'], 'deep');
      expect(after['confirmed_replay_unsafe'], isTrue);
    });

    test('switching sessions clears previous and loads new history', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      // Select first session
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);
      expect(messagesCubit.state.activeSessionId, session1.id);

      // Switch to second session
      await sessionCubit.selectSession(session2);
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.activeSessionId, session2.id);
      expect(conversationRepository.loadedHistorySessionIds, containsAll([session1.id, session2.id]));
    });

    test(
      'selecting a session with a pending permission request in history restores the pending permission request',
      () async {
        socket.setConnected(true);
        conversationRepository.transportReady = true;
        agentRepository.seedAgents([agent], activeAgentId: agent.id);
        agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
        wire();
        await Future<void>.delayed(Duration.zero);

        final request = DeviceSuspendedRequest(
          requestId: 'perm-flow-1',
          sessionId: session1.id,
          toolName: 'shell_execute',
          permissionClass: 'shell_execution',
          scope: 'workspace',
          workspaceId: 'workspace-1',
          workspaceName: 'desktop-agent',
          workspacePath: '/repo',
          toolInput: const {'command': 'echo hello'},
          tool: const {'name': 'shell_execute'},
        );

        // Seed the pending permission request in the repository
        conversationRepository.setPendingSuspendedRequest(agent, request);

        await sessionCubit.selectSession(session1);
        await Future<void>.delayed(Duration.zero);

        expect(messagesCubit.state.pendingSuspendedRequest, request);
      },
    );
  });

  // ── Step 4: Send message ───────────────────────────────────────────────────

  group('step 4: send message → ConversationInputCubit routes through repository', () {
    test('sendMessage routes trimmed text through ConversationInputCubit to repository', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      inputCubit.selectWorkspace(workspace);
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);
      messagesCubit.setNextMessagePreferences(
        providerId: 'provider-1',
        model: 'model-1',
      );
      await Future<void>.delayed(Duration.zero);

      await inputCubit.sendMessage('  Hello, Sanad!  ');

      expect(conversationRepository.sentMessages, [
        'Hello, Sanad!',
      ], reason: 'InputCubit must trim whitespace before delegating');
    });

    test('sendMessage with blank text is silently dropped', () async {
      socket.setConnected(true);
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await inputCubit.sendMessage('   ');

      expect(conversationRepository.sentMessages, isEmpty);
    });
  });

  // ── Step 5: Streaming events update message list ───────────────────────────

  group('step 5: streaming socket events update SessionMessagesCubit', () {
    test('streaming event received by repository propagates to SessionMessagesCubit.messages', () async {
      socket.setConnected(true);
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      final streamedEvent = CanonicalEvent(
        id: 'event-stream-1',
        kind: EventKind.thinking,
        status: EventStatus.running,
        text: 'Thinking...',
        timestamp: DateTime(2026, 1, 5),
      );

      // Simulate a streaming event arriving from the socket layer
      conversationRepository.setMessages(agent, [streamedEvent]);
      await Future<void>.delayed(Duration.zero);

      expect(
        messagesCubit.state.messages.any((e) => e.id == streamedEvent.id),
        isTrue,
        reason: 'Streamed events from the repository should reach the messages cubit',
      );
    });

    test('multiple streaming events accumulate and reflect the latest snapshot', () async {
      socket.setConnected(true);
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      final events = [
        CanonicalEvent(id: 'e-1', kind: EventKind.userMessage, text: 'Hello', timestamp: DateTime(2026, 1, 5, 10)),
        CanonicalEvent(
          id: 'e-2',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'Sure, ',
          timestamp: DateTime(2026, 1, 5, 11),
        ),
        CanonicalEvent(
          id: 'e-3',
          kind: EventKind.finalAnswer,
          text: 'Sure, I can help!',
          timestamp: DateTime(2026, 1, 5, 12),
        ),
      ];

      conversationRepository.setMessages(agent, events);
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.messages.length, 3);
      expect(messagesCubit.state.messages.last.id, 'e-3');
    });
  });

  // ── Step 6: Processing state ───────────────────────────────────────────────

  group('step 6: processing state propagates through the chain', () {
    test('processing snapshot from repository propagates to SessionCubit.processingSessionIds', () async {
      socket.setConnected(true);
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      conversationRepository.setProcessing(agent, DeviceProcessingSnapshot(sessionIds: {session1.id}));
      await Future<void>.delayed(Duration.zero);

      expect(sessionCubit.state.isSessionProcessing(agent.id, session1.id), isTrue);
      expect(sessionCubit.state.isSessionProcessing(agent.id, session2.id), isFalse);
    });

    test('stop() routes through ConversationInputCubit to repository', () async {
      socket.setConnected(true);
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      await inputCubit.stop();

      expect(conversationRepository.stopCalls, 1);
    });
  });

  // ── Step 7: Connection scope switching ───────────────────────────────────

  group('step 7: connection scope switching', () {
    test('keeps message updates flowing when preferredConnectionScope changes for the same agent', () async {
      socket.setConnected(true);

      final cloudAgent = DeviceConfig(
        id: 'agent-flow-1',
        name: 'SanadAgent',
        isOnline: true,
        metadata: const {'preferred_connection_scope': 'cloud'},
      );

      final localAgent = DeviceConfig(
        id: 'agent-flow-1',
        name: 'SanadAgent',
        isOnline: true,
        metadata: const {'preferred_connection_scope': 'local'},
      );

      agentRepository.seedAgents([cloudAgent], activeAgentId: cloudAgent.id);
      agentCubit.emitState(DeviceActive(activeAgent: cloudAgent, agents: [cloudAgent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      // Seed initial message for cloud agent
      final cloudEvent = CanonicalEvent(
        id: 'cloud-msg',
        kind: EventKind.finalAnswer,
        text: 'From Cloud',
        timestamp: DateTime(2026, 1, 5),
      );
      conversationRepository.setMessages(cloudAgent, [cloudEvent]);
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.messages.map((e) => e.text).toList(), contains('From Cloud'));

      // Switch scope to local
      agentCubit.emitState(DeviceActive(activeAgent: localAgent, agents: [localAgent]));
      await Future<void>.delayed(Duration.zero);

      // The cubit should now be listening to streams resolved with the new agent instance.
      // Let's verify by emitting a new message specifically for the local agent configuration.
      final localEvent = CanonicalEvent(
        id: 'local-msg',
        kind: EventKind.finalAnswer,
        text: 'From Local',
        timestamp: DateTime(2026, 1, 6),
      );
      conversationRepository.setMessages(localAgent, [localEvent]);
      await Future<void>.delayed(Duration.zero);

      expect(messagesCubit.state.messages.map((e) => e.text).toList(), contains('From Local'));
    });
  });

  group('fork: navigate to child or stay on failure', () {
    test('accepted fork selects the child and keeps the parent listed', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      final child = Session(
        id: 'child-fork-1',
        title: '(1) First session',
        deviceId: agent.id,
        createdAt: DateTime(2026, 8, 30),
        updatedAt: DateTime(2026, 8, 30),
      );
      conversationRepository.forkResult = SessionForkResult(
        outcome: 'accepted',
        child: child,
      );

      final result = await inputCubit.forkSession(
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
      );

      expect(result.isAccepted, isTrue);
      expect(sessionCubit.state.selectedSession?.id, 'child-fork-1');
      expect(
        sessionCubit.state.agentSessions[agent.id]?.map((item) => item.id),
        containsAll([session1.id, 'child-fork-1']),
      );
      expect(conversationRepository.forkRequests.single['session_id'], session1.id);
      expect(
        conversationRepository.forkRequests.single.containsKey('messages'),
        isFalse,
      );
    });

    test('already_exists still opens the existing child', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      final child = Session(
        id: 'child-fork-existing',
        title: '(1) First session',
        deviceId: agent.id,
        createdAt: DateTime(2026, 8, 30),
        updatedAt: DateTime(2026, 8, 30),
      );
      conversationRepository.forkResult = SessionForkResult(
        outcome: 'already_exists',
        child: child,
      );

      final result = await inputCubit.forkSession(
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
      );

      expect(result.isAccepted, isTrue);
      expect(sessionCubit.state.selectedSession?.id, 'child-fork-existing');
      expect(
        sessionCubit.state.agentSessions[agent.id]?.map((item) => item.id),
        containsAll([session1.id, 'child-fork-existing']),
      );
    });

    test('navigation failure keeps the committed child in the sidebar', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      sessionCubit = _NavigationFailingSessionCubit(
        agentCubit: agentCubit,
        socketService: socket,
        conversationRepository: conversationRepository,
      );
      messagesCubit = SessionMessagesCubit(
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        conversationRepository: conversationRepository,
        preferencesRepository: FakeDevicePreferencesRepository(),
      );
      inputCubit = ConversationInputCubit(messagesCubit: messagesCubit);
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      final child = Session(
        id: 'child-fork-navigation-failed',
        title: '(1) First session',
        deviceId: agent.id,
        createdAt: DateTime(2026, 8, 30),
        updatedAt: DateTime(2026, 8, 30),
      );
      conversationRepository.forkResult = SessionForkResult(
        outcome: 'accepted',
        child: child,
      );
      (sessionCubit as _NavigationFailingSessionCubit).failSelection = true;

      final result = await inputCubit.forkSession(
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
      );

      expect(result.isAccepted, isTrue);
      expect(result.navigationFailed, isTrue);
      expect(sessionCubit.state.selectedSession?.id, session1.id);
      expect(
        sessionCubit.state.agentSessions[agent.id]?.map((item) => item.id),
        contains('child-fork-navigation-failed'),
      );
    });

    test('failed fork keeps the original session selected', () async {
      socket.setConnected(true);
      conversationRepository.transportReady = true;
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);
      await sessionCubit.selectSession(session1);
      await Future<void>.delayed(Duration.zero);

      conversationRepository.forkResult = const SessionForkResult(
        outcome: 'target_not_forkable',
      );

      final result = await inputCubit.forkSession(
        targetMessageId: 'm-final',
        targetTurnId: 'turn-1',
      );

      expect(result.isAccepted, isFalse);
      expect(sessionCubit.state.selectedSession?.id, session1.id);
      expect(
        sessionCubit.state.agentSessions[agent.id]?.map((item) => item.id),
        isNot(contains('child-fork-1')),
      );
    });
  });

  // ── Step 8: Logout resets the chain ───────────────────────────────────────

  group('step 8: logout clears all cached state', () {
    test('resetForLogout clears agents; SessionCubit resets to empty state', () async {
      socket.setConnected(true);
      agentRepository.seedAgents([agent], activeAgentId: agent.id);
      agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
      wire();
      await Future<void>.delayed(Duration.zero);

      // Sessions are loaded
      expect(sessionCubit.state.agentSessions[agent.id], isNotNull);

      // Simulate logout
      await agentCubit.resetForLogout();
      await Future<void>.delayed(Duration.zero);

      expect(sessionCubit.state.agentSessions, isEmpty);
      expect(messagesCubit.state.messages, isEmpty);
    });
  });
}

class _NavigationFailingSessionCubit extends SessionCubit {
  _NavigationFailingSessionCubit({
    required super.agentCubit,
    required super.socketService,
    required super.conversationRepository,
  });

  bool failSelection = false;

  @override
  Future<void> selectSession(Session session) {
    if (failSelection) {
      throw StateError('navigation failed');
    }
    return super.selectSession(session);
  }
}
