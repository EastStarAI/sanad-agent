import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/conversations/data/persistence/conversation_cache_persistor.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

class AppAuthListener extends StatefulWidget {
  final AuthService authService;
  final SanadSocketService socketService;
  final SanadSocketService? localSocketService;
  final DeviceConnectionCoordinator? connectionCoordinator;
  final Future<void> Function() syncAuthContext;
  final ConversationCacheRepository conversationCacheRepository;
  final ConversationCachePersistor conversationCachePersistor;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const AppAuthListener({
    super.key,
    required this.authService,
    required this.socketService,
    required this.localSocketService,
    required this.connectionCoordinator,
    required this.syncAuthContext,
    required this.conversationCacheRepository,
    required this.conversationCachePersistor,
    required this.navigatorKey,
    required this.child,
  });

  @override
  State<AppAuthListener> createState() => _AppAuthListenerState();
}

class _AppAuthListenerState extends State<AppAuthListener> {
  StreamSubscription<String?>? _accessTokenSubscription;
  StreamSubscription<void>? _exchangeRequestSubscription;
  StreamSubscription<Map<String, dynamic>>? _localEventSubscription;
  StreamSubscription<SocketLifecycleState>? _localLifecycleSubscription;

  @override
  void initState() {
    super.initState();
    _listenForTerminalSessionInvalidation();
    _listenForDesktopAuthenticationExchange();
  }

  @override
  void didUpdateWidget(covariant AppAuthListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.authService, widget.authService)) {
      unawaited(_accessTokenSubscription?.cancel());
      _listenForTerminalSessionInvalidation();
    }
    if (!identical(oldWidget.authService, widget.authService) ||
        !identical(oldWidget.localSocketService, widget.localSocketService) ||
        !identical(
          oldWidget.connectionCoordinator,
          widget.connectionCoordinator,
        )) {
      unawaited(_exchangeRequestSubscription?.cancel());
      unawaited(_localEventSubscription?.cancel());
      unawaited(_localLifecycleSubscription?.cancel());
      _listenForDesktopAuthenticationExchange();
    }
  }

  void _listenForTerminalSessionInvalidation() {
    _accessTokenSubscription = widget.authService.accessTokenStream.listen((token) {
      if (token != null || !mounted) return;
      context.read<AuthCubit>().invalidateRejectedSession();
    });
  }

  void _listenForDesktopAuthenticationExchange() {
    final localSocket = widget.localSocketService;
    if (!AppPlatform.isDesktop || localSocket == null) return;

    _exchangeRequestSubscription = widget.authService.authenticationExchangeStream.listen(
      (_) => unawaited(_publishDesktopAuthenticationExchange()),
    );
    _localEventSubscription = localSocket.events.listen((event) {
      if (event['type'] != 'authentication_exchange' || !mounted) return;
      unawaited(context.read<AuthCubit>().synchronizeExternalSession());
    });
    _localLifecycleSubscription = localSocket.lifecycleStateStream.listen((state) {
      if (state != SocketLifecycleState.ready || !mounted) return;
      // Reconcile both processes after reconnect because a notification may
      // have been missed while either side was unavailable.
      unawaited(context.read<AuthCubit>().synchronizeExternalSession());
      unawaited(_publishDesktopAuthenticationExchange(ensureConnected: false));
    });
  }

  Future<void> _publishDesktopAuthenticationExchange({
    bool ensureConnected = true,
  }) async {
    final localSocket = widget.localSocketService;
    final coordinator = widget.connectionCoordinator;
    if (!AppPlatform.isDesktop || localSocket == null || coordinator == null) {
      return;
    }
    if (ensureConnected) {
      await coordinator.ensureLocalConnection();
    }
    if (!localSocket.isConnected) return;
    localSocket.emit('authentication_exchange', const {});
  }

  @override
  void dispose() {
    unawaited(_accessTokenSubscription?.cancel());
    unawaited(_exchangeRequestSubscription?.cancel());
    unawaited(_localEventSubscription?.cancel());
    unawaited(_localLifecycleSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthCubit, AuthState>(
      listener: (context, state) {
        if (state is AuthAuthenticated) {
          unawaited(widget.authService.syncExternalSession(state.accessToken));
          unawaited(widget.syncAuthContext());
          widget.socketService.setAccessToken(state.accessToken);
          unawaited(
            widget.socketService
                .connect()
                .then((_) {
                  if (context.mounted) {
                    unawaited(context.read<DeviceCubit>().fetchAgents());
                  }
                })
                .catchError((_) {}),
          );
        } else if (state is AuthUnauthenticated) {
          final cloudDeviceIds = widget.conversationCacheRepository.snapshot.contexts.keys
              .where((deviceId) => deviceId != DeviceInventoryIds.localDevice)
              .toSet();
          widget.conversationCacheRepository.clearCloudUserScope(cloudDeviceIds);
          unawaited(widget.conversationCachePersistor.flush());
          context.read<DeviceConnectionCoordinator>().clearEventDeduplicationState();
          unawaited(context.read<DeviceCubit>().resetForLogout());
          widget.socketService.disconnect();
          widget.socketService.setAccessToken(null);
          unawaited(widget.syncAuthContext());
        }
      },
      child: widget.child,
    );
  }
}
