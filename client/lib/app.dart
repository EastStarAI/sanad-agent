import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/app/app_auth_listener.dart';
import 'package:sanad_client/core/presentation/app/app_providers.dart';
import 'package:sanad_client/core/presentation/app/app_shell.dart';
import 'package:sanad_client/core/presentation/state/app_state.dart';
import 'package:sanad_client/core/presentation/utils/external_paste_manager.dart';
import 'package:sanad_client/features/conversations/data/persistence/conversation_cache_persistor.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

AppState get appCtrl => getIt<AppState>();
final appNavigatorKey = GlobalKey<NavigatorState>();

class SanadAgentApp extends StatefulWidget {
  final ThemeMode initialTheme;
  final Locale initialLocale;
  final AppearanceState initialAppearance;

  const SanadAgentApp({
    super.key,
    required this.initialTheme,
    required this.initialLocale,
    this.initialAppearance = const AppearanceState(),
  });

  @override
  State<SanadAgentApp> createState() => _SanadAgentAppState();
}

class _SanadAgentAppState extends State<SanadAgentApp> with WidgetsBindingObserver {
  late final ConversationCachePersistor _conversationCachePersistor;
  bool _wasBackgrounded = false;
  static const _pasteEventChannel = MethodChannel('com.eaststarai.sanad/pasteEvents');

  @override
  void initState() {
    super.initState();
    _conversationCachePersistor = getIt<ConversationCachePersistor>();
    WidgetsBinding.instance.addObserver(this);
    if (AppPlatform.isMacOS) {
      _listenToExternalPaste();
    }
  }

  /// Text pastes are captured by the macOS runner at the key event, so a
  /// dictation tool that restores the pasteboard right after posting Cmd+V
  /// cannot lose its transcript. The runner only captures plain text and keeps
  /// leaving files and images to the composer's paste routing.
  void _listenToExternalPaste() {
    _pasteEventChannel.setMethodCallHandler((call) async {
      if (call.method == 'onExternalPaste') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final text = args['text']?.toString() ?? '';
        if (text.isNotEmpty) {
          ExternalPasteManager.handlePaste(text);
        }
      }
      return null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The gateway socket is created while the app returns from the external
    // login browser; a connection opened across that transition can look ready
    // while its transport is already dead, so lifecycle ordering is diagnosed
    // from this line.
    Logger('app.lifecycle').info('app.lifecycle state=${state.name}');
    if (state == AppLifecycleState.resumed) {
      if (_wasBackgrounded) {
        _wasBackgrounded = false;
        if (AppPlatform.isMobile || AppPlatform.isWeb) {
          appCtrl.onAppResumed();
        }
      }
      return;
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      _wasBackgrounded = true;
      unawaited(_conversationCachePersistor.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_conversationCachePersistor.flush());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = appCtrl;

    return AppProviders(
      initialTheme: widget.initialTheme,
      initialLocale: widget.initialLocale,
      initialAppearance: widget.initialAppearance,
      child: AppAuthListener(
        authService: appState.authService,
        socketService: appState.brainSocketController,
        localSocketService: AppPlatform.isDesktop
            ? getIt<SanadSocketService>(instanceName: 'localSocketService')
            : null,
        connectionCoordinator: AppPlatform.isDesktop ? getIt<DeviceConnectionCoordinator>() : null,
        syncAuthContext: () async => appState.syncAuthContext(),
        conversationCacheRepository: getIt<ConversationCacheRepository>(),
        conversationCachePersistor: _conversationCachePersistor,
        navigatorKey: appNavigatorKey,
        child: AppShell(navigatorKey: appNavigatorKey),
      ),
    );
  }
}
