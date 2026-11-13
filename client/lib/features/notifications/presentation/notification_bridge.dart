import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/app.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_presence_store.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/application/notification_session_opener.dart';
import 'package:sanad_client/features/notifications/application/mobile_push_service.dart';
import 'package:sanad_client/features/notifications/application/mobile_push_token_registrar.dart';
import 'package:sanad_client/features/notifications/data/mobile_push_pending_revocation_store.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/mobile_foreground_policy.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_ask_registry.dart';
import 'package:sanad_client/features/notifications/infrastructure/mobile_push_token_relay.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/infrastructure/platform/desktop_lifecycle_manager.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// Mounts the notification pipeline for the running app.
///
/// This widget is composition only: it supplies the pipeline's dependencies
/// from the providers, the dependency registry, and the platform lifecycle, and
/// it holds nothing that a test would want to fake. The decision, collapse,
/// dedupe, quiet-window, and action rules live in the domain and application
/// layers, which is why this file has no rules of its own.
///
/// It sits above the router, so it reports window visibility itself and navigates
/// through the application navigator key rather than a router context.
class NotificationBridge extends StatefulWidget {
  const NotificationBridge({super.key, required this.child});

  final Widget child;

  @override
  State<NotificationBridge> createState() => _NotificationBridgeState();
}

class _NotificationBridgeState extends State<NotificationBridge> with WidgetsBindingObserver {
  static final Logger _logger = Logger('notifications.bridge');

  late final NotificationPresenceStore _presence;
  late final NotificationPlatformAdapter _adapter;
  late final NotificationAskRegistry _askRegistry;
  late final NotificationSessionOpener _opener;
  late final ConversationCacheRepository _cache;
  late final ConversationRepository _conversations;

  /// The single lifecycle observer that decides whether the UI is on screen.
  NotificationService? _service;
  NotificationActionRouter? _actionRouter;
  MobilePushTransport? _mobileTransport;
  MobilePushTokenRegistrar? _pushRegistrar;
  MobilePushService? _mobilePushService;
  final List<StreamSubscription<SocketLifecycleState>> _lifecycleSubscriptions = [];
  final List<StreamSubscription<Object?>> _pushSubscriptions = [];
  StreamSubscription<NotificationPresence>? _presenceSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _presence = context.read<NotificationPresenceStore>();
    _adapter = getIt<NotificationPlatformAdapter>();
    _cache = getIt<ConversationCacheRepository>();
    _conversations = getIt<ConversationRepository>();
    _askRegistry = NotificationAskRegistry();

    // The app starts in the foreground; the lifecycle callback corrects this as
    // soon as the window is hidden or restored.
    _presence.setWindowVisible(true);

    _opener = NotificationSessionOpener(
      readDevices: _readDevices,
      sessionsForDevice: _cache.sessionsForDevice,
      activeDeviceId: () => _cache.activeDeviceId,
      openDestination: _openDestination,
      showWindow: _showWindow,
    );

    if (!_adapter.isSupported) {
      _logger.info('notifications are not available on ${AppPlatform.name}');
      return;
    }

    final settings = context.read<NotificationSettingsCubit>();
    _actionRouter = NotificationActionRouter(
      readPendingAsk: _askRegistry.pendingFor,
      openSession: _opener.open,
      respondToAsk: _respondToAsk,
    );
    _service = NotificationService(
      adapter: _adapter,
      eventStreams: getIt<DeviceConnectionCoordinator>().eventStreams,
      copyResolver: _resolveCopy,
      readPreferences: () => settings.state.preferences,
      readPermission: () => settings.state.permission,
      readPresence: () => _presence.presence,
      readApprovalActionLabels: _resolveApprovalLabels,
      readKindLabels: _resolveKindLabels,
      askRegistry: _askRegistry,
      actionRouter: _actionRouter!,
    );
    unawaited(_service!.start());
    _listenToTransportLifecycle();
    _startMobilePush();
  }

  /// Mounts the push wake-up path on a platform that has a provider.
  ///
  /// Everything it needs already exists: the display pipeline, the action
  /// router, and the ask registry. Push therefore adds a wake-up and a token, and
  /// nothing that could fork the rules the desktop path already proves.
  void _startMobilePush() {
    final transport = getIt<MobilePushTransport>();
    _mobileTransport = transport;
    _presenceSubscription = _presence.changes.listen(_publishVisibleSession);
    if (!transport.isSupported) return;

    final registrar = MobilePushTokenRegistrar(
      transport: transport,
      relay: getIt<MobilePushTokenRelay>(),
      pendingRevocations: getIt<MobilePushPendingRevocationStore>(),
    )..start();
    _pushRegistrar = registrar;
    _mobilePushService = MobilePushService(
      transport: transport,
      notifications: _service!,
      actionRouter: _actionRouter!,
      readPresence: () => _presence.presence,
      isAppInForeground: () => _presence.presence.windowVisible,
      awaitReady: _awaitAuthoritativeState,
    );
    unawaited(_mobilePushService!.start());
    _listenToAccountSession();
    _publishVisibleSession(_presence.presence);
  }

  /// Registers the device token while an account session exists, and withdraws
  /// it as soon as that session ends.
  ///
  /// Two events end the session and both must revoke: an explicit logout (which
  /// account deletion also performs), and a terminal `auth_revoked` from the
  /// Gateway.
  ///
  /// The account lifecycle listener is an ancestor of this widget, so it tears
  /// the cloud socket down before this listener runs and the revocation always
  /// meets a disconnected socket. The registrar therefore records the withdrawal
  /// before it tries to send it and delivers it on the next authenticated
  /// connection, so the outcome here does not depend on who reacted first.
  void _listenToAccountSession() {
    final auth = context.read<AuthCubit>();
    final coordinator = getIt<DeviceConnectionCoordinator>();
    if (auth.state is AuthAuthenticated) unawaited(_pushRegistrar!.onAuthenticated());
    _pushSubscriptions.add(
      auth.stream.listen((state) {
        switch (state) {
          case AuthAuthenticated():
            unawaited(_pushRegistrar!.onAuthenticated());
          case AuthUnauthenticated():
            unawaited(
              _pushRegistrar!.revoke(
                reason: MobilePushRevocationReason.logout,
                deviceId: coordinator.currentDeviceId,
              ),
            );
          default:
            break;
        }
      }),
    );
    _pushSubscriptions.add(
      coordinator.cloudSocketService.onAuthFailure.listen((payload) {
        if (payload['terminal'] != true) return;
        unawaited(
          _pushRegistrar!.revoke(
            reason: MobilePushRevocationReason.sessionRevoked,
            deviceId: coordinator.currentDeviceId,
          ),
        );
      }),
    );
  }

  /// Mirrors the exact session on screen to the native foreground hook.
  void _publishVisibleSession(NotificationPresence presence) {
    final transport = _mobileTransport;
    if (transport == null || !transport.isSupported) return;
    final sessionId = MobileForegroundPolicy.visibleSessionForNative(
      presence,
      appInForeground: presence.windowVisible,
    );
    unawaited(transport.reportVisibleSession(sessionId));
  }

  /// Waits until the replayed state has arrived, so an approval tapped from a
  /// notification answers the ask this Client actually holds.
  Future<void> _awaitAuthoritativeState() async {
    final socket = getIt<DeviceConnectionCoordinator>().cloudSocketService;
    if (socket.isReady) return;
    await socket.lifecycleStateStream.firstWhere(
      (state) => state == SocketLifecycleState.ready,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _presence.setWindowVisible(true);
        // An OS revocation must reach the display pipeline and Settings
        // without an app restart.
        unawaited(context.read<NotificationSettingsCubit>().refreshPermission());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _presence.setWindowVisible(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _lifecycleSubscriptions) {
      unawaited(subscription.cancel());
    }
    _lifecycleSubscriptions.clear();
    for (final subscription in _pushSubscriptions) {
      unawaited(subscription.cancel());
    }
    _pushSubscriptions.clear();
    unawaited(_presenceSubscription?.cancel());
    _presenceSubscription = null;
    unawaited(_mobilePushService?.dispose());
    unawaited(_pushRegistrar?.dispose());
    _presence.reset();
    unawaited(_service?.dispose());
    super.dispose();
  }

  void _listenToTransportLifecycle() {
    final coordinator = getIt<DeviceConnectionCoordinator>();
    for (final socket in <SanadSocketService>[
      coordinator.localSocketService,
      coordinator.cloudSocketService,
    ]) {
      _lifecycleSubscriptions.add(
        socket.lifecycleStateStream.listen((state) {
          if (state != SocketLifecycleState.ready) return;
          // Every connect re-delivers parked state; the quiet window keeps that
          // replay from becoming a new OS interruption.
          _service?.onTransportConnected();
        }),
      );
    }
  }

  List<DeviceConfig> _readDevices() {
    // A late event may reach the pipeline while the tree tears down; resolving a
    // device then must not throw.
    if (!mounted) return const <DeviceConfig>[];
    final state = context.read<DeviceCubit>().state;
    return switch (state) {
      DeviceActive() => state.agents,
      DeviceNoActive() => state.agents,
      _ => const <DeviceConfig>[],
    };
  }

  NotificationCopySource get _copy {
    final locale = mounted ? context.read<LocaleCubit>().state : const Locale('en');
    return NotificationCopySource(lookupAppLocalizations(locale));
  }

  NotificationCopy _resolveCopy(NotificationKind kind) => _copy.copyFor(kind);

  Map<NotificationActionIntent, String> _resolveApprovalLabels() =>
      _copy.approvalActionLabels;

  Map<NotificationKind, String> _resolveKindLabels() => _copy.kindLabels;

  Future<void> _showWindow() async {
    if (!AppPlatform.isDesktop) return;
    try {
      await getIt<DesktopLifecycleManager>().showWindow();
    } catch (error, stack) {
      _logger.warning('could not restore the window for a notification', error, stack);
    }
  }

  Future<void> _openDestination(ConversationDestination destination) async {
    final context = appNavigatorKey.currentContext ??
        appNavigatorKey.currentState?.context ??
        appNavigatorKey.currentState?.overlay?.context;
    if (context == null) {
      _logger.warning('could not open a notification destination: no router context');
      return;
    }
    GoRouter.of(context).go(destination.routePath);
  }

  Future<void> _respondToAsk(
    DeviceSuspendedRequest request,
    NotificationActionIntent intent,
    NotificationPayload payload,
  ) async {
    final agent = _opener.resolveAgent(
      sessionId: request.sessionId,
      deviceId: payload.deviceId,
      hardwareId: payload.hardwareId,
    );
    if (agent == null) {
      _logger.warning('could not resolve the device for a notification approval');
      return;
    }
    final allow = intent != NotificationActionIntent.deny;
    await _conversations.respondToSuspendedRequest(
      agent,
      request,
      allow: allow,
      scope: allow
          ? (intent == NotificationActionIntent.allowSession ? 'session' : 'once')
          : request.scope,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
