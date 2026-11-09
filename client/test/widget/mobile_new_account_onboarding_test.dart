// New-account onboarding on the mobile layout (Task 152).
//
// The owner's phone review found four blockers on the first screen a brand-new
// account sees. Each group below pins one of them at a phone viewport
// (390x844) and, where the rule is shared, at a desktop viewport (1400x1000):
//
// 1. a zero-device mobile surface with no side menu (and therefore no route to
//    Settings -> Profile -> Sign out);
// 2. a created device jumping to Home instead of the install page;
// 3. a composer model/provider picker that disappears while the device has no
//    capability snapshot (exactly the fresh-device case);
// 4. the provider-setup gate and the usable new conversation behind it.
//
// The tests drive the real router, `OnboardingSetupScreen`, `AddDeviceScreen`,
// `HomeScreen`, and the composer with fake auth/device/provider state. The
// mobile cases set `AppPlatform.overrideIsDesktop/overrideIsMobile` because a
// widget test hosted on macOS otherwise reports a desktop platform.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_media_loader_resolver.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart' show FakeVoiceStreamCubit;

const _phone = Size(390, 844);
const _desktop = Size(1400, 1000);

/// A signed-in cloud gateway, the state in which creating a device is allowed.
const _cloudReadyGateway = GatewayConnectionStatus(
  localGateway: LocalGatewayStatus.disconnected,
  sanadGateway: SanadGatewayStatus.authenticatedNoDevices,
  actions: [],
  recommendedRoute: AppRoutes.onboarding,
  isDesktop: false,
);

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit deviceCubit;
  late DeviceCapabilitiesStore capabilities;
  late DeviceConnectionCoordinator resolver;
  late FakeConversationRepository conversationRepository;
  late ConversationCacheStore cacheStore;
  late ConversationCacheRepository cacheRepository;
  late ConversationHistoryController history;
  late ProviderUsageCubit providerUsage;
  late _FakeAuthCubit authCubit;
  late _FakeProviderClient providerClient;

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
    conversationRepository = FakeConversationRepository()..transportReady = true;
    cacheStore = ConversationCacheStore();
    cacheRepository = ConversationCacheRepository(cache: cacheStore, transport: conversationRepository);
    history = ConversationHistoryController();
    authCubit = _FakeAuthCubit()..emitState(_authenticatedState());
    providerClient = _FakeProviderClient();

    getIt
      ..registerSingleton<ConversationRepository>(conversationRepository)
      ..registerSingleton<ConversationCacheRepository>(cacheRepository)
      ..registerSingleton<IDevicePreferencesRepository>(FakeDevicePreferencesRepository())
      ..registerSingleton<ConversationHistoryController>(history)
      ..registerSingleton<DeviceConnectionCoordinator>(resolver)
      ..registerSingleton<DeviceCapabilitiesStore>(capabilities)
      ..registerSingleton<LocalToolRuntimeService>(LocalToolRuntimeService())
      ..registerSingleton<WorkspaceToolRuntimeContext>(WorkspaceToolRuntimeContext())
      ..registerSingleton<ProviderSetupClient>(providerClient)
      ..registerSingleton<AccountLifecycleRepository>(_FakeAccountLifecycleRepository())
      ..registerSingleton<ConversationMediaLoaderResolver>(
        ConversationMediaLoaderResolver(cloudSocketService: socket, hardwareId: 'device-a'),
      );
    providerUsage = ProviderUsageCubit(localDeviceId: 'device-a', client: providerClient);
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
    AppPlatform.overrideIsDesktop = null;
    AppPlatform.overrideIsMobile = null;
  });

  void usePhone() {
    AppPlatform.overrideIsDesktop = false;
    AppPlatform.overrideIsMobile = true;
  }

  void useDesktop() {
    AppPlatform.overrideIsDesktop = true;
    AppPlatform.overrideIsMobile = false;
  }

  Future<GoRouter> pumpApp(
    WidgetTester tester,
    String initialLocation, {
    required Size size,
    GatewayConnectionStatus? gateway,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final setup = AppRouter.createRouter(authCubit, initialLocation: initialLocation, historyController: history);
    final gatewayCubit = _FakeGatewayConnectionCubit(gateway ?? const GatewayConnectionStatus.initial());
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
              create: (_) => DeviceCapabilitiesCubit(capabilities: capabilities, agentCubit: deviceCubit),
            ),
            BlocProvider<VoiceStreamCubit>.value(value: FakeVoiceStreamCubit()),
            BlocProvider<AppearanceCubit>.value(value: _FakeAppearanceCubit()),
          ],
          child: MaterialApp.router(
            routerConfig: setup.router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: kSupportedLocales,
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A device-less Home keeps an indeterminate spinner alive, so it can never
      // settle; bounded pumps are enough to observe a redirect away from it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }
    return setup.router;
  }

  /// The live location including imperative `push` pages: `push` does not
  /// update `routeInformationProvider`, so the delegate's configuration is the
  /// authority for "where is the user now".
  String pathOf(GoRouter router) => router.routerDelegate.currentConfiguration.uri.toString();

  /// Drains layout exceptions the surface under test is not asserting about, so
  /// one unrelated overflow cannot fail an unrelated case.
  void drainExceptions(WidgetTester tester) {
    while (tester.takeException() != null) {}
  }

  void emitDevice(DeviceConfig device) {
    agentRepository.seedAgents([device], activeAgentId: device.id);
    deviceCubit.emitState(DeviceActive(activeAgent: device, agents: [device]));
  }

  group('defect 1 — a zero-device mobile surface always offers the side menu', () {
    testWidgets('phone: the menu opens the drawer and Profile reaches Sign out', (tester) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(tester, AppRoutes.onboarding, size: _phone);

      // The zero-device surface is the onboarding route, and it must carry the
      // same menu affordance Home already has.
      expect(pathOf(router), AppRoutes.onboarding);
      expect(find.byKey(const Key('nav_menu_btn')), findsOneWidget);

      await tester.tap(find.byKey(const Key('nav_menu_btn')));
      await tester.pumpAndSettle();

      // The drawer is the existing side menu, not a new sign-out surface.
      expect(find.byKey(const Key('sidebar_profile_destination')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sidebar_profile_destination')));
      await tester.pumpAndSettle();

      // Profile is where an account signs out; the action is the existing one,
      // reached through the existing side menu.
      expect(find.byKey(const ValueKey('sign_out_btn')), findsOneWidget);
    });

    testWidgets('desktop: onboarding keeps its local-first card and gains no drawer', (tester) async {
      useDesktop();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(tester, AppRoutes.onboarding, size: _desktop);

      expect(pathOf(router), AppRoutes.onboarding);
      expect(find.byKey(const Key('onboarding_run_locally')), findsOneWidget);
      expect(find.byKey(const Key('nav_menu_btn')), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.drawer, isNull);
    });

    testWidgets('phone: the zero-device card fits a phone width without overflowing', (tester) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      await pumpApp(tester, AppRoutes.onboarding, size: _phone);

      expect(tester.takeException(), isNull);
    });
  });

  group('defect 1 — the Settings deep link resolves without a device', () {
    for (final entry in <(String, Size, void Function())>[
      ('phone', _phone, usePhone),
      ('desktop', _desktop, useDesktop),
    ]) {
      testWidgets('${entry.$1}: ?section=profile opens Profile with zero devices', (tester) async {
        entry.$3();
        deviceCubit.emitState(const DeviceNoActive(agents: []));

        await pumpApp(tester, '${AppRoutes.settings}?section=profile', size: entry.$2);

        expect(find.byKey(const ValueKey('sign_out_btn')), findsOneWidget);
        // A wide layout keeps the navigation column visible and marks Profile
        // selected; a compact layout hosts it in the closed drawer.
        if (entry.$1 == 'desktop') {
          expect(find.byKey(const Key('nav_tile_profile')), findsWidgets);
        }
      });
    }
  });

  group('defect 2 — creating a device lands on, and stays on, the install page', () {
    testWidgets('phone: the post-create install page stays until the user leaves it', (tester) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(
        tester,
        AppRoutes.onboarding,
        size: _phone,
        gateway: _cloudReadyGateway,
      );

      await tester.tap(find.byKey(const Key('onboarding_remote_action')));
      await tester.pumpAndSettle();
      expect(find.text('Add Host Device'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), 'My Server');
      await tester.pump();
      await tester.tap(find.text('Create Host Device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drainExceptions(tester);

      // The authoritative inventory reports the created device, not yet online.
      emitDevice(DeviceConfig(id: 'device-new', name: 'My Server', token: 'pair-token-123', isOnline: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drainExceptions(tester);

      // The install page still owns the screen, and the conversation surface it
      // was wrongly replaced with is absent.
      expect(find.text('Continue to Home'), findsOneWidget);
      expect(find.textContaining('pair-token-123'), findsWidgets);
      expect(find.byKey(const Key('chat_input')), findsNothing);
      expect(pathOf(router), isNot(contains('/conversations/')));
    });

    testWidgets('phone: the created device coming online continues to Home', (tester) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(
        tester,
        AppRoutes.onboarding,
        size: _phone,
        gateway: _cloudReadyGateway,
      );

      await tester.tap(find.byKey(const Key('onboarding_remote_action')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'My Server');
      await tester.pump();
      await tester.tap(find.text('Create Host Device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drainExceptions(tester);
      emitDevice(DeviceConfig(id: 'device-new', name: 'My Server', token: 'pair-token-123', isOnline: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drainExceptions(tester);

      // The documented completion: the device actually connects.
      emitDevice(DeviceConfig(id: 'device-new', name: 'My Server', token: 'pair-token-123', isOnline: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      drainExceptions(tester);

      expect(pathOf(router), AppRoutes.newConversationLocation('device-new'));

      // The "connected" toast owns a dismiss timer; let it retire so the test
      // ends with a clean timer set.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('desktop: a created device never moves a pushed install page', (tester) async {
      useDesktop();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      await pumpApp(
        tester,
        AppRoutes.addAgent,
        size: _desktop,
        gateway: _cloudReadyGateway,
      );

      await tester.enterText(find.byType(TextFormField), 'My Server');
      await tester.pump();
      await tester.tap(find.text('Create Host Device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drainExceptions(tester);
      emitDevice(DeviceConfig(id: 'device-new', name: 'My Server', token: 'pair-token-123', isOnline: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drainExceptions(tester);

      expect(find.text('Continue to Home'), findsOneWidget);
      expect(find.textContaining('pair-token-123'), findsWidgets);
    });

    testWidgets('phone: the add-device header fits a phone width', (tester) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      await pumpApp(tester, AppRoutes.addAgent, size: _phone);

      expect(tester.takeException(), isNull);
    });
  });

  group('defect 3 — the model/provider picker is always available', () {
    for (final entry in <(String, Size, void Function())>[
      ('phone', _phone, usePhone),
      ('desktop', _desktop, useDesktop),
    ]) {
      testWidgets('${entry.$1}: visible with no capability snapshot and opens an empty picker with Settings', (
        tester,
      ) async {
        entry.$3();
        emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: true));

        await pumpApp(tester, AppRoutes.home, size: entry.$2);
        drainExceptions(tester);

        // No capability snapshot for this device yet: the default capability is
        // all-false, and the picker must still be there.
        expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);

        await tester.tap(find.byKey(const Key('model_selector_btn')));
        await tester.pumpAndSettle();
        drainExceptions(tester);

        expect(find.text('No configured providers'), findsOneWidget);
        expect(find.byKey(const Key('model_picker_settings_btn')), findsOneWidget);
      });
    }
  });

  group('defect D-1 — Settings never strands a zero-device account', () {
    testWidgets('phone: back from Settings with zero devices returns to the zero-device surface', (
      tester,
    ) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(tester, '${AppRoutes.settings}?section=profile', size: _phone);

      await tester.tap(find.byKey(const Key('settings_back_to_conversations_btn')));
      await tester.pumpAndSettle();

      // The live iOS pass landed here on `/home`: a device-less composer with no
      // route back to "Add a Remote Device".
      expect(pathOf(router), AppRoutes.onboarding);
      expect(find.byKey(const Key('onboarding_remote_action')), findsOneWidget);
      expect(find.byKey(const Key('chat_input')), findsNothing);
    });

    testWidgets('phone: back from Settings with a device still returns to Home', (tester) async {
      usePhone();
      emitDevice(DeviceConfig(id: 'device-a', name: 'Phone', isOnline: true));

      final router = await pumpApp(tester, '${AppRoutes.settings}?section=profile', size: _phone);

      await tester.tap(find.byKey(const Key('settings_back_to_conversations_btn')));
      await tester.pumpAndSettle();
      drainExceptions(tester);

      // Unchanged for an account with a device: Home's own surface, which may
      // auto-route into that device's new conversation.
      expect(pathOf(router), isNot(AppRoutes.onboarding));
      expect(find.byKey(const Key('onboarding_remote_action')), findsNothing);
    });

    testWidgets('phone: landing on Home with zero devices returns to the zero-device surface', (
      tester,
    ) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(tester, AppRoutes.home, size: _phone, settle: false);
      drainExceptions(tester);

      expect(pathOf(router), AppRoutes.onboarding);
      expect(find.byKey(const Key('onboarding_remote_action')), findsOneWidget);
    });

    testWidgets('phone: a pending inventory never bounces Home to onboarding', (tester) async {
      usePhone();
      deviceCubit.emitState(const DeviceNoActive(agents: [], isLoadingFromBackend: true));

      final router = await pumpApp(tester, AppRoutes.home, size: _phone, settle: false);
      drainExceptions(tester);

      // An account with devices passes through this state on every cold start.
      expect(pathOf(router), AppRoutes.home);
    });

    testWidgets('desktop: back from Settings with zero devices keeps the Home landing', (tester) async {
      useDesktop();
      deviceCubit.emitState(const DeviceNoActive(agents: []));

      final router = await pumpApp(tester, '${AppRoutes.settings}?section=profile', size: _desktop);

      await tester.tap(find.byKey(const Key('settings_back_to_conversations_btn')));
      await tester.pumpAndSettle();
      drainExceptions(tester);

      // Desktop keeps its local-first Home; the zero-device rule is mobile-only.
      expect(pathOf(router), AppRoutes.home);
    });
  });

  group('defect 4 — provider setup on a fresh online device', () {
    testWidgets('phone: an online device without a provider opens the gate', (tester) async {
      usePhone();
      providerClient.readiness = const ProviderReadinessDto(hasProvider: false, runtimeReady: false);
      emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: true));

      await pumpApp(tester, AppRoutes.home, size: _phone);

      expect(find.byKey(const Key('provider_setup_gate')), findsOneWidget);
      expect(find.text('Provider setup required'), findsOneWidget);
    });

    testWidgets('phone: the dismissed gate leaves a usable new conversation', (tester) async {
      usePhone();
      providerClient.readiness = const ProviderReadinessDto(hasProvider: false, runtimeReady: false);
      emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: true));

      await pumpApp(tester, AppRoutes.home, size: _phone);
      expect(find.byKey(const Key('provider_setup_gate')), findsOneWidget);

      await tester.tap(find.byKey(const Key('provider_setup_gate_close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('provider_setup_gate')), findsNothing);
      // The conversation is usable: the picker is present and a message can be
      // sent.
      expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
      await tester.pump();
      final send = tester.widget<IconButton>(find.byKey(const Key('send_message_btn')));
      expect(send.onPressed, isNotNull);
    });

    testWidgets('desktop: an online device without a provider opens the gate', (tester) async {
      useDesktop();
      providerClient.readiness = const ProviderReadinessDto(hasProvider: false, runtimeReady: false);
      emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: true));

      await pumpApp(tester, AppRoutes.home, size: _desktop);

      expect(find.byKey(const Key('provider_setup_gate')), findsOneWidget);
    });

    testWidgets('a configured runtime never opens the gate', (tester) async {
      usePhone();
      providerClient.readiness = const ProviderReadinessDto(hasProvider: true, runtimeReady: true);
      emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: true));

      await pumpApp(tester, AppRoutes.home, size: _phone);

      expect(find.byKey(const Key('provider_setup_gate')), findsNothing);
      expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);
    });

    testWidgets('an offline device never opens the gate', (tester) async {
      usePhone();
      providerClient.readiness = const ProviderReadinessDto(hasProvider: false, runtimeReady: false);
      emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: false));

      await pumpApp(tester, AppRoutes.home, size: _phone);

      expect(find.byKey(const Key('provider_setup_gate')), findsNothing);
    });

    testWidgets('a readiness failure never opens the gate', (tester) async {
      usePhone();
      providerClient.readinessError = StateError('transport unavailable');
      emitDevice(DeviceConfig(id: 'device-a', name: 'Device A', isOnline: true));

      await pumpApp(tester, AppRoutes.home, size: _phone);

      expect(find.byKey(const Key('provider_setup_gate')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

// ─── Fakes ───────────────────────────────────────────────────────────────────

AuthAuthenticated _authenticatedState() => const AuthAuthenticated(
  username: 'ahmed',
  email: 'ahmed@example.com',
  userId: 'user-1',
  accessToken: 'token',
  userCredits: 0,
  totalCredits: 0,
);

/// A provider client whose readiness verdict each test controls.
class _FakeProviderClient extends Fake implements ProviderSetupClient {
  ProviderReadinessDto readiness = const ProviderReadinessDto(hasProvider: true, runtimeReady: true);
  Object? readinessError;

  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) async {
    final error = readinessError;
    if (error != null) throw error;
    return readiness;
  }

  @override
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent}) async => readiness;

  @override
  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent}) async => const [];

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async => const [];

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async =>
      const ModelCacheSnapshotDto(instances: [], recent: []);

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => const [];

  @override
  Stream<ModelCacheUpdateEvent> get modelUpdates => const Stream<ModelCacheUpdateEvent>.empty();

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async => const ProviderUsageSupportDto(support: {});

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => const ProviderUsageResultDto(status: 'unavailable');

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) async {}
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

class _FakeGatewayConnectionCubit extends Fake implements GatewayConnectionCubit {
  _FakeGatewayConnectionCubit(this._state);

  final GatewayConnectionStatus _state;
  final StreamController<GatewayConnectionStatus> _controller = StreamController<GatewayConnectionStatus>.broadcast();

  @override
  GatewayConnectionStatus get state => _state;

  @override
  Stream<GatewayConnectionStatus> get stream => _controller.stream;

  void dispose() => unawaited(_controller.close());
}

class _FakeAppearanceCubit extends Fake implements AppearanceCubit {
  @override
  AppearanceState get state => const AppearanceState();

  @override
  Stream<AppearanceState> get stream => const Stream<AppearanceState>.empty();
}

class _FakeAccountLifecycleRepository extends Fake implements AccountLifecycleRepository {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Stream<bool> get readinessChanges => const Stream<bool>.empty();

  @override
  bool get isReady => false;

  @override
  Future<AccountLifecycleSnapshot> fetch() async =>
      const AccountLifecycleSnapshot(items: [], presenceAvailable: false);

  @override
  Future<void> dispose() async {}
}
