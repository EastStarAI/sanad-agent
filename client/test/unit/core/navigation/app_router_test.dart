import 'dart:async';

import 'package:sanad_client/core/navigation/app_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

GoRouter _goRouter(AppRouterSetup setup) => setup.router;

class _FakeAuthCubit extends AuthCubit {
  _FakeAuthCubit() : super(authRepository: _FakeAuthRepository());

  final StreamController<AuthState> _stateController = StreamController<AuthState>.broadcast();
  AuthState _state = AuthInitial();

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

void main() {
  late _FakeAuthCubit authCubit;

  setUp(() {
    authCubit = _FakeAuthCubit();
    AppPlatform.overrideIsDesktop = false;
  });

  tearDown(() async {
    await authCubit.close();
    AppPlatform.overrideIsDesktop = null;
  });

  group('AppRouter Redirects', () {
    test('redirects to splash when auth state is initial or loading', () {
      expect(
        AppRouter.handleRedirect(AuthInitial(), uri: Uri.parse(AppRoutes.home), matchedLocation: AppRoutes.home),
        '/?from=%2Fhome',
      );
      expect(
        AppRouter.handleRedirect(
          AuthLoading(),
          uri: Uri.parse(AppRoutes.settings),
          matchedLocation: AppRoutes.settings,
        ),
        '/?from=%2Fsettings',
      );

      // Should not redirect if already at splash
      expect(
        AppRouter.handleRedirect(AuthInitial(), uri: Uri.parse(AppRoutes.splash), matchedLocation: AppRoutes.splash),
        isNull,
      );
    });

    test('on desktop: allows auth loading users to access home when local gateway is connected', () {
      AppPlatform.overrideIsDesktop = true;
      const connectedStatus = GatewayConnectionStatus(
        localGateway: LocalGatewayStatus.connected,
        sanadGateway: SanadGatewayStatus.disconnected,
        actions: [],
        recommendedRoute: AppRoutes.home,
        isDesktop: true,
      );
      expect(
        AppRouter.handleRedirect(
          AuthLoading(),
          uri: Uri.parse(AppRoutes.home),
          matchedLocation: AppRoutes.home,
          gatewayStatus: connectedStatus,
        ),
        isNull,
      );
    });

    test('redirects to login when auth state is unauthenticated or error', () {
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.home),
          matchedLocation: AppRoutes.home,
        ),
        '/login?from=%2Fhome',
      );
      expect(
        AppRouter.handleRedirect(AuthError('err'), uri: Uri.parse(AppRoutes.splash), matchedLocation: AppRoutes.splash),
        AppRoutes.login,
      );

      // Should not redirect if already at login
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.login),
          matchedLocation: AppRoutes.login,
        ),
        isNull,
      );
    });

    test('on desktop: keeps unauthenticated users on bootstrap before choosing local or onboarding', () {
      AppPlatform.overrideIsDesktop = true;
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.splash),
          matchedLocation: AppRoutes.splash,
        ),
        isNull,
      );
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.login),
          matchedLocation: AppRoutes.login,
        ),
        isNull,
      );
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.home),
          matchedLocation: AppRoutes.home,
        ),
        '/?from=%2Fhome',
      );
    });

    test('on desktop: local-ready unauthenticated startup recovers to home', () {
      AppPlatform.overrideIsDesktop = true;
      const connectedStatus = GatewayConnectionStatus(
        localGateway: LocalGatewayStatus.connected,
        sanadGateway: SanadGatewayStatus.disconnected,
        actions: [],
        recommendedRoute: AppRoutes.home,
        isDesktop: true,
      );
      for (final route in [
        AppRoutes.splash,
        AppRoutes.login,
        AppRoutes.onboarding,
      ]) {
        expect(
          AppRouter.handleRedirect(
            AuthUnauthenticated(),
            uri: Uri.parse(route),
            matchedLocation: route,
            gatewayStatus: connectedStatus,
          ),
          AppRoutes.home,
        );
      }
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.home),
          matchedLocation: AppRoutes.home,
          gatewayStatus: connectedStatus,
        ),
        isNull,
      );
    });

    test('on desktop: allows unauthenticated users to access home when local gateway is installed but stopped', () {
      AppPlatform.overrideIsDesktop = true;
      const stoppedStatus = GatewayConnectionStatus(
        localGateway: LocalGatewayStatus.installedButStopped,
        sanadGateway: SanadGatewayStatus.disconnected,
        actions: [],
        recommendedRoute: AppRoutes.onboarding,
        isDesktop: true,
      );
      expect(
        AppRouter.handleRedirect(
          AuthUnauthenticated(),
          uri: Uri.parse(AppRoutes.home),
          matchedLocation: AppRoutes.home,
          gatewayStatus: stoppedStatus,
        ),
        isNull,
      );
    });

    test('redirects authenticated users back to the requested route when present', () {
      final authState = _authenticatedState();

      expect(
        AppRouter.handleRedirect(
          authState,
          uri: Uri.parse('/?from=%2Fconversations%2Fagent-123%2Fsession-456'),
          matchedLocation: AppRoutes.splash,
        ),
        isNull,
      );
      expect(
        AppRouter.handleRedirect(
          authState,
          uri: Uri.parse('/login?from=%2Fsettings'),
          matchedLocation: AppRoutes.login,
        ),
        '/?from=%2Fsettings',
      );

      expect(
        AppRouter.handleRedirect(authState, uri: Uri.parse(AppRoutes.splash), matchedLocation: AppRoutes.splash),
        isNull,
      );
      expect(
        AppRouter.handleRedirect(authState, uri: Uri.parse(AppRoutes.login), matchedLocation: AppRoutes.login),
        '/?from=%2Flogin',
      );

      // Should not redirect if at any other authenticated route
      expect(
        AppRouter.handleRedirect(authState, uri: Uri.parse(AppRoutes.home), matchedLocation: AppRoutes.home),
        isNull,
      );
      expect(
        AppRouter.handleRedirect(authState, uri: Uri.parse(AppRoutes.settings), matchedLocation: AppRoutes.settings),
        isNull,
      );
    });

    test('redirects authenticated users from splash when gateway is ready', () {
      final authState = _authenticatedState();
      const readyStatus = GatewayConnectionStatus(
        localGateway: LocalGatewayStatus.disconnected,
        sanadGateway: SanadGatewayStatus.authenticatedWithDevices,
        actions: [],
        recommendedRoute: AppRoutes.home,
        isDesktop: false,
      );

      // When there is a "from" parameter
      expect(
        AppRouter.handleRedirect(
          authState,
          uri: Uri.parse('/?from=%2Fconversations%2Fagent-123%2Fsession-456'),
          matchedLocation: AppRoutes.splash,
          gatewayStatus: readyStatus,
        ),
        '/conversations/agent-123/session-456',
      );

      // When there is no "from" parameter
      expect(
        AppRouter.handleRedirect(
          authState,
          uri: Uri.parse(AppRoutes.splash),
          matchedLocation: AppRoutes.splash,
          gatewayStatus: readyStatus,
        ),
        AppRoutes.home,
      );
    });
  });

  test('router has all required routes', () {
    final setup = AppRouter.createRouter(authCubit);
    final goRouter = _goRouter(setup);
    final routes = goRouter.configuration.routes.expand((r) => _extractPaths(r as GoRoute)).toList();

    expect(routes, contains(AppRoutes.splash));
    expect(routes, contains(AppRoutes.login));
    expect(routes, contains(AppRoutes.home));
    expect(routes, contains(AppRoutes.settings));
    expect(routes, contains(AppRoutes.stdioMcpSettings));
    expect(routes, contains(AppRoutes.agents));
    expect(routes, contains(AppRoutes.addAgent));
    expect(routes, contains(AppRoutes.conversations));
    expect(routes, contains(AppRoutes.session));
  });

  testWidgets('parses conversation deep links into route parameters', (tester) async {
    authCubit.emitState(_authenticatedState());
    final setup = AppRouter.createRouter(
      authCubit,
      initialLocation: AppRoutes.sessionLocation('agent-123', 'session-456'),
      builders: AppRouterBuilders(
        homeBuilder: (context, state) => Text(
          'agent=${state.pathParameters['deviceId']};session=${state.pathParameters['sessionId']}',
          textDirection: TextDirection.ltr,
        ),
      ),
    );
    final goRouter = _goRouter(setup);

    await tester.pumpWidget(MaterialApp.router(routerConfig: goRouter));
    await tester.pumpAndSettle();

    expect(find.text('agent=agent-123;session=session-456'), findsOneWidget);
    expect(goRouter.routeInformationProvider.value.uri.path, AppRoutes.sessionLocation('agent-123', 'session-456'));
  });

  testWidgets('renders the error builder for unknown routes', (tester) async {
    authCubit.emitState(_authenticatedState());
    final setup = AppRouter.createRouter(
      authCubit,
      initialLocation: '/missing-route',
      builders: AppRouterBuilders(
        errorBuilder: (context, state) => Text('404:${state.uri.path}', textDirection: TextDirection.ltr),
      ),
    );
    final goRouter = _goRouter(setup);

    await tester.pumpWidget(MaterialApp.router(routerConfig: goRouter));
    await tester.pumpAndSettle();

    expect(find.text('404:/missing-route'), findsOneWidget);
  });

  testWidgets('updates router state when navigating between conversation routes', (tester) async {
    authCubit.emitState(_authenticatedState());
    final setup = AppRouter.createRouter(
      authCubit,
      initialLocation: AppRoutes.conversationLocation('agent-123'),
      builders: AppRouterBuilders(
        homeBuilder: (context, state) => Text(
          'path=${state.uri.path};agent=${state.pathParameters['deviceId']};session=${state.pathParameters['sessionId'] ?? 'none'}',
          textDirection: TextDirection.ltr,
        ),
      ),
    );
    final goRouter = _goRouter(setup);

    await tester.pumpWidget(MaterialApp.router(routerConfig: goRouter));
    await tester.pumpAndSettle();

    expect(find.text('path=/conversations/agent-123;agent=agent-123;session=none'), findsOneWidget);

    goRouter.go(AppRoutes.sessionLocation('agent-123', 'session-999'));
    await tester.pumpAndSettle();

    expect(find.text('path=/conversations/agent-123/session-999;agent=agent-123;session=session-999'), findsOneWidget);
    expect(goRouter.routeInformationProvider.value.uri.path, AppRoutes.sessionLocation('agent-123', 'session-999'));
  });

  testWidgets('history sync keeps UI and external route navigation aligned', (tester) async {
    authCubit.emitState(_authenticatedState());
    final history = ConversationHistoryController();
    const first = ConversationDestination.session(deviceId: 'agent-123', sessionId: 'session-a');
    const second = ConversationDestination.session(deviceId: 'agent-123', sessionId: 'session-b');
    history.setInitial(first);
    final setup = AppRouter.createRouter(
      authCubit,
      initialLocation: first.routePath,
      historyController: history,
      builders: AppRouterBuilders(
        homeBuilder: (context, state) => Text(
          state.uri.path,
          textDirection: TextDirection.ltr,
        ),
      ),
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: setup.router));
    await tester.pumpAndSettle();

    setup.historySync.navigateTo(second);
    await tester.pumpAndSettle();
    expect(setup.router.routeInformationProvider.value.uri.path, second.routePath);

    setup.router.go(first.routePath);
    await tester.pumpAndSettle();
    setup.historySync.reconcileFromRoute(first);
    expect(history.snapshot.current, first);
    expect(history.snapshot.forwardStack, [second]);

    setup.historySync.goForward();
    await tester.pumpAndSettle();
    expect(setup.router.routeInformationProvider.value.uri.path, second.routePath);

    history.dispose();
  });

  testWidgets('passes requested conversation route to bootstrap after refresh', (tester) async {
    final setup = AppRouter.createRouter(
      authCubit,
      initialLocation: AppRoutes.sessionLocation('agent-123', 'session-456'),
      builders: AppRouterBuilders(
        splashBuilder: (context, state) =>
            Text('splash:${state.uri.queryParameters['from'] ?? 'none'}', textDirection: TextDirection.ltr),
        homeBuilder: (context, state) => Text('home:${state.uri.path}', textDirection: TextDirection.ltr),
      ),
    );
    final goRouter = _goRouter(setup);

    await tester.pumpWidget(MaterialApp.router(routerConfig: goRouter));
    await tester.pumpAndSettle();

    expect(find.text('splash:/conversations/agent-123/session-456'), findsOneWidget);

    authCubit.emitState(_authenticatedState());
    await tester.pumpAndSettle();

    expect(find.text('splash:/conversations/agent-123/session-456'), findsOneWidget);
    expect(goRouter.routeInformationProvider.value.uri.path, AppRoutes.splash);
  });
}

List<String> _extractPaths(GoRoute route) {
  final paths = [route.path];
  for (final subRoute in route.routes) {
    if (subRoute is GoRoute) {
      paths.addAll(_extractPaths(subRoute).map((p) => '${route.path}/$p'.replaceAll('//', '/')));
    }
  }
  return paths;
}

AuthAuthenticated _authenticatedState() {
  return const AuthAuthenticated(
    username: 'test',
    email: 'test@example.com',
    userId: 'user1',
    accessToken: 'token',
    userCredits: 100.0,
    totalCredits: 100.0,
  );
}
