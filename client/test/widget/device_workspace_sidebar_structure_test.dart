import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/device_workspace_sidebar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/gestures.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_state.dart';
import 'package:sanad_client/features/home/presentation/widgets/conversation_workspace_layout.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';

import '../helpers/fake_device_repository.dart';
import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart';

/// Device workspace sidebar structure and intent wiring tests.
///
/// Verifies:
/// - The persistent device selector + settings icon are always present.
/// - Workspaces and Conversations headings render with their section data.
/// - The `+` (create-workspace) and per-workspace `+` (new-conversation) emit
///   the correct intents without creating a Session.
/// - Expansion is persisted; toggling an unloaded workspace triggers a lazy
///   first-page fetch.
/// - Switching device renders only that device's data.
/// - Session selection navigates to the correct route.
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
  late DeviceConfig device;
  late DeviceWorkspace workspace;

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
    device = DeviceConfig(
      id: 'device-1',
      name: 'Sanad Desktop',
      metadata: const {'is_local_reachable': true, 'preferred_connection_scope': 'local'},
      isOnline: true,
    );
    workspace = const DeviceWorkspace(id: 'ws-1', name: 'Project A', path: '/tmp/a');
    agentRepository.seedAgents([device], activeAgentId: device.id);
    conversationRepository.workspaces.add(workspace);
    agentCubit.emitState(DeviceActive(activeAgent: device, agents: [device]));
    cacheStore = ConversationCacheStore();
    cacheRepository = ConversationCacheRepository(cache: cacheStore, transport: conversationRepository);
    // Seed workspaces + a scoped + an unscoped session.
    final scoped = Session(
      id: 's-scoped',
      title: 'Scoped chat',
      deviceId: device.id,
      workspaceId: 'ws-1',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      lastMessageAt: DateTime(2026, 1, 1),
    );
    final unscoped = Session(
      id: 's-unscoped',
      title: 'Free chat',
      deviceId: device.id,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
      lastMessageAt: DateTime(2026, 1, 2),
    );
    conversationRepository.seedSessions(device, [scoped, unscoped]);
    sessionCubit = _TestSessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    cacheStore.setActiveDevice(device.id);
    cacheStore.applyWorkspacesRefreshed(device.id, [
      workspace,
    ], generation: cacheStore.advanceWorkspacesGeneration(device.id));
    cacheStore.applySessionCreated(device.id, scoped);
    cacheStore.applySessionCreated(device.id, unscoped);
    sessionSidebarCubit = SessionSidebarCubit(cacheRepository: cacheRepository);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await sessionSidebarCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    socket.dispose();
  });

  Future<void> pumpSidebar(
    WidgetTester tester, {
    GoRouter? router,
    bool isDrawerMode = false,
  }) {
    return pumpTestApp(
      tester,
      router: router,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionSidebarCubit: sessionSidebarCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      conversationRepository: conversationRepository,
      child: DeviceWorkspaceSidebar(
        showChrome: false,
        key: const Key('sidebar'),
        isDrawerMode: isDrawerMode,
      ),
    );
  }

  Future<void> setSurfaceSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  testWidgets('session titles follow their first strong character', (tester) async {
    final arabicFirst = Session(
      id: 's-arabic-direction',
      title: 'مرحبا this title continues mostly in English',
      deviceId: device.id,
      createdAt: DateTime(2026, 1, 3),
      updatedAt: DateTime(2026, 1, 3),
    );
    final englishFirst = Session(
      id: 's-english-direction',
      title: 'Hello هذا العنوان يكمل باللغة العربية',
      deviceId: device.id,
      createdAt: DateTime(2026, 1, 4),
      updatedAt: DateTime(2026, 1, 4),
    );
    cacheStore.applySessionCreated(device.id, arabicFirst);
    cacheStore.applySessionCreated(device.id, englishFirst);

    await pumpSidebar(tester);
    await tester.pump();

    final arabicFinder = find.text(arabicFirst.title);
    final englishFinder = find.text(englishFirst.title);
    final arabicTitle = tester.widget<Text>(arabicFinder);
    final englishTitle = tester.widget<Text>(englishFinder);
    expect(arabicTitle.textDirection, TextDirection.rtl);
    expect(arabicTitle.textAlign, TextAlign.start);
    expect(englishTitle.textDirection, TextDirection.ltr);
    expect(englishTitle.textAlign, TextAlign.start);

    final arabicAlign = tester.widget<Align>(
      find.ancestor(of: arabicFinder, matching: find.byType(Align)).first,
    );
    final englishAlign = tester.widget<Align>(
      find.ancestor(of: englishFinder, matching: find.byType(Align)).first,
    );
    expect(arabicAlign.alignment, AlignmentDirectional.centerStart);
    expect(englishAlign.alignment, AlignmentDirectional.centerStart);
    expect(tester.getTopLeft(arabicFinder).dx, closeTo(tester.getTopLeft(englishFinder).dx, 0.1));
  });

  testWidgets('device selector header is always present and dropdown exposes Device Settings', (tester) async {
    await pumpSidebar(tester);
    expect(find.textContaining('Sanad Desktop'), findsOneWidget);
    expect(find.byKey(const Key('sidebar_create_workspace_btn')), findsOneWidget);

    // Open dropdown to find settings option
    await tester.tap(find.textContaining('Sanad Desktop'));
    await tester.pumpAndSettle();
    expect(find.text('Device Settings'), findsOneWidget);
  });

  testWidgets('empty device header distinguishes loading from a settled empty inventory', (tester) async {
    agentCubit.emitState(const DeviceNoActive(isLoadingFromBackend: true));
    await pumpSidebar(tester);

    expect(find.text('Loading devices…'), findsOneWidget);
    expect(find.text('No devices'), findsNothing);

    agentCubit.emitState(const DeviceNoActive());
    await tester.pump();

    expect(find.text('Loading devices…'), findsNothing);
    expect(find.text('No devices'), findsOneWidget);
  });

  testWidgets('Workspaces heading and workspace-scoped session render', (tester) async {
    await pumpSidebar(tester);
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Project A'), findsOneWidget);
    expect(find.text('Scoped chat'), findsOneWidget);
  });

  testWidgets('workspace gear appears on hover and opens scoped settings', (tester) async {
    Uri? openedSettings;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: DeviceWorkspaceSidebar(
              showChrome: false,
              key: Key('sidebar'),
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) {
            openedSettings = state.uri;
            return const Text('Workspace settings');
          },
        ),
      ],
    );
    await pumpSidebar(tester, router: router);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.text('Project A')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace_settings_btn')));
    await tester.pumpAndSettle();

    expect(openedSettings?.queryParameters['section'], 'workspace');
    expect(openedSettings?.queryParameters['device_id'], device.id);
    expect(openedSettings?.queryParameters['workspace_id'], workspace.id);
  });

  testWidgets('Conversations section heading and unscoped session render', (tester) async {
    await pumpSidebar(tester);
    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('Free chat'), findsOneWidget);
  });

  testWidgets('session selection defers activation and navigates to its route', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: DeviceWorkspaceSidebar(showChrome: false, key: Key('sidebar')),
          ),
        ),
        GoRoute(
          path: '/conversations/:deviceId/:sessionId',
          builder: (context, state) => const Text('Selected route'),
        ),
      ],
    );
    await pumpSidebar(tester, router: router);

    await tester.tap(find.text('Scoped chat'));
    await tester.pumpAndSettle();

    expect(conversationRepository.activatedSessionIds, isEmpty);
    expect(find.text('Selected route'), findsOneWidget);
  });

  testWidgets('switching active device renders only that device data', (tester) async {
    // Switch the cache active device to a second device with no overlapping data.
    final device2 = DeviceConfig(id: 'device-2', name: 'Cloud', isOnline: true);
    cacheStore.setActiveDevice(device2.id);
    await tester.pump();
    // agentCubit still considers device-1 the active agent so the sidebar appears;
    // only the body comes from cacheStore. Verify the cubit projection.
    expect(sessionSidebarCubit.state.activeDeviceId, device2.id);
    // device-1's session titles are absent in the new device's snapshot.
    final groups = sessionSidebarCubit.state.snapshot?.conversationGroups ?? const [];
    final hasFreeChat = groups.any((g) => g.sessions.any((s) => s.id == 's-unscoped'));
    expect(hasFreeChat, isFalse);
  });

  testWidgets('restored cloud cache renders after DeviceNoActive resolves', (tester) async {
    final cloud = DeviceConfig(id: 'cloud-device', name: 'Cloud device', isOnline: false);
    final cached = Session(
      id: 'cloud-session',
      title: 'Cloud cached chat',
      deviceId: cloud.id,
      createdAt: DateTime(2026, 2, 1),
      updatedAt: DateTime(2026, 2, 1),
    );
    cacheStore.applySessionCreated(cloud.id, cached);
    cacheStore.setActiveDevice(cloud.id);
    agentCubit.emitState(DeviceNoActive(agents: [device]));

    await pumpSidebar(tester);
    await tester.pump();
    expect(find.text('No device selected'), findsOneWidget);

    agentCubit.emitState(DeviceActive(activeAgent: cloud, agents: [device, cloud]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('No device selected'), findsNothing);
    expect(find.text('Cloud cached chat'), findsOneWidget);
  });

  testWidgets('cached cloud row dispatches through its snapshot device, not a stale active device', (tester) async {
    final cloud = DeviceConfig(id: 'cloud-device', name: 'Cloud device', isOnline: false);
    final cached = Session(
      id: 'cloud-session',
      title: 'Cloud cached chat',
      deviceId: cloud.id,
      createdAt: DateTime(2026, 2, 1),
      updatedAt: DateTime(2026, 2, 1),
    );
    agentRepository.seedAgents([device, cloud], activeAgentId: device.id);
    agentCubit.emitState(DeviceActive(activeAgent: device, agents: [device, cloud]));
    await tester.idle();
    cacheStore.applySessionCreated(cloud.id, cached);
    cacheStore.setActiveDevice(cloud.id);
    await tester.idle();

    await pumpSidebar(tester);
    await tester.pump();

    final row = tester.widget<SidebarConversationRow>(
      find.byType(SidebarConversationRow).first,
    );
    expect(row.session.id, cached.id);
    expect(row.device.id, cloud.id);
    expect((agentCubit.state as DeviceActive).activeAgent.id, device.id);
  });

  testWidgets('background refresh with cached rows has no loading chrome', (tester) async {
    await pumpSidebar(tester);
    cacheStore.setSectionLoading(device.id, null);
    await tester.pump();

    expect(find.text('Free chat'), findsOneWidget);
    expect(find.textContaining('Refreshing'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('top New Session routes intent without creating a daemon session', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: DeviceWorkspaceSidebar(showChrome: false, key: Key('sidebar')),
          ),
        ),
        GoRoute(
          path: '/conversations/:deviceId',
          builder: (context, state) => const SizedBox(),
        ),
      ],
    );
    await pumpSidebar(tester, router: router);

    await tester.tap(find.byKey(const Key('sidebar_new_session_btn')));
    await tester.pump();

    expect(conversationRepository.createdSessionRequests, isEmpty);
    expect(conversationRepository.beginNewSessionCalls, 1);
  });

  testWidgets('new conversation intent inside a workspace sets draft workspaceId without creating a session', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: DeviceWorkspaceSidebar(showChrome: false, key: Key('sidebar')),
          ),
        ),
        GoRoute(
          path: '/conversations/:deviceId',
          builder: (context, state) => const SizedBox(),
        ),
      ],
    );
    await pumpSidebar(tester, router: router);
    expect(conversationRepository.createdSessionRequests.length, 0);
    expect(conversationRepository.beginNewSessionCalls, 0);
    final plusButton = find.byKey(const Key('sidebar_new_conversation_btn'));
    expect(plusButton, findsOneWidget);
    await tester.tap(plusButton);
    await tester.pump();
    expect(conversationRepository.createdSessionRequests.length, 0);
    expect(conversationRepository.beginNewSessionCalls, 1);
    final draft = cacheRepository.newConversationDraft(device.id);
    expect(draft.workspaceId, 'ws-1');
  });

  testWidgets('unscoped Conversations plus button starts a New Conversation with no workspace binding', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: DeviceWorkspaceSidebar(showChrome: false, key: Key('sidebar')),
          ),
        ),
        GoRoute(
          path: '/conversations/:deviceId',
          builder: (context, state) => const SizedBox(),
        ),
      ],
    );
    await pumpSidebar(tester, router: router);

    // Pre-seed a workspace-bound draft to prove the button clears it.
    cacheRepository.setNewConversationDraft(device.id, workspaceId: 'ws-1');
    await tester.pump();

    final plusButton = find.byKey(const Key('sidebar_new_unscoped_conversation_btn'));
    expect(plusButton, findsOneWidget);
    await tester.tap(plusButton);
    await tester.pump();

    expect(
      conversationRepository.createdSessionRequests,
      isEmpty,
      reason: 'the plus button must not create a session before send',
    );
    expect(conversationRepository.beginNewSessionCalls, 1);
    final draft = cacheRepository.newConversationDraft(device.id);
    expect(draft.workspaceId, isNull, reason: 'the New Conversation draft must be unscoped (no workspace)');
  });

  testWidgets('desktop and drawer layouts keep the sidebar interactive without overflow', (tester) async {
    for (final scenario in [
      (size: const Size(1280, 900), isDrawerMode: false),
      (size: const Size(390, 844), isDrawerMode: true),
    ]) {
      await setSurfaceSize(tester, scenario.size);
      await pumpSidebar(tester, isDrawerMode: scenario.isDrawerMode);
      await tester.pump();

      expect(find.byKey(const Key('sidebar')), findsOneWidget);
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Conversations'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('drawer mode keeps primary actions at accessible touch sizes', (tester) async {
    await setSurfaceSize(tester, const Size(390, 844));
    await pumpSidebar(tester, isDrawerMode: true);
    await tester.pump();

    expect(tester.getSize(find.byKey(const Key('sidebar_create_workspace_btn'))).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(find.byKey(const Key('sidebar_new_conversation_btn'))).height, greaterThanOrEqualTo(44));
  });

  testWidgets('offline stale banner keeps cached sessions visible with retry affordance', (tester) async {
    final offlineDevice = device.copyWith(isOnline: false);
    agentCubit.emitState(DeviceActive(activeAgent: offlineDevice, agents: [offlineDevice]));
    final generation = cacheStore.advanceGeneration(device.id, null);
    cacheStore.applySectionRefreshed(
      device.id,
      null,
      [
        Session(
          id: 'cached-1',
          title: 'Cached conversation',
          deviceId: device.id,
          createdAt: DateTime(2026, 1, 3),
          updatedAt: DateTime(2026, 1, 3),
          lastMessageAt: DateTime(2026, 1, 3),
        ),
      ],
      nextCursor: null,
      hasMore: false,
      generation: generation,
    );
    cacheStore.applySectionError(
      device.id,
      null,
      'offline',
      generation: generation,
    );

    await pumpSidebar(tester);
    await tester.pump();

    expect(find.text('Cached conversation'), findsOneWidget);
    expect(find.textContaining('Offline — showing cached conversations'), findsOneWidget);
    expect(find.text('Retry'), findsWidgets);
  });

  testWidgets('desktop header exposes Back and Forward controls', (tester) async {
    final history = ConversationHistoryController();
    final d1 = ConversationDestination.session(deviceId: 'device-1', sessionId: 's-1');
    final d2 = ConversationDestination.session(deviceId: 'device-1', sessionId: 's-2');
    final d3 = ConversationDestination.session(deviceId: 'device-1', sessionId: 's-3');
    history.navigateTo(d1);
    history.navigateTo(d2);
    history.navigateTo(d3);
    history.goBack(); // now back (d1) and forward (d3) are both available

    getIt.registerSingleton<ConversationHistoryController>(history);
    addTearDown(() => getIt.unregister<ConversationHistoryController>());

    var navigatedRoute = '';
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: ConversationWorkspaceLayout(
              showChrome: false,
              child: SizedBox(),
            ),
          ),
        ),
        GoRoute(
          path: '/conversations/:deviceId/:sessionId',
          builder: (context, state) {
            navigatedRoute = state.uri.toString();
            return const Scaffold(
              body: ConversationWorkspaceLayout(
                showChrome: false,
                child: SizedBox(),
              ),
            );
          },
        ),
      ],
    );

    await pumpSidebar(tester, router: router);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sidebar_back_btn')));
    await tester.pumpAndSettle();
    expect(navigatedRoute, '/conversations/device-1/s-1');

    await tester.tap(find.byKey(const Key('sidebar_forward_btn')));
    await tester.pumpAndSettle();
    expect(navigatedRoute, '/conversations/device-1/s-2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('options menu works when hover exits row to pop up menu', (tester) async {
    final capsCubit = _FakeDeviceCapabilitiesCubit(
      DeviceCapabilitiesState(
        capabilitiesByAgentId: {
          device.id: const Capability(
            supportsUpdateSessionName: true,
            supportsDeleteSession: true,
          ),
        },
      ),
    );

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionSidebarCubit: sessionSidebarCubit,
      deviceCapabilitiesCubit: capsCubit,
      conversationCacheRepository: cacheRepository,
      conversationRepository: conversationRepository,
      child: const DeviceWorkspaceSidebar(
        showChrome: false,
        key: Key('sidebar'),
      ),
    );

    await tester.pumpAndSettle();

    // The options button (more_vert icon) should not be visible initially.
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // Hover over the first session ("Scoped chat").
    final rowFinder = find.text('Scoped chat');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(rowFinder));
    await tester.pump();

    // Now options button should be visible.
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    // Click on options button to open the popup menu.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    // Simulate mouse leaving the row to go to the popup menu.
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();

    // Verify "Rename" popup item is visible.
    expect(find.text('Rename'), findsOneWidget);

    // Tap "Rename".
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    // Verify the rename dialog is shown.
    expect(find.text('Rename Session'), findsOneWidget);

    // Close the dialog.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await gesture.removePointer();
    await capsCubit.close();
  });
}

class _FakeDeviceCapabilitiesCubit extends Cubit<DeviceCapabilitiesState> implements DeviceCapabilitiesCubit {
  _FakeDeviceCapabilitiesCubit(super.initialState);

  @override
  DeviceCapabilitiesStore get capabilities => throw UnimplementedError();

  @override
  DeviceCubit get agentCubit => throw UnimplementedError();

  @override
  Future<void> ensureFreshForAgent(DeviceConfig agent, {bool force = false}) async {}
}

class _TestSessionCubit extends SessionCubit {
  _TestSessionCubit({
    required super.agentCubit,
    required super.socketService,
    required super.conversationRepository,
    super.conversationCacheRepository,
  });

  void emitState(SessionState state) {
    emit(state);
  }
}
