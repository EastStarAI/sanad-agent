import 'package:sanad_client/core/config/app_config.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/bloc/theme/theme_cubit.dart';
import 'package:sanad_client/core/presentation/state/app_state.dart';
import 'package:sanad_client/features/conversations/data/persistence/conversation_cache_persistor.dart';
import 'package:sanad_client/core/utils/logger.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';
import 'package:sanad_client/utils/windows_scheme_registrar.dart';
import 'package:sanad_client/utils/inspector_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppBootstrapResult {
  final ThemeMode initialTheme;

  const AppBootstrapResult({required this.initialTheme});
}

class AppBootstrap {
  static const _startupTraceEnabled = bool.fromEnvironment(
    'SANAD_STARTUP_TRACE',
  );

  static Future<void> _trace(String phase) async {
    if (!_startupTraceEnabled || kIsWeb) return;
    final configured = AppConfig.sanadHome.trim();
    final home = configured.isNotEmpty
        ? configured
        : (Platform.environment['SANAD_HOME']?.trim().isNotEmpty ?? false)
        ? Platform.environment['SANAD_HOME']!.trim()
        : p.join(Platform.environment['USERPROFILE'] ?? '.', '.sanad');
    final file = File(p.join(home, 'logs', 'client-startup.trace'));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${DateTime.now().toUtc().toIso8601String()} $phase\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  static Future<AppBootstrapResult> initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    await _trace('binding-ready');
    final preferencesPrefix = AppConfig.sharedPreferencesPrefix;
    if (preferencesPrefix.isNotEmpty) {
      SharedPreferences.setPrefix(preferencesPrefix);
    }
    initClientLogger();
    setupInspectorListener();

    final initialTheme = await ThemeCubit.getSavedTheme();
    await _trace('theme-ready');
    await Future.wait([
      WindowManagerService.initialize(),
      registerWindowsScheme(),
    ]);
    await _trace('window-ready');

    await configureDependencies(startupTrace: _trace);
    await _trace('dependencies-ready');
    await getIt<AppState>().ready;
    await _trace('app-state-ready');
    await getIt<ConversationCachePersistor>().hydrate();
    await _trace('cache-ready');

    return AppBootstrapResult(initialTheme: initialTheme);
  }
}
