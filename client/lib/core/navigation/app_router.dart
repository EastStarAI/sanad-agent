import 'package:logging/logging.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/core/navigation/route_refresh_notifier.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/auth/presentation/screens/splash_screen.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/features/home/presentation/screens/home_screen.dart';
import 'package:sanad_client/features/settings/presentation/screens/settings_screen.dart';
import 'package:sanad_client/features/devices/presentation/screens/add_device_screen.dart';
import 'package:sanad_client/features/devices/presentation/screens/onboarding_setup_screen.dart';
import 'package:sanad_client/features/mcp/presentation/screens/mcp_server_management_screen.dart';
import 'package:sanad_client/features/mcp/presentation/screens/add_mcp_server_screen.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/core/presentation/screens/not_found_screen.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

typedef AppRouteBuilder = Widget Function(BuildContext context, GoRouterState state);
typedef AppRouteErrorBuilder = Widget Function(BuildContext context, GoRouterState state);

class AppRouterBuilders {
  const AppRouterBuilders({
    this.splashBuilder,
    this.loginBuilder,
    this.homeBuilder,
    this.settingsBuilder,
    this.stdioMcpSettingsBuilder,
    this.mcpServersBuilder,
    this.addMcpServerBuilder,
    this.agentsBuilder,
    this.addAgentBuilder,
    this.onboardingBuilder,
    this.errorBuilder,
  });

  final AppRouteBuilder? splashBuilder;
  final AppRouteBuilder? loginBuilder;
  final AppRouteBuilder? homeBuilder;
  final AppRouteBuilder? settingsBuilder;
  final AppRouteBuilder? stdioMcpSettingsBuilder;
  final AppRouteBuilder? mcpServersBuilder;
  final AppRouteBuilder? addMcpServerBuilder;
  final AppRouteBuilder? agentsBuilder;
  final AppRouteBuilder? addAgentBuilder;
  final AppRouteBuilder? onboardingBuilder;
  final AppRouteErrorBuilder? errorBuilder;
}

/// Holds the [GoRouter] instance together with its [GoRouterHistorySync].
///
/// Returned by [AppRouter.createRouter] so callers get both the router config
/// and the history synchronization object in one bundle.
class AppRouterSetup {
  final GoRouter router;
  final GoRouterHistorySync historySync;

  AppRouterSetup({
    required this.router,
    required this.historySync,
  });
}

class AppRouter {
  static AppRouterSetup createRouter(
    AuthCubit authCubit, {
    GatewayConnectionCubit? gatewayConnectionCubit,
    String? initialLocation,
    GlobalKey<NavigatorState>? navigatorKey,
    AppRouterBuilders builders = const AppRouterBuilders(),
    ConversationHistoryController? historyController,
  }) {
    final controller = historyController ?? ConversationHistoryController();

    final router = GoRouter(
      navigatorKey: navigatorKey,
      initialLocation: initialLocation ?? AppRoutes.splash,
      refreshListenable: RouteRefreshNotifier(
        authCubit.stream,
        gatewayConnectionCubit?.stream,
      ),
      redirect: (context, state) {
        return handleRedirect(
          authCubit.state,
          uri: state.uri,
          matchedLocation: state.matchedLocation,
          gatewayStatus: gatewayConnectionCubit?.state,
        );
      },
      routes: [
        GoRoute(
          path: AppRoutes.splash,
          pageBuilder: (context, state) => _buildSplashPage(
            context,
            state,
            builders.splashBuilder ?? builders.loginBuilder,
            bootstrapGateway: true,
          ),
        ),
        GoRoute(
          path: AppRoutes.login,
          pageBuilder: (context, state) => _buildSplashPage(
            context,
            state,
            builders.loginBuilder ?? builders.splashBuilder,
            bootstrapGateway: false,
          ),
        ),
        GoRoute(
          path: AppRoutes.home,
          pageBuilder: (context, state) => _buildHomePage(
            context,
            state,
            builders.homeBuilder,
          ),
        ),
        GoRoute(
          path: AppRoutes.conversations,
          pageBuilder: (context, state) => _buildHomePage(
            context,
            state,
            builders.homeBuilder,
          ),
        ),
        GoRoute(
          path: AppRoutes.newConversation,
          pageBuilder: (context, state) => _buildHomePage(
            context,
            state,
            builders.homeBuilder,
          ),
        ),
        GoRoute(
          path: AppRoutes.session,
          pageBuilder: (context, state) => _buildHomePage(
            context,
            state,
            builders.homeBuilder,
          ),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: builders.settingsBuilder ?? (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: AppRoutes.stdioMcpSettings,
          builder: builders.stdioMcpSettingsBuilder ?? (context, state) => const McpServerManagementScreen(),
        ),
        GoRoute(
          path: AppRoutes.mcpServers,
          builder: builders.mcpServersBuilder ?? (context, state) => const McpServerManagementScreen(),
        ),
        GoRoute(
          path: AppRoutes.addMcpServer,
          builder:
              builders.addMcpServerBuilder ??
              (context, state) {
                final extra = state.extra;
                final payload = extra is Map ? Map<String, dynamic>.from(extra) : const <String, dynamic>{};
                return AddMcpServerScreen(
                  device: payload['device'] as DeviceConfig?,
                  workspacePath: payload['workspacePath']?.toString(),
                  scopeLabel: payload['scopeLabel']?.toString(),
                  scope: payload['scope'] is McpConfigScope
                      ? payload['scope'] as McpConfigScope
                      : McpConfigScope.global,
                  initialConfig: payload['initialConfig'] as McpServerConfig?,
                );
              },
        ),
        GoRoute(
          path: AppRoutes.agents,
          redirect: builders.agentsBuilder == null ? (context, state) => '${AppRoutes.settings}?section=device' : null,
          builder: builders.agentsBuilder ?? (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: AppRoutes.addAgent,
          builder: builders.addAgentBuilder ?? (context, state) => const AddDeviceScreen(),
        ),
        GoRoute(
          path: AppRoutes.onboarding,
          builder: builders.onboardingBuilder ?? (context, state) => const OnboardingSetupScreen(),
        ),
      ],
      errorBuilder:
          builders.errorBuilder ??
          (context, state) => NotFoundScreen(
            errorMessage: state.uri.path,
          ),
    );

    final historySync = GoRouterHistorySync(
      controller: controller,
      router: router,
    );

    return AppRouterSetup(
      router: router,
      historySync: historySync,
    );
  }

  static String? handleRedirect(
    AuthState authState, {
    required Uri uri,
    required String matchedLocation,
    GatewayConnectionStatus? gatewayStatus,
  }) {
    final currentUri = uri;
    final isLoggingIn = matchedLocation == AppRoutes.login;
    final isSplash = matchedLocation == AppRoutes.splash;
    final isOnboarding = matchedLocation == AppRoutes.onboarding;
    final isAddAgent = matchedLocation == AppRoutes.addAgent;

    final isLocalInstalled =
        AppPlatform.isDesktop && gatewayStatus != null && gatewayStatus.localGateway != LocalGatewayStatus.notFound;
    final isLocalReady = AppPlatform.isDesktop && gatewayStatus?.isLocalConnected == true;

    // A ready desktop-local Agent is sufficient runtime authority even when
    // cloud authentication is absent. If bootstrap previously fell back to an
    // unauthenticated surface, route refresh must recover to Home without a
    // manual Run Local action.
    if (authState is! AuthAuthenticated &&
        authState is! AuthCompleting &&
        isLocalReady &&
        (isSplash || isLoggingIn || isOnboarding)) {
      final requestedLocation = currentUri.queryParameters['from'];
      return _debugRedirect(
        requestedLocation != null && requestedLocation.isNotEmpty
            ? requestedLocation
            : (gatewayStatus?.recommendedRoute ?? AppRoutes.home),
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'desktop_local_ready_redirect',
      );
    }

    // 1. Authenticated state
    if (authState is AuthAuthenticated) {
      if (isLoggingIn) {
        final requestedLocation = currentUri.queryParameters['from'];
        if (requestedLocation != null && requestedLocation.isNotEmpty) {
          return _debugRedirect(
            Uri(
              path: AppRoutes.splash,
              queryParameters: {'from': requestedLocation},
            ).toString(),
            authState: authState,
            uri: currentUri,
            matchedLocation: matchedLocation,
            reason: 'authenticated_login_redirect_to_bootstrap_with_from',
          );
        }
        return _debugRedirect(
          _authLocationWithReturnTo(AppRoutes.splash, currentUri),
          authState: authState,
          uri: currentUri,
          matchedLocation: matchedLocation,
          reason: 'authenticated_login_redirect_to_bootstrap',
        );
      }

      // If the user is on the splash screen but bootstrapping is already complete,
      // redirect them to the requested or recommended route to avoid race conditions.
      if (isSplash) {
        final isReady = AppPlatform.isDesktop
            ? (gatewayStatus?.isLocalConnected == true || gatewayStatus?.isCloudReady == true)
            : (gatewayStatus?.isCloudReady == true || gatewayStatus?.sanadGateway == SanadGatewayStatus.disconnected);
        if (isReady) {
          final requestedLocation = currentUri.queryParameters['from'];
          final target = (requestedLocation != null && requestedLocation.isNotEmpty)
              ? requestedLocation
              : (gatewayStatus?.recommendedRoute ?? AppRoutes.home);
          return _debugRedirect(
            target,
            authState: authState,
            uri: currentUri,
            matchedLocation: matchedLocation,
            reason: 'authenticated_bootstrap_complete_redirect',
          );
        }
      }

      return _debugRedirect(
        null,
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'allowed',
      );
    }

    // 2. Unauthenticated / Loading / Initial on Desktop with Local Gateway (Offline Mode)
    if (isLocalInstalled) {
      return _debugRedirect(
        null,
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'desktop_offline_mode_allowed',
      );
    }

    // 3. Unauthenticated / Loading / Initial without Local Gateway
    if (authState is AuthInitial || authState is AuthLoading || authState is AuthCompleting) {
      if (isSplash || isLoggingIn || (AppPlatform.isDesktop && isOnboarding)) {
        return _debugRedirect(
          null,
          authState: authState,
          uri: currentUri,
          matchedLocation: matchedLocation,
          reason: 'auth_bootstrap_route_allowed',
        );
      }
      return _debugRedirect(
        _authLocationWithReturnTo(AppRoutes.splash, currentUri),
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'auth_bootstrap_required',
      );
    }

    // AuthUnauthenticated / AuthError without Local Gateway
    if (AppPlatform.isDesktop) {
      if (isSplash || isLoggingIn || isOnboarding || isAddAgent) {
        return _debugRedirect(
          null,
          authState: authState,
          uri: currentUri,
          matchedLocation: matchedLocation,
          reason: 'desktop_unauth_route_allowed',
        );
      }
      return _debugRedirect(
        _authLocationWithReturnTo(AppRoutes.splash, currentUri),
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'desktop_unauth_bootstrap_required',
      );
    }

    // Non-desktop (Mobile/Web) unauthenticated
    if (isSplash) {
      return _debugRedirect(
        AppRoutes.login,
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'non_desktop_unauth_login_required',
      );
    }
    if (isLoggingIn) {
      return _debugRedirect(
        null,
        authState: authState,
        uri: currentUri,
        matchedLocation: matchedLocation,
        reason: 'login_allowed',
      );
    }
    return _debugRedirect(
      _authLocationWithReturnTo(AppRoutes.login, currentUri),
      authState: authState,
      uri: currentUri,
      matchedLocation: matchedLocation,
      reason: 'login_required',
    );
  }

  static final _logger = Logger('AppRouter');

  static String? _debugRedirect(
    String? redirect, {
    required AuthState authState,
    required Uri uri,
    required String matchedLocation,
    required String reason,
  }) {
    _logger.info(
      'AppRouterRedirect: auth=${authState.runtimeType} '
      'desktop=${AppPlatform.isDesktop} location=$matchedLocation '
      'uri=$uri redirect=${redirect ?? 'allow'} reason=$reason',
    );
    return redirect;
  }

  static String _authLocationWithReturnTo(String authPath, Uri currentUri) {
    final requestedLocation = _requestedLocation(currentUri);
    if (requestedLocation == authPath) return authPath;
    return Uri(
      path: authPath,
      queryParameters: {
        'from': requestedLocation,
      },
    ).toString();
  }

  static String _requestedLocation(Uri uri) {
    final path = uri.path.isEmpty ? AppRoutes.splash : uri.path;
    final query = Map<String, String>.from(uri.queryParameters)..remove('from');
    return Uri(path: path, queryParameters: query.isEmpty ? null : query).toString();
  }

  static Page<void> _buildHomePage(
    BuildContext context,
    GoRouterState state,
    AppRouteBuilder? overrideBuilder,
  ) {
    final destination = ConversationDestination.fromRouteParams(
      deviceId: state.pathParameters['deviceId'],
      sessionId: state.pathParameters['sessionId'],
      queryParameters: state.uri.queryParameters,
      isNew: state.matchedLocation == AppRoutes.newConversation || state.uri.path.endsWith('/new'),
    );

    final child =
        overrideBuilder?.call(context, state) ??
        HomeScreen(
          destination: destination,
        );

    return NoTransitionPage<void>(
      key: const ValueKey('home-router-page'),
      child: child,
    );
  }

  static Page<void> _buildSplashPage(
    BuildContext context,
    GoRouterState state,
    AppRouteBuilder? overrideBuilder, {
    required bool bootstrapGateway,
  }) {
    final child =
        overrideBuilder?.call(context, state) ??
        SplashScreen(
          requestedLocation: state.uri.queryParameters['from'],
          bootstrapGateway: bootstrapGateway,
        );
    return NoTransitionPage<void>(
      key: ValueKey(bootstrapGateway ? 'auth-bootstrap-page' : 'login-page'),
      child: child,
    );
  }
}
