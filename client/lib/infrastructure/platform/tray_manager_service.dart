import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/app.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/infrastructure/platform/desktop_lifecycle_manager.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_builder.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:tray_manager/tray_manager.dart' as tm;

abstract class TrayManagerAdapter {
  Future<void> initialize({
    required String iconAssetPath,
    required String tooltip,
    required void Function() onTrayIconClick,
  });
  Future<void> setContextMenu(List<TrayMenuItemDescriptor> items);
  Future<void> destroy();
}

class NativeTrayManagerAdapter implements TrayManagerAdapter {
  static final _logger = Logger('NativeTrayManagerAdapter');
  tm.TrayIcon? _trayIcon;
  tm.Menu? _currentMenu;
  List<tm.MenuItem> _currentMenuItems = [];

  @override
  Future<void> initialize({
    required String iconAssetPath,
    required String tooltip,
    required void Function() onTrayIconClick,
  }) async {
    try {
      final trayIcon = tm.TrayIcon.create();
      if (trayIcon == null) {
        _logger.warning('Failed to create native tray icon');
        return;
      }
      _trayIcon = trayIcon;

      try {
        final image = tm.ImageAsset.fromAsset(iconAssetPath);
        if (image != null) {
          trayIcon.icon = image;
        }
      } catch (e) {
        _logger.warning('Could not load tray icon asset: $iconAssetPath', e);
      }

      if (AppPlatform.isWindows) {
        trayIcon.setContextMenuTrigger(tm.ContextMenuTrigger.rightClicked);
      } else {
        if (AppPlatform.isMacOS) {
          trayIcon.iconSize = const Size(18, 18);
        }
        trayIcon.setContextMenuTrigger(tm.ContextMenuTrigger.clicked);
      }

      trayIcon.setTooltip(tooltip);
      trayIcon.addListener((event) {
        if (event is tm.TrayIconClickedEvent || event is tm.TrayIconDoubleClickedEvent) {
          if (AppPlatform.isWindows) {
            onTrayIconClick();
          }
        }
      });
      trayIcon.setVisible(true);
    } catch (e, st) {
      _logger.warning('Failed to initialize native tray icon', e, st);
    }
  }

  @override
  Future<void> setContextMenu(List<TrayMenuItemDescriptor> items) async {
    final trayIcon = _trayIcon;
    if (trayIcon == null) return;

    try {
      final menu = tm.Menu.create();
      if (menu == null) {
        _logger.warning('Failed to create native menu');
        return;
      }

      final newItems = <tm.MenuItem>[];
      for (final item in items) {
        if (item.isSeparator) {
          menu.addSeparator();
          continue;
        }

        final nativeItem = tm.MenuItem.createWithLabelAndType(
          item.label,
          tm.MenuItemType.normal,
        );
        if (nativeItem == null) continue;

        nativeItem.isEnabled = item.isEnabled;
        if (item.onSelected != null) {
          nativeItem.addListener((event) {
            if (event is tm.MenuItemClickedEvent) {
              unawaited(Future.sync(() => item.onSelected!()));
            }
          });
        }
        menu.addItem(nativeItem);
        newItems.add(nativeItem);
      }

      trayIcon.setContextMenu(menu);

      // Preserve new menu/items in Dart memory while freeing previous instances
      final oldMenu = _currentMenu;
      final oldItems = _currentMenuItems;
      _currentMenu = menu;
      _currentMenuItems = newItems;

      for (final oldItem in oldItems) {
        try {
          oldItem.dispose();
        } catch (_) {}
      }
      try {
        oldMenu?.dispose();
      } catch (_) {}
    } catch (e, st) {
      _logger.warning('Failed to set tray context menu', e, st);
    }
  }

  @override
  Future<void> destroy() async {
    try {
      for (final item in _currentMenuItems) {
        try {
          item.dispose();
        } catch (_) {}
      }
      _currentMenuItems.clear();
      try {
        _currentMenu?.dispose();
      } catch (_) {}
      _currentMenu = null;
      _trayIcon?.dispose();
      _trayIcon = null;
    } catch (e, st) {
      _logger.warning('Failed to dispose tray icon', e, st);
    }
  }
}

class AppTrayService {
  static final _logger = Logger('AppTrayService');

  final TrayManagerAdapter _adapter;
  final ConversationCacheStore _conversationCacheStore;
  final ClientCliCubit _clientCliCubit;
  final LocalDaemonController _daemonController;
  final DesktopLifecycleManager _lifecycleManager;
  final void Function(ConversationDestination destination)? _onNavigate;

  StreamSubscription? _cacheSub;
  StreamSubscription? _cliSub;
  Timer? _refreshDebounceTimer;
  Timer? _daemonPollTimer;
  List<TrayMenuItemDescriptor>? _lastMenuItems;
  bool _isInitialized = false;
  bool _isAgentActionInProgress = false;

  AppTrayService({
    required TrayManagerAdapter adapter,
    required ConversationCacheStore conversationCacheStore,
    required ClientCliCubit clientCliCubit,
    required LocalDaemonController daemonController,
    required DesktopLifecycleManager lifecycleManager,
    void Function(ConversationDestination destination)? onNavigate,
  })  : _adapter = adapter,
        _conversationCacheStore = conversationCacheStore,
        _clientCliCubit = clientCliCubit,
        _daemonController = daemonController,
        _lifecycleManager = lifecycleManager,
        _onNavigate = onNavigate;

  bool get isInitialized => _isInitialized;

  Future<void> initialize({
    String iconAssetPath = 'assets/app-logo.png',
    String tooltip = 'Sanad',
  }) async {
    if (_isInitialized) return;
    _isInitialized = true;

    await _adapter.initialize(
      iconAssetPath: iconAssetPath,
      tooltip: tooltip,
      onTrayIconClick: () => _lifecycleManager.showWindow(),
    );

    _cacheSub = _conversationCacheStore.snapshotStream.listen((_) {
      _scheduleRefresh();
    });

    _cliSub = _clientCliCubit.stream.listen((_) {
      _scheduleRefresh();
    });

    _daemonPollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(refreshMenu());
    });

    await refreshMenu(force: true);
  }

  void _scheduleRefresh() {
    _refreshDebounceTimer?.cancel();
    _refreshDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(refreshMenu());
    });
  }

  List<Session> extractRecentConversations() {
    final allSessions = <Session>[];
    final contexts = _conversationCacheStore.snapshot.contexts;
    for (final entry in contexts.entries) {
      final deviceId = entry.key;
      final sessions = _conversationCacheStore.sessionsForDevice(deviceId);
      for (final s in sessions) {
        if (s.deviceId == null || s.deviceId!.isEmpty) {
          allSessions.add(s.copyWith(deviceId: deviceId));
        } else {
          allSessions.add(s);
        }
      }
    }
    final deduped = <String, Session>{};
    for (final session in allSessions) {
      final existing = deduped[session.id];
      if (existing == null) {
        deduped[session.id] = session;
      } else {
        final existingTime = existing.lastMessageAt ?? existing.updatedAt;
        final newTime = session.lastMessageAt ?? session.updatedAt;
        if (newTime.isAfter(existingTime)) {
          deduped[session.id] = session;
        }
      }
    }
    return TrayMenuBuilder.sortRecentConversations(deduped.values);
  }

  Future<void> refreshMenu({bool force = false}) async {
    if (!_isInitialized) return;

    bool isRunning = false;
    try {
      isRunning = await _daemonController.isDaemonRunning();
    } catch (e) {
      _logger.warning('Failed to query daemon running status', e);
    }

    final recentSessions = extractRecentConversations();
    final cliEnabled = _clientCliCubit.state.enabled;

    final menuItems = TrayMenuBuilder.buildMenu(
      recentConversations: recentSessions,
      isAgentRunning: isRunning,
      isClientCliEnabled: cliEnabled,
      onShow: () => unawaited(_lifecycleManager.showWindow()),
      onSelectConversation: (session) => handleSelectConversation(session),
      onAgentAction: () => unawaited(handleAgentAction()),
      onToggleClientCli: () => unawaited(handleToggleClientCli()),
      onQuit: () => unawaited(_lifecycleManager.quit()),
    );

    if (!force && listEquals(_lastMenuItems, menuItems)) {
      return;
    }
    _lastMenuItems = menuItems;

    await _adapter.setContextMenu(menuItems);
  }

  void handleSelectConversation(Session session) {
    unawaited(_lifecycleManager.showWindow());
    final effectiveDeviceId = (session.deviceId?.isNotEmpty ?? false)
        ? session.deviceId!
        : (_conversationCacheStore.activeDeviceId ?? '');
    if (effectiveDeviceId.isEmpty) {
      _logger.warning('Cannot navigate to conversation ${session.id}: no valid deviceId');
      return;
    }

    final destination = ConversationDestination.session(
      deviceId: effectiveDeviceId,
      sessionId: session.id,
      workspaceId: session.workspaceId,
    );
    if (_onNavigate != null) {
      _onNavigate(destination);
      return;
    }
    final context = appNavigatorKey.currentContext ??
        appNavigatorKey.currentState?.context ??
        appNavigatorKey.currentState?.overlay?.context;
    if (context != null) {
      GoRouter.of(context).go(destination.routePath);
    }
  }

  Future<void> handleAgentAction() async {
    if (_isAgentActionInProgress) return;
    _isAgentActionInProgress = true;
    try {
      final isRunning = await _daemonController.isDaemonRunning();
      if (isRunning) {
        _logger.info('Restarting local agent daemon from tray action');
        await _daemonController.restartDaemon();
      } else {
        _logger.info('Starting local agent daemon from tray action');
        await _daemonController.startDaemon();
      }
    } catch (e, st) {
      _logger.warning('Failed to execute daemon lifecycle action', e, st);
    } finally {
      _isAgentActionInProgress = false;
      _refreshDebounceTimer?.cancel();
      await refreshMenu(force: true);
    }
  }

  Future<void> handleToggleClientCli() async {
    final next = !_clientCliCubit.state.enabled;
    _logger.info('Toggling Client CLI enabled state to: $next');
    await _clientCliCubit.setEnabled(next);
    _refreshDebounceTimer?.cancel();
    await refreshMenu(force: true);
  }

  Future<void> destroy() async {
    _refreshDebounceTimer?.cancel();
    _refreshDebounceTimer = null;
    _daemonPollTimer?.cancel();
    _daemonPollTimer = null;
    await _cacheSub?.cancel();
    _cacheSub = null;
    await _cliSub?.cancel();
    _cliSub = null;
    _lastMenuItems = null;
    await _adapter.destroy();
    _isInitialized = false;
  }
}
