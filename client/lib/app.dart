import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/app/app_auth_listener.dart';
import 'package:sanad_client/core/presentation/app/app_providers.dart';
import 'package:sanad_client/core/presentation/app/app_shell.dart';
import 'package:sanad_client/core/presentation/state/app_state.dart';
import 'package:sanad_client/core/presentation/utils/external_paste_manager.dart';
import 'package:sanad_client/features/conversations/data/persistence/conversation_cache_persistor.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/utils/app_platform.dart';

AppState get appCtrl => getIt<AppState>();
final appNavigatorKey = GlobalKey<NavigatorState>();

class SanadAgentApp extends StatefulWidget {
  final ThemeMode initialTheme;
  const SanadAgentApp({super.key, required this.initialTheme});

  @override
  State<SanadAgentApp> createState() => _SanadAgentAppState();
}

class _SanadAgentAppState extends State<SanadAgentApp> with WidgetsBindingObserver {
  late final ConversationCachePersistor _conversationCachePersistor;
  bool _wasBackgrounded = false;
  static const _pasteEventChannel = MethodChannel(
    'com.eaststarai.sanad/pasteEvents',
  );

  @override
  void initState() {
    super.initState();
    _conversationCachePersistor = getIt<ConversationCachePersistor>();
    WidgetsBinding.instance.addObserver(this);
    if (AppPlatform.isMacOS) {
      _listenToExternalPaste();
    }
  }

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
    if (state == AppLifecycleState.resumed) {
      if (_wasBackgrounded) {
        _wasBackgrounded = false;
        if (AppPlatform.isMobile || kIsWeb) {
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
      child: AppAuthListener(
        authService: appState.authService,
        socketService: appState.brainSocketController,
        syncAuthContext: () async => appState.syncAuthContext(),
        conversationCacheRepository: getIt<ConversationCacheRepository>(),
        conversationCachePersistor: _conversationCachePersistor,
        navigatorKey: appNavigatorKey,
        child: AppShell(navigatorKey: appNavigatorKey),
      ),
    );
  }
}
