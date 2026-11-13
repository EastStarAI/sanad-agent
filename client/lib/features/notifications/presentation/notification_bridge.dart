import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/app.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
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
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_ask_registry.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/features/notifications/presentation/notification_window_presence_reporter.dart';
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
/// It sits above the router, so it composes [NotificationWindowPresenceReporter]
/// — the one projector of the desktop window's deterministic hide/show record —
/// and navigates through the application navigator key rather than a router
/// context.
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

  /// The pipeline this bridge owns. Window visibility is projected separately by
  /// [NotificationWindowPresenceReporter], and the lifecycle observer here only
  /// refreshes the OS permission on resume.
  NotificationService? _service;
  final List<StreamSubscription<SocketLifecycleState>> _lifecycleSubscriptions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _presence = context.read<NotificationPresenceStore>();
    _adapter = getIt<NotificationPlatformAdapter>();
    _cache = getIt<ConversationCacheRepository>();
    _conversations = getIt<ConversationRepository>();
    _askRegistry = NotificationAskRegistry();

    _opener = NotificationSessionOpener(
      readDevices: _readDevices,
      sessionsForDevice: _cache.sessionsForDevice,
      activeDeviceId: () => _cache.activeDeviceId,
      openDestination: _openDestination,
      showWindow: _showWindow,
    );

    if (!_adapter.isSupported) {
      _logger.info('desktop notifications are not available on ${AppPlatform.name}');
      return;
    }

    final settings = context.read<NotificationSettingsCubit>();
    _service = NotificationService(
      adapter: _adapter,
      eventStreams: getIt<DeviceConnectionCoordinator>().eventStreams,
      copyResolver: _resolveCopy,
      readPreferences: () => settings.state.preferences,
      readPermission: () => settings.state.permission,
      readPresence: () => _presence.presence,
      readApprovalActionLabels: _resolveApprovalLabels,
      askRegistry: _askRegistry,
      actionRouter: NotificationActionRouter(
        readPendingAsk: _askRegistry.pendingFor,
        openSession: _opener.open,
        respondToAsk: _respondToAsk,
      ),
    );
    unawaited(_service!.start());
    // Settings owns the button; the pipeline owns the action. Attaching the
    // probe here keeps one path to the platform and lets the test result honour
    // the same permission and preference gates a real alert would.
    settings.attachTestSender(_sendTestNotification);
    _listenToTransportLifecycle();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    // Window visibility is not derived here: [NotificationWindowPresenceReporter]
    // reads the deterministic hide/show record of [DesktopLifecycleManager],
    // because a desktop platform may never emit a transition for a tray hide.
    if (state == AppLifecycleState.resumed) {
      // An OS revocation must reach the display pipeline and Settings without an
      // app restart.
      unawaited(context.read<NotificationSettingsCubit>().refreshPermission());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _lifecycleSubscriptions) {
      unawaited(subscription.cancel());
    }
    _lifecycleSubscriptions.clear();
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

  /// Runs the user's test notification through the mounted pipeline.
  Future<NotificationDisplayOutcome?> _sendTestNotification() async {
    final service = _service;
    if (service == null) return null;
    final copy = _copy.testNotificationCopy;
    final decision = await service.raiseTestNotification(
      title: copy.title,
      body: copy.body,
    );
    return decision?.outcome;
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
  Widget build(BuildContext context) => NotificationWindowPresenceReporter(
        lifecycleManager: AppPlatform.isDesktop ? getIt<DesktopLifecycleManager>() : null,
        child: widget.child,
      );
}
