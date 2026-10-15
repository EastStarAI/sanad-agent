import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/session_sidebar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/theme/activity_animation_policy.dart';

import '../helpers/fake_device_repository.dart';
import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceCapabilitiesStore capabilities;
  late DeviceConnectionCoordinator resolver;
  late FakeConversationRepository conversationRepository;
  late ConversationCacheStore cacheStore;
  late ConversationCacheRepository cacheRepository;
  late _TestSessionCubit sessionCubit;
  late SessionSidebarCubit sessionSidebarCubit;
  late DeviceConfig agent;
  late Session firstSession;
  late Session secondSession;

  setUp(() async {
    socket = FakeSanadSocketService()..setConnected(true);
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilities = DeviceCapabilitiesStore(resolver);
    conversationRepository = FakeConversationRepository();
    agent = DeviceConfig(
      id: 'agent-1',
      name: 'SanadAgent',
      metadata: const {
        'is_local_reachable': true,
        'preferred_connection_scope': 'local',
        'is_local_candidate': true,
      },
      isOnline: true,
    );
    firstSession = Session(
      id: 'session-1',
      title: 'First session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    secondSession = Session(
      id: 'session-2',
      title: 'Second session',
      deviceId: agent.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    conversationRepository.seedSessions(agent, [firstSession, secondSession]);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = _TestSessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    cacheStore = ConversationCacheStore();
    cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );
    cacheStore.setActiveDevice(agent.id);
    cacheStore.applySessionCreated(agent.id, firstSession);
    cacheStore.applySessionCreated(agent.id, secondSession);
    sessionSidebarCubit = SessionSidebarCubit(cacheRepository: cacheRepository);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    SessionSidebar.debugOnSessionRowBuild = null;
    SidebarConversationRow.debugOnSessionRowBuild = null;
    SidebarWorkspacesSection.debugOnBuild = null;
    SidebarUnscopedConversationsSection.debugOnBuild = null;
    await sessionCubit.close();
    await sessionSidebarCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    socket.dispose();
  });

  testWidgets('processing updates rebuild only the affected session row', (
    tester,
  ) async {
    final rowBuilds = <String, int>{};
    SidebarConversationRow.debugOnSessionRowBuild = (deviceId, sessionId) {
      rowBuilds.update(sessionId, (value) => value + 1, ifAbsent: () => 1);
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionSidebarCubit: sessionSidebarCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      conversationRepository: conversationRepository,
      child: const SessionSidebar(showChrome: false),
    );
    await tester.pump();
    expect(find.text('First session'), findsOneWidget);
    expect(find.text('Second session'), findsOneWidget);
    expect(find.text('local'), findsOneWidget);

    rowBuilds.clear();
    sessionCubit.emitState(
      sessionCubit.state.copyWith(
        attentionStates: {
          agent.id: {
            firstSession.id: _attention(
              firstSession.id,
              SessionExecutionState.running,
            ),
          },
        },
      ),
    );
    expect(
      sessionCubit.state.attentionStateFor(agent.id, firstSession.id),
      isNotNull,
    );
    await tester.pump();
    await tester.pump();

    expect(rowBuilds, {firstSession.id: 1});
  });

  testWidgets(
    'pending permission updates rebuild only the affected session row',
    (tester) async {
      final rowBuilds = <String, int>{};
      SidebarConversationRow.debugOnSessionRowBuild = (deviceId, sessionId) {
        rowBuilds.update(sessionId, (value) => value + 1, ifAbsent: () => 1);
      };

      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionSidebarCubit: sessionSidebarCubit,
        capabilities: capabilities,
        conversationCacheRepository: cacheRepository,
        conversationRepository: conversationRepository,
        child: const SessionSidebar(showChrome: false),
      );

      rowBuilds.clear();
      sessionCubit.emitState(
        sessionCubit.state.copyWith(
          attentionStates: {
            agent.id: {
              secondSession.id: _attention(
                secondSession.id,
                SessionExecutionState.blocked,
                request: _request(secondSession.id),
              ),
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(rowBuilds, {secondSession.id: 1});
      expect(find.byIcon(Icons.pending_actions_outlined), findsOneWidget);
    },
  );

  testWidgets(
    'sidebar renders every authoritative state with one unified priority selector',
    (tester) async {
      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionSidebarCubit: sessionSidebarCubit,
        capabilities: capabilities,
        conversationCacheRepository: cacheRepository,
        conversationRepository: conversationRepository,
        child: const SessionSidebar(showChrome: false),
      );
      await tester.pump();

      final expectedIcons = <SessionExecutionState, IconData?>{
        SessionExecutionState.idle: null,
        SessionExecutionState.queued: Icons.queue_outlined,
        SessionExecutionState.running: null,
        SessionExecutionState.waiting: Icons.schedule_outlined,
        SessionExecutionState.blocked: Icons.error_outline,
        SessionExecutionState.resuming: null,
        SessionExecutionState.stopping: Icons.stop_circle_outlined,
      };
      for (final entry in expectedIcons.entries) {
        sessionCubit.emitState(const SessionState());
        await tester.pump();
        sessionCubit.emitState(
          SessionState(
            attentionStates: {
              agent.id: {
                firstSession.id: _attention(firstSession.id, entry.key),
              },
            },
          ),
        );
        await tester.pump();
        if (entry.value != null) {
          expect(
            find.byIcon(entry.value!),
            findsOneWidget,
            reason: entry.key.name,
          );
        } else if (entry.key == SessionExecutionState.running || entry.key == SessionExecutionState.resuming) {
          expect(
            find.byKey(const Key('sidebar_session_busy_indicator')),
            findsOneWidget,
            reason: entry.key.name,
          );
          expect(
            find.byIcon(Icons.error_outline),
            findsNothing,
            reason: '${entry.key.name} must replace a previous error icon',
          );
        }
      }

      // A pending question outranks the blocked execution snapshot.
      sessionCubit.emitState(const SessionState());
      await tester.pump();
      sessionCubit.emitState(
        SessionState(
          attentionStates: {
            agent.id: {
              firstSession.id: _attention(
                firstSession.id,
                SessionExecutionState.blocked,
                request: _request(firstSession.id, toolName: 'system_ask_user'),
              ),
            },
          },
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    },
  );

  testWidgets('unscoped cache updates do not rebuild the workspace section', (
    tester,
  ) async {
    int workspaceBuilds = 0;
    SidebarWorkspacesSection.debugOnBuild = () => workspaceBuilds += 1;

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionSidebarCubit: sessionSidebarCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      conversationRepository: conversationRepository,
      child: const SessionSidebar(showChrome: false),
    );
    await tester.pump();

    workspaceBuilds = 0;
    cacheRepository.applyUserMessageAccepted(
      agent.id,
      firstSession.id,
      timestamp: DateTime(2026, 1, 4),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(workspaceBuilds, 0);
  });

  testWidgets(
    'sidebar busy dot renders static green circle when continuous motion is disabled',
    (tester) async {
      await ActivityAnimationPolicy.withContinuousActivityAnimationOverrideAsync(false, () async {
        await pumpTestApp(
          tester,
          agentCubit: agentCubit,
          sessionCubit: sessionCubit,
          sessionSidebarCubit: sessionSidebarCubit,
          capabilities: capabilities,
          conversationCacheRepository: cacheRepository,
          conversationRepository: conversationRepository,
          child: const SessionSidebar(showChrome: false),
        );
        await tester.pump();

        sessionCubit.emitState(const SessionState());
        await tester.pump();
        sessionCubit.emitState(
          SessionState(
            attentionStates: {
              agent.id: {
                firstSession.id: _attention(firstSession.id, SessionExecutionState.running),
              },
            },
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('sidebar_session_busy_indicator')), findsOneWidget);
        expect(find.byKey(const Key('sidebar_busy_dot_static')), findsOneWidget);
        expect(find.byKey(const Key('sidebar_busy_dot_animated')), findsNothing);

        final container = tester.widget<Container>(find.byKey(const Key('sidebar_busy_dot_static')));
        final boxDecoration = container.decoration as BoxDecoration;
        expect(boxDecoration.color, equals(const Color(0xFF22C55E)));
      });
    },
  );

  testWidgets(
    'sidebar busy dot renders animated dot when continuous motion is allowed',
    (tester) async {
      await ActivityAnimationPolicy.withContinuousActivityAnimationOverrideAsync(true, () async {
        await pumpTestApp(
          tester,
          agentCubit: agentCubit,
          sessionCubit: sessionCubit,
          sessionSidebarCubit: sessionSidebarCubit,
          capabilities: capabilities,
          conversationCacheRepository: cacheRepository,
          conversationRepository: conversationRepository,
          child: const SessionSidebar(showChrome: false),
        );
        await tester.pump();

        sessionCubit.emitState(const SessionState());
        await tester.pump();
        sessionCubit.emitState(
          SessionState(
            attentionStates: {
              agent.id: {
                firstSession.id: _attention(firstSession.id, SessionExecutionState.running),
              },
            },
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('sidebar_session_busy_indicator')), findsOneWidget);
        expect(find.byKey(const Key('sidebar_busy_dot_animated')), findsOneWidget);
        expect(find.byKey(const Key('sidebar_busy_dot_static')), findsNothing);
      });
    },
  );
}

SessionAttentionState _attention(
  String sessionId,
  SessionExecutionState state, {
  DeviceSuspendedRequest? request,
}) => SessionAttentionState(
  sessionId: sessionId,
  executionSnapshot: SessionExecutionSnapshot(
    sessionId: sessionId,
    state: state,
    workItemId: state == SessionExecutionState.idle ? null : 'work-$sessionId',
    requestId: state == SessionExecutionState.idle ? null : 'request-$sessionId',
    revision: 1,
    updatedAt: null,
  ),
  runtimeNotice: null,
  pendingSuspendedRequest: request,
);

DeviceSuspendedRequest _request(
  String sessionId, {
  String toolName = 'shell',
}) => DeviceSuspendedRequest(
  requestId: 'permission-$sessionId',
  sessionId: sessionId,
  toolName: toolName,
  permissionClass: 'workspace_write',
  scope: 'once',
  workspaceId: null,
  workspaceName: null,
  workspacePath: null,
  toolInput: const {},
  tool: const {},
);

class _TestSessionCubit extends SessionCubit {
  _TestSessionCubit({
    required super.agentCubit,
    required super.socketService,
    required super.conversationRepository,
  });

  void emitState(SessionState state) {
    emit(state);
  }
}
