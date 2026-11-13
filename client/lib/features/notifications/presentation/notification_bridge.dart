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
import 'package:sanad_client/features/notifications/application/web_push_subscription_service.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_ask_registry.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';
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
///
/// Web push is a wake-up, never a second decision: a browser notification the
/// worker raised while no tab was visible becomes a page event only through the
/// interaction channel, and a wake-up that a visible tab receives is fed into
/// the same `NotificationService` the socket feeds, where the canonical
/// `event_id` collapses the two copies into one notification.
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
  late final NotificationActionRouter _actionRouter;
  late final ConversationCacheRepository _cache;
  late final ConversationRepository _conversations;

  /// The single lifecycle observer that decides whether the UI is on screen.
  NotificationService? _service;
  WebPushSubscriptionService? _webPush;
  final List<StreamSubscription<SocketLifecycleState>> _lifecycleSubscriptions = [];
  StreamSubscription<WebPushInteraction>? _interactionSubscription;
  StreamSubscription<WebPushSubscription>? _rotationSubscription;
  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<DeviceState>? _pendingOpenDeviceSubscription;

  String? _lastAccessToken;
  bool _authenticated = false;
  _PendingOpen? _pendingOpen;
  int _pendingOpenAttempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _presence = context.read<NotificationPresenceStore>();
    _adapter = getIt<NotificationPlatformAdapter>();
    _webPush = getIt<WebPushSubscriptionService>();
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
    _actionRouter = NotificationActionRouter(
      readPendingAsk: _askRegistry.pendingFor,
      openSession: _opener.open,
      respondToAsk: _respondToAsk,
    );

    _listenToWebPush();
    _listenToAuth();
    _consumePendingWebOpen();

    if (!_adapter.isSupported) {
      _logger.info('notifications are not available on ${AppPlatform.name}');
      return;
    }

    final settings = context.read<NotificationSettingsCubit>();
    _service = NotificationService(
      adapter: _adapter,
      // A browser push wake-up is one more copy of the same canonical event, so
      // it joins the socket streams instead of owning a second display path.
      eventStreams: <Stream<Map<String, dynamic>>>[
        ...getIt<DeviceConnectionCoordinator>().eventStreams,
        if (_webPush != null) _webPush!.pushEnvelopes,
      ],
      copyResolver: _resolveCopy,
      readPreferences: () => settings.state.preferences,
      readPermission: () => settings.state.permission,
      readPresence: () => _presence.presence,
      readApprovalActionLabels: _resolveApprovalLabels,
      askRegistry: _askRegistry,
      actionRouter: _actionRouter,
    );
    unawaited(_service!.start());
    _listenToTransportLifecycle();
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
    unawaited(_interactionSubscription?.cancel());
    unawaited(_rotationSubscription?.cancel());
    unawaited(_authSubscription?.cancel());
    unawaited(_pendingOpenDeviceSubscription?.cancel());
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

  /// Wires the browser interaction channel into the existing router.
  ///
  /// A click is a plain open; an action the browser reports is routed exactly
  /// like a desktop notification action, including its fail-closed checks.
  void _listenToWebPush() {
    final service = _webPush;
    if (service == null) return;
    _interactionSubscription = service.interactions.listen((interaction) {
      unawaited(_handleWebInteraction(interaction));
    });
    _rotationSubscription = service.rotations.listen((subscription) {
      unawaited(service.onSubscriptionRotated(subscription));
    });
  }

  Future<void> _handleWebInteraction(WebPushInteraction interaction) async {
    final payload = _decodeInteraction(interaction);
    if (payload == null) {
      _logger.warning('dropped a browser notification interaction with an unreadable payload');
      return;
    }
    final outcome = await _actionRouter.handle(payload, interaction.actionId);
    _logger.info('browser notification interaction handled: ${outcome.name}');
  }

  NotificationPayload? _decodeInteraction(WebPushInteraction interaction) {
    final envelope = interaction.envelope;
    if (envelope != null) {
      final parsed = NotificationPayload.fromEvent(envelope);
      if (parsed != null) return parsed;
    }
    final presented = interaction.presented;
    if (presented != null) return NotificationPayload.fromPresentationPayload(presented);
    return null;
  }

  /// Revokes the browser subscription on logout with the token captured while
  /// the session was still valid, because the Client clears credentials before
  /// the logout becomes observable here.
  void _listenToAuth() {
    final auth = context.read<AuthCubit>();
    _observeAuth(auth.state);
    _authSubscription = auth.stream.listen(_observeAuth);
  }

  void _observeAuth(AuthState state) {
    if (state is AuthAuthenticated) {
      _lastAccessToken = state.accessToken;
      if (_authenticated) return;
      _authenticated = true;
      unawaited(_webPush?.synchronize());
      return;
    }
    if (!_authenticated) return;
    _authenticated = false;
    final accessToken = _lastAccessToken;
    _lastAccessToken = null;
    unawaited(_webPush?.revokeForLogout(accessToken: accessToken));
  }

  /// Consumes the session a notification click opened the app with.
  ///
  /// The first attempt runs before the device inventory may have arrived; one
  /// bounded retry follows the device state, and a click that still cannot be
  /// resolved is dropped rather than opening a different session.
  void _consumePendingWebOpen() {
    final target = _webPush?.takePendingOpen();
    final sessionId = target?['session_id'];
    if (sessionId == null || sessionId.isEmpty) return;
    _pendingOpen = _PendingOpen(sessionId: sessionId, requestId: target?['request_id']);
    unawaited(_openPendingWebTarget());
    _pendingOpenDeviceSubscription = context.read<DeviceCubit>().stream.listen((state) {
      if (_pendingOpen == null) return;
      if (state is! DeviceActive && state is! DeviceNoActive) return;
      unawaited(_openPendingWebTarget());
    });
  }

  Future<void> _openPendingWebTarget() async {
    final pending = _pendingOpen;
    if (pending == null) return;
    if (_pendingOpenAttempts >= 2) {
      _logger.info('dropped a notification click that could not resolve a device');
      _pendingOpen = null;
      await _pendingOpenDeviceSubscription?.cancel();
      _pendingOpenDeviceSubscription = null;
      return;
    }
    _pendingOpenAttempts++;
    final opened = await _opener.openSession(
      sessionId: pending.sessionId,
      requestId: pending.requestId,
    );
    if (!opened) return;
    _pendingOpen = null;
    await _pendingOpenDeviceSubscription?.cancel();
    _pendingOpenDeviceSubscription = null;
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

  Future<void> _showWindow() async {
    if (!AppPlatform.isDesktop) return;
    try {
      await getIt<DesktopLifecycleManager>().showWindow();
    } catch (error, stack) {
      _logger.warning('could not restore the window for a notification', error, stack);
    }
  }

  Future<void> _openDestination(ConversationDestination destination) async {
    final context =
        appNavigatorKey.currentContext ??
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

class _PendingOpen {
  const _PendingOpen({required this.sessionId, this.requestId});

  final String sessionId;
  final String? requestId;
}
