import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_media_loader_resolver.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_search.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_search_cubit.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/device_workspace_sidebar.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/devices/models/device_client.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart' show FakeVoiceStreamCubit;

/// Back/forward navigation integrity across conversations and devices (Plan 103).
///
/// Each test drives the real [HomeScreen] through the real conversation routes,
/// so the route reconciliation, history stacks, sidebar projection, and atomic
/// session swap are exercised together:
/// - Back to a session that is absent from the loaded sidebar pages stays on
///   that session instead of being rewritten to New Conversation.
/// - A device switch is one typed navigation: URL, history, selection, and the
///   presented conversation all describe the new device, and Back/Forward then
///   move predictably across devices.
/// - A New Conversation round-trip keeps Forward enabled and adds exactly one
///   history entry per user navigation.
/// - A genuinely missing session surfaces the failure/retry presentation.
void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit deviceCubit;
  late DeviceCapabilitiesStore capabilities;
  late DeviceConnectionCoordinator resolver;
  late _TestConversationRepository conversationRepository;
  late ConversationCacheStore cacheStore;
  late ConversationCacheRepository cacheRepository;
  late ConversationHistoryController history;
  late ProviderUsageCubit providerUsage;
  late _FakeAuthCubit authCubit;
  late DeviceConfig deviceA;
  late DeviceConfig deviceB;

  const workspace = DeviceWorkspace(id: 'workspace-1', name: 'Project A', path: '/repo/a');

  final sessionA = Session(
    id: 'session-a',
    title: 'Conversation A',
    deviceId: 'device-a',
    workspaceId: workspace.id,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    lastMessageAt: DateTime(2026, 1, 1),
  );
  final sessionB = Session(
    id: 'session-b',
    title: 'Conversation B',
    deviceId: 'device-b',
    createdAt: DateTime(2026, 1, 2),
    updatedAt: DateTime(2026, 1, 2),
    lastMessageAt: DateTime(2026, 1, 2),
  );

  setUp(() async {
    await getIt.reset(dispose: false);

    socket = FakeSanadSocketService()..setConnected(true);
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    deviceCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilities = DeviceCapabilitiesStore(resolver);
    conversationRepository = _TestConversationRepository()..transportReady = true;
    conversationRepository.workspaces.add(workspace);
    conversationRepository.seedSessions(deviceA = _device('device-a', 'Device A'), [sessionA]);
    conversationRepository.seedSessions(deviceB = _device('device-b', 'Device B'), [sessionB]);

    cacheStore = ConversationCacheStore();
    cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );
    cacheStore.applyWorkspacesRefreshed(
      deviceA.id,
      const [workspace],
      generation: cacheStore.advanceWorkspacesGeneration(deviceA.id),
    );
    cacheStore.applySessionCreated(deviceA.id, sessionA);
    cacheStore.applySessionCreated(deviceB.id, sessionB);
    cacheStore.recordLastDestination(
      ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id),
    );
    cacheStore.recordLastDestination(
      ConversationDestination.session(deviceId: deviceB.id, sessionId: sessionB.id),
    );
    cacheStore.setActiveDevice(deviceA.id);

    history = ConversationHistoryController();
    authCubit = _FakeAuthCubit()..emitState(_authenticatedState());

    agentRepository.seedAgents([deviceA, deviceB], activeAgentId: deviceA.id);
    // A device switch resolves through the client registry before it reaches the
    // cache projection; no protocol traffic is issued on this path.
    agentClientRegistry
      ..registerClient(deviceA.id, _InertDeviceClient(deviceA, socket))
      ..registerClient(deviceB.id, _InertDeviceClient(deviceB, socket));
    deviceCubit.emitState(DeviceActive(activeAgent: deviceA, agents: [deviceA, deviceB]));

    getIt
      ..registerSingleton<ConversationRepository>(conversationRepository)
      ..registerSingleton<ConversationCacheRepository>(cacheRepository)
      ..registerSingleton<IDevicePreferencesRepository>(FakeDevicePreferencesRepository())
      ..registerSingleton<ConversationHistoryController>(history)
      ..registerSingleton<DeviceConnectionCoordinator>(resolver)
      ..registerSingleton<DeviceCapabilitiesStore>(capabilities)
      ..registerSingleton<LocalToolRuntimeService>(LocalToolRuntimeService())
      ..registerSingleton<WorkspaceToolRuntimeContext>(WorkspaceToolRuntimeContext())
      ..registerSingleton<ProviderSetupClient>(_FakeProviderSetupClient())
      // The chat pane resolves its byte transport through this resolver, so the
      // harness registers it exactly like `configureDependencies()` does.
      ..registerSingleton<ConversationMediaLoaderResolver>(
        ConversationMediaLoaderResolver(
          cloudSocketService: socket,
          hardwareId: deviceA.id,
        ),
      );
    providerUsage = ProviderUsageCubit(
      localDeviceId: deviceA.id,
      client: _FakeProviderSetupClient(),
    );
    getIt.registerSingleton<ProviderUsageCubit>(providerUsage);
  });

  tearDown(() async {
    await getIt.reset(dispose: false);
    await providerUsage.close();
    await authCubit.close();
    await deviceCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    cacheStore.dispose();
    socket.dispose();
    history.dispose();
  });

  Future<GoRouter> pumpHome(WidgetTester tester, String initialLocation, {Size size = const Size(1400, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final setup = AppRouter.createRouter(
      authCubit,
      initialLocation: initialLocation,
      historyController: history,
    );
    final gatewayCubit = _FakeGatewayConnectionCubit();
    addTearDown(gatewayCubit.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [RepositoryProvider<SanadSocketService>.value(value: socket)],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<DeviceCubit>.value(value: deviceCubit),
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<GatewayConnectionCubit>.value(value: gatewayCubit),
            BlocProvider<DeviceCapabilitiesCubit>(
              create: (_) => DeviceCapabilitiesCubit(
                capabilities: capabilities,
                agentCubit: deviceCubit,
              ),
            ),
            BlocProvider<VoiceStreamCubit>.value(value: FakeVoiceStreamCubit()),
          ],
          child: MaterialApp.router(
            routerConfig: setup.router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: kSupportedLocales,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return setup.router;
  }

  String currentPath(GoRouter router) => router.routeInformationProvider.value.uri.toString();

  SessionCubit sessionCubitOf(WidgetTester tester) =>
      BlocProvider.of<SessionCubit>(tester.element(find.byType(DeviceWorkspaceSidebar)));

  SessionMessagesCubit messagesCubitOf(WidgetTester tester) =>
      BlocProvider.of<SessionMessagesCubit>(tester.element(find.byType(DeviceWorkspaceSidebar)));

  testWidgets('Back to a session outside the loaded pages keeps that session', (tester) async {
    // The evicted session exists as the previous destination but is absent from
    // the device's loaded section, exactly like a session evicted by a section
    // refresh (`_firstPageSize = 6` replaces the whole page).
    const evicted = ConversationDestination.session(deviceId: 'device-a', sessionId: 'session-evicted');
    history
      ..setInitial(evicted)
      ..navigateTo(ConversationDestination.session(deviceId: 'device-a', sessionId: sessionA.id));

    final router = await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));
    expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA.id));

    await tester.tap(find.byKey(const Key('sidebar_back_btn')));
    await tester.pumpAndSettle();

    // The destination is presented as requested, not rewritten.
    expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, 'session-evicted'));
    expect(history.snapshot.current, evicted);
    expect(history.snapshot.current!.isNewConversation, isFalse);
    // Forward was preserved: Back is not a one-way rewrite of the destination.
    expect(history.snapshot.forwardStack, [
      ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id),
    ]);
    // The conversation was actually requested and presented.
    expect(conversationRepository.loadedHistorySessionIds, contains('session-evicted'));
    expect(sessionCubitOf(tester).state.selectedSession?.id, 'session-evicted');
    expect(messagesCubitOf(tester).state.activeSessionId, 'session-evicted');
    expect(messagesCubitOf(tester).state.visualState.isNewConversation, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A genuinely missing session surfaces the failure presentation with retry', (tester) async {
    conversationRepository.failingHistorySessionIds.add('session-evicted');
    const evicted = ConversationDestination.session(deviceId: 'device-a', sessionId: 'session-evicted');
    history
      ..setInitial(evicted)
      ..navigateTo(ConversationDestination.session(deviceId: 'device-a', sessionId: sessionA.id));

    final router = await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));

    await tester.tap(find.byKey(const Key('sidebar_back_btn')));
    await tester.pumpAndSettle();

    expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, 'session-evicted'));
    expect(history.snapshot.current, evicted);
    expect(history.snapshot.current!.isNewConversation, isFalse);
    expect(find.byKey(const Key('retry_history_load_button')), findsOneWidget);
    expect(find.text('Could not load this conversation.'), findsOneWidget);
    expect(messagesCubitOf(tester).state.historyLoadError, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed history load is re-issued once the transport delivers again (Task 124 D2)', (tester) async {
    conversationRepository.failingHistorySessionIds.add(sessionA.id);
    history.setInitial(ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id));
    await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));
    expect(find.byKey(const Key('retry_history_load_button')), findsOneWidget);
    final attempts = conversationRepository.loadedHistorySessionIds.where((id) => id == sessionA.id).length;

    // The disconnect ends; the reconnect re-sync lands the device's history in
    // the store, which publishes it.
    conversationRepository.failingHistorySessionIds.clear();
    conversationRepository.setMessages(deviceA, const <CanonicalEvent>[]);
    await tester.pumpAndSettle();

    expect(
      conversationRepository.loadedHistorySessionIds.where((id) => id == sessionA.id).length,
      attempts + 1,
    );
    expect(find.byKey(const Key('retry_history_load_button')), findsNothing);
    expect(messagesCubitOf(tester).state.historyLoadError, isNull);
    expect(messagesCubitOf(tester).state.activeSessionId, sessionA.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact New Conversation context chips never overflow (Task 124 D3)', (tester) async {
    final longDevice = deviceA.copyWith(name: 'A device with a very long name that does not fit a phone');
    agentRepository.seedAgents([longDevice, deviceB], activeAgentId: longDevice.id);
    agentClientRegistry.registerClient(longDevice.id, _InertDeviceClient(longDevice, socket));
    deviceCubit.emitState(DeviceActive(activeAgent: longDevice, agents: [longDevice, deviceB]));
    const start = ConversationDestination.newConversation(deviceId: 'device-a', workspaceId: 'workspace-1');
    history.setInitial(start);

    await pumpHome(tester, start.routePath, size: const Size(420, 900));

    expect(tester.takeException(), isNull);
  });

  testWidgets('Device switch makes URL, history, selection, and presentation agree', (tester) async {
    history.setInitial(ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id));

    final router = await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));

    await tester.tap(find.byKey(const Key('sidebar_device_switcher_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar_device_item_Device B')));
    await tester.pumpAndSettle();

    final deviceBSession = ConversationDestination.session(deviceId: deviceB.id, sessionId: sessionB.id);
    expect((deviceCubit.state as DeviceActive).activeAgent.id, deviceB.id);
    expect(cacheRepository.activeDeviceId, deviceB.id);
    expect(currentPath(router), deviceBSession.routePath);
    expect(history.snapshot.current, deviceBSession);
    expect(history.snapshot.backStack, [
      ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id),
    ]);
    expect(sessionCubitOf(tester).state.selectedSession?.deviceId, deviceB.id);
    expect(sessionCubitOf(tester).state.selectedSession?.id, sessionB.id);
    expect(messagesCubitOf(tester).state.activeSessionId, sessionB.id);
    // The sidebar now projects the new device's conversations only.
    expect(find.byKey(ValueKey('sidebar_session_title:${sessionB.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('sidebar_session_title:${sessionA.id}')), findsNothing);

    // Back crosses devices deterministically and is visible in the URL.
    await tester.tap(find.byKey(const Key('sidebar_back_btn')));
    await tester.pumpAndSettle();

    expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA.id));
    expect(history.snapshot.current?.deviceId, deviceA.id);
    expect(history.snapshot.current?.sessionId, sessionA.id);
    expect(sessionCubitOf(tester).state.selectedSession?.id, sessionA.id);
    expect(messagesCubitOf(tester).state.activeSessionId, sessionA.id);
    expect(history.snapshot.forwardStack, [deviceBSession]);
    expect(find.byKey(ValueKey('sidebar_session_title:${sessionA.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('sidebar_session_title:${sessionB.id}')), findsNothing);

    await tester.tap(find.byKey(const Key('sidebar_forward_btn')));
    await tester.pumpAndSettle();

    expect(currentPath(router), deviceBSession.routePath);
    expect(history.snapshot.current, deviceBSession);
    expect(history.snapshot.forwardStack, isEmpty);
    expect(sessionCubitOf(tester).state.selectedSession?.id, sessionB.id);
    expect(messagesCubitOf(tester).state.activeSessionId, sessionB.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('New Conversation round-trip keeps Forward and adds one entry per navigation', (tester) async {
    history.setInitial(ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id));
    final router = await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));

    await tester.tap(find.byKey(const Key('sidebar_new_session_btn')));
    await tester.pumpAndSettle();

    // The resolver restores the device's workspace context, and the route uses
    // the resolved destination instead of a workspace-less location.
    const newConversation = ConversationDestination.newConversation(
      deviceId: 'device-a',
      workspaceId: 'workspace-1',
    );
    expect(currentPath(router), newConversation.routePath);
    expect(history.snapshot.current, newConversation);
    expect(cacheRepository.newConversationDraft(deviceA.id).workspaceId, workspace.id);
    expect(history.snapshot.backStack, [
      ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id),
    ]);
    expect(history.snapshot.forwardStack, isEmpty);

    await tester.tap(find.byKey(const Key('sidebar_back_btn')));
    await tester.pumpAndSettle();

    expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA.id));
    expect(history.snapshot.forwardStack, [newConversation]);
    expect(history.snapshot.backStack, isEmpty);

    await tester.tap(find.byKey(const Key('sidebar_forward_btn')));
    await tester.pumpAndSettle();

    expect(currentPath(router), newConversation.routePath);
    expect(history.snapshot.current, newConversation);
    // Exactly one entry per user navigation: the round-trip did not accumulate
    // duplicate New Conversation identities.
    expect(history.snapshot.backStack, [
      ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id),
    ]);
    expect(history.snapshot.forwardStack, isEmpty);
    expect(tester.takeException(), isNull);
  });

  group('search result then New Conversation (Task 124 item 4)', () {
    Future<void> settleFrames(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> openSearchHit(
      WidgetTester tester,
      Session session, {
      String? anchorEventId,
      bool settle = true,
    }) async {
      conversationRepository.searchSessionsHandler = (agent, query, cursor) async => SessionSearchPage(
        hits: [
          SessionSearchHit(
            session: session,
            matchKind: SessionSearchMatchKind.content,
            snippet: 'match',
            anchorEventId: anchorEventId,
          ),
        ],
        hasMore: false,
      );
      await tester.tap(find.byKey(const Key('conversation_search_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('conversation_search_field')), 'match');
      await tester.pump(SessionSearchCubit.debounceDuration);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('conversation_search_result:${session.id}')));
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await settleFrames(tester);
      }
    }

    for (final (anchored, startNew, cached) in [
      (false, false, true),
      (true, false, true),
      (false, true, true),
      (true, true, true),
      (true, true, false),
      (false, true, false),
    ]) {
      testWidgets('New Conversation still navigates after opening a search result '
          '(anchored: $anchored, from new: $startNew, cached: $cached)', (
        tester,
      ) async {
        final sessionA2 = Session(
          id: 'session-a2',
          title: 'Conversation A2',
          deviceId: deviceA.id,
          workspaceId: workspace.id,
          createdAt: DateTime(2026, 1, 3),
          updatedAt: DateTime(2026, 1, 3),
          lastMessageAt: DateTime(2026, 1, 3),
        );
        conversationRepository.seedSessions(deviceA, [sessionA, sessionA2]);
        if (cached) cacheStore.applySessionCreated(deviceA.id, sessionA2);
        final GoRouter router;
        if (startNew) {
          const start = ConversationDestination.newConversation(deviceId: 'device-a', workspaceId: 'workspace-1');
          history.setInitial(start);
          router = await pumpHome(tester, start.routePath);
        } else {
          history.setInitial(ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id));
          router = await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));
        }

        await openSearchHit(tester, sessionA2, anchorEventId: anchored ? 'event-1' : null);
        expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA2.id));
        expect(sessionCubitOf(tester).state.selectedSession?.id, sessionA2.id);

        await tester.tap(find.byKey(const Key('sidebar_new_session_btn')));
        await tester.pumpAndSettle();

        const newConversation = ConversationDestination.newConversation(
          deviceId: 'device-a',
          workspaceId: 'workspace-1',
        );
        expect(currentPath(router), newConversation.routePath);
        expect(history.snapshot.current, newConversation);
        expect(sessionCubitOf(tester).state.selectedSession, isNull);
        expect(messagesCubitOf(tester).state.visualState.isNewConversation, isTrue);

        // Navigation keeps working afterwards.
        await tester.tap(find.byKey(ValueKey('sidebar_session_title:${sessionA.id}')));
        await tester.pumpAndSettle();
        expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA.id));
        expect(sessionCubitOf(tester).state.selectedSession?.id, sessionA.id);
        expect(tester.takeException(), isNull);
      });
    }

    for (final anchor in [null, 'event-1']) {
      testWidgets('New Conversation still navigates after opening a search result for the open session ($anchor)', (
        tester,
      ) async {
        history.setInitial(ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id));
        final router = await pumpHome(tester, AppRoutes.sessionLocation(deviceA.id, sessionA.id));

        await openSearchHit(tester, sessionA, anchorEventId: anchor);
        expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA.id));

        await tester.tap(find.byKey(const Key('sidebar_new_session_btn')));
        await tester.pumpAndSettle();

        const newConversation = ConversationDestination.newConversation(
          deviceId: 'device-a',
          workspaceId: 'workspace-1',
        );
        expect(currentPath(router), newConversation.routePath);
        expect(history.snapshot.current, newConversation);
        expect(sessionCubitOf(tester).state.selectedSession, isNull);
        expect(tester.takeException(), isNull);
      });
    }

    for (final (button, expected) in [
      (
        'sidebar_new_conversation_btn:workspace-1',
        const ConversationDestination.newConversation(deviceId: 'device-a', workspaceId: 'workspace-1'),
      ),
    ]) {
      for (final startNew in [false, true]) {
        testWidgets('$button navigates after a search result (from new: $startNew)', (tester) async {
          final sessionA2 = Session(
            id: 'session-a2',
            title: 'Conversation A2',
            deviceId: deviceA.id,
            workspaceId: workspace.id,
            createdAt: DateTime(2026, 1, 3),
            updatedAt: DateTime(2026, 1, 3),
            lastMessageAt: DateTime(2026, 1, 3),
          );
          conversationRepository.seedSessions(deviceA, [sessionA, sessionA2]);
          cacheStore.applySessionCreated(deviceA.id, sessionA2);
          final start = startNew
              ? expected
              : ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id);
          history.setInitial(start);
          final router = await pumpHome(tester, start.routePath);

          await openSearchHit(tester, sessionA2, anchorEventId: 'event-1');
          expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA2.id));

          await tester.tap(find.byKey(Key(button)));
          await tester.pumpAndSettle();

          expect(currentPath(router), expected.routePath);
          expect(history.snapshot.current, expected);
          expect(sessionCubitOf(tester).state.selectedSession, isNull);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('New Conversation navigates while the search result history is still loading', (tester) async {
      final sessionA2 = Session(
        id: 'session-a2',
        title: 'Conversation A2',
        deviceId: deviceA.id,
        workspaceId: workspace.id,
        createdAt: DateTime(2026, 1, 3),
        updatedAt: DateTime(2026, 1, 3),
        lastMessageAt: DateTime(2026, 1, 3),
      );
      conversationRepository.seedSessions(deviceA, [sessionA, sessionA2]);
      cacheStore.applySessionCreated(deviceA.id, sessionA2);
      final pendingHistory = Completer<List<CanonicalEvent>>();
      conversationRepository.loadAnchoredHistoryHandler = (agent, sessionId, anchor) => pendingHistory.future;
      const start = ConversationDestination.newConversation(deviceId: 'device-a', workspaceId: 'workspace-1');
      history.setInitial(start);
      final router = await pumpHome(tester, start.routePath);

      await openSearchHit(tester, sessionA2, anchorEventId: 'event-1', settle: false);
      expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA2.id));

      await tester.tap(find.byKey(const Key('sidebar_new_session_btn')));
      await settleFrames(tester);
      expect(currentPath(router), start.routePath);
      pendingHistory.complete(const <CanonicalEvent>[]);
      await tester.pumpAndSettle();

      expect(currentPath(router), start.routePath);
      expect(history.snapshot.current, start);
      expect(sessionCubitOf(tester).state.selectedSession, isNull);
      expect(messagesCubitOf(tester).state.visualState.isNewConversation, isTrue);

      await tester.tap(find.byKey(ValueKey('sidebar_session_title:${sessionA2.id}')));
      await tester.pumpAndSettle();
      expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA2.id));
      expect(tester.takeException(), isNull);
    });

    testWidgets('drawer: New Conversation still navigates after opening a search result', (tester) async {
      final sessionA2 = Session(
        id: 'session-a2',
        title: 'Conversation A2',
        deviceId: deviceA.id,
        workspaceId: workspace.id,
        createdAt: DateTime(2026, 1, 3),
        updatedAt: DateTime(2026, 1, 3),
        lastMessageAt: DateTime(2026, 1, 3),
      );
      conversationRepository.seedSessions(deviceA, [sessionA, sessionA2]);
      cacheStore.applySessionCreated(deviceA.id, sessionA2);
      history.setInitial(ConversationDestination.session(deviceId: deviceA.id, sessionId: sessionA.id));
      final router = await pumpHome(
        tester,
        AppRoutes.sessionLocation(deviceA.id, sessionA.id),
        size: const Size(600, 1000),
      );
      ScaffoldState scaffold() => tester.state<ScaffoldState>(find.byType(Scaffold).first);

      scaffold().openDrawer();
      await tester.pumpAndSettle();
      await openSearchHit(tester, sessionA2, anchorEventId: 'event-1');
      expect(currentPath(router), AppRoutes.sessionLocation(deviceA.id, sessionA2.id));
      expect(scaffold().isDrawerOpen, isFalse);

      scaffold().openDrawer();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sidebar_new_session_btn')));
      await tester.pumpAndSettle();

      const newConversation = ConversationDestination.newConversation(
        deviceId: 'device-a',
        workspaceId: 'workspace-1',
      );
      expect(currentPath(router), newConversation.routePath);
      expect(history.snapshot.current, newConversation);
      expect(
        BlocProvider.of<SessionCubit>(tester.element(find.byType(Scaffold).first)).state.selectedSession,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('remembered device fallback through Home (Task 124 D1)', () {
    testWidgets('an automatic Home restore during the fallback keeps and later restores the remembered device', (
      tester,
    ) async {
      final local = DeviceConfig(id: 'hw-local', name: 'This device', hardwareId: 'hw-local', isOnline: true);
      final localSession = Session(
        id: 'session-local',
        title: 'Local conversation',
        deviceId: local.id,
        createdAt: DateTime(2026, 1, 4),
        updatedAt: DateTime(2026, 1, 4),
        lastMessageAt: DateTime(2026, 1, 4),
      );
      conversationRepository.seedSessions(local, [localSession]);
      cacheStore.applySessionCreated(local.id, localSession);
      cacheStore.recordLastDestination(
        ConversationDestination.session(deviceId: local.id, sessionId: localSession.id),
      );
      agentClientRegistry.registerClient(local.id, _InertDeviceClient(local, socket));

      // Remembered cloud device A, but no cloud inventory can arrive.
      agentRepository.seedAgents([local], activeAgentId: deviceA.id);
      agentRepository.cloudInventoryPending = false;
      await deviceCubit.init();
      expect((deviceCubit.state as DeviceActive).activeAgent.id, local.id);

      // Cold start with no route: Home restores the fallback device's last
      // destination on its own.
      final router = await pumpHome(tester, AppRoutes.home);
      expect(currentPath(router), AppRoutes.sessionLocation(local.id, localSession.id));
      expect(agentRepository.getActiveAgentId(), deviceA.id, reason: 'an automatic restore is not a user pick');

      // The cloud inventory returns with A: the remembered device is restored.
      agentRepository.cloudInventoryPending = true;
      agentRepository.seedAgents([local, deviceA, deviceB], activeAgentId: deviceA.id);
      agentRepository.emitAgentsUpdate();
      await tester.pumpAndSettle();
      expect((deviceCubit.state as DeviceActive).activeAgent.id, deviceA.id);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a user-opened route during the fallback replaces the remembered device', (tester) async {
      final local = DeviceConfig(id: 'hw-local', name: 'This device', hardwareId: 'hw-local', isOnline: true);
      final localSession = Session(
        id: 'session-local',
        title: 'Local conversation',
        deviceId: local.id,
        createdAt: DateTime(2026, 1, 4),
        updatedAt: DateTime(2026, 1, 4),
        lastMessageAt: DateTime(2026, 1, 4),
      );
      final otherLocal = localSession.copyWith(id: 'session-local-2', title: 'Other local');
      conversationRepository.seedSessions(local, [localSession, otherLocal]);
      cacheStore.applySessionCreated(local.id, localSession);
      cacheStore.applySessionCreated(local.id, otherLocal);
      cacheStore.recordLastDestination(
        ConversationDestination.session(deviceId: local.id, sessionId: localSession.id),
      );
      agentClientRegistry.registerClient(local.id, _InertDeviceClient(local, socket));
      agentRepository.seedAgents([local], activeAgentId: deviceA.id);
      agentRepository.cloudInventoryPending = false;
      await deviceCubit.init();

      final router = await pumpHome(tester, AppRoutes.home);
      expect(agentRepository.getActiveAgentId(), deviceA.id);
      await tester.tap(find.byKey(ValueKey('sidebar_session_title:${otherLocal.id}')));
      await tester.pumpAndSettle();
      expect(currentPath(router), AppRoutes.sessionLocation(local.id, otherLocal.id));
      expect(agentRepository.getActiveAgentId(), local.id);

      // The user's pick wins over the remembered device when cloud returns.
      agentRepository.cloudInventoryPending = true;
      agentRepository.seedAgents([local, deviceA, deviceB], activeAgentId: local.id);
      agentRepository.emitAgentsUpdate();
      await tester.pumpAndSettle();
      expect((deviceCubit.state as DeviceActive).activeAgent.id, local.id);
      expect(tester.takeException(), isNull);
    });
  });
}

DeviceConfig _device(String id, String name) => DeviceConfig(id: id, name: name, isOnline: true);

AuthAuthenticated _authenticatedState() => const AuthAuthenticated(
  username: 'ahmed',
  email: 'ahmed@example.com',
  userId: 'user-1',
  accessToken: 'token',
  userCredits: 0,
  totalCredits: 0,
);

/// [FakeConversationRepository] with a switch to fail history loads, standing in
/// for a session the daemon genuinely does not have.
class _TestConversationRepository extends FakeConversationRepository {
  final Set<String> failingHistorySessionIds = <String>{};

  @override
  Future<List<CanonicalEvent>> loadSessionHistory(DeviceConfig agent, String sessionId) async {
    if (failingHistorySessionIds.contains(sessionId)) {
      throw StateError('session_not_found: $sessionId');
    }
    return super.loadSessionHistory(agent, sessionId);
  }
}

class _FakeProviderSetupClient extends Fake implements ProviderSetupClient {
  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) async =>
      const ProviderReadinessDto(hasProvider: true, runtimeReady: true);
}

/// A registered client only proves that a device can be switched to; the
/// navigation path issues no protocol traffic.
class _InertDeviceClient implements DeviceClient {
  _InertDeviceClient(this.config, this.controller);

  @override
  final DeviceConfig config;

  @override
  final SanadSocketService controller;

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  bool get isConnected => false;

  @override
  void sendCommand({required String command, Map<String, dynamic>? payload}) {}

  @override
  Future<Map<String, dynamic>?> request({
    required String command,
    required Map<String, dynamic> payload,
    required String requestId,
    Duration timeout = const Duration(seconds: 10),
  }) async => null;

  @override
  void dispose() {}
}

class _FakeAuthCubit extends AuthCubit {
  _FakeAuthCubit() : super(authRepository: _FakeAuthRepository());

  final StreamController<AuthState> _stateController = StreamController<AuthState>.broadcast();
  AuthState _state = AuthUnauthenticated();

  @override
  AuthState get state => _state;

  @override
  Stream<AuthState> get stream => _stateController.stream;

  void emitState(AuthState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  @override
  Future<void> close() async {
    await _stateController.close();
    return super.close();
  }
}

class _FakeAuthRepository implements IAuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The window status bar reads only gateway state; no probe or action is
/// exercised by these navigation tests.
class _FakeGatewayConnectionCubit extends Fake implements GatewayConnectionCubit {
  final StreamController<GatewayConnectionStatus> _controller = StreamController<GatewayConnectionStatus>.broadcast();

  @override
  GatewayConnectionStatus get state => const GatewayConnectionStatus.initial();

  @override
  Stream<GatewayConnectionStatus> get stream => _controller.stream;

  void dispose() => unawaited(_controller.close());
}
