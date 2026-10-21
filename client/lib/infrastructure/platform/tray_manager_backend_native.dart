import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_client/infrastructure/platform/tray_manager_adapter.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:tray_manager/tray_manager.dart' as tm;

/// Native desktop tray backend.
///
/// This library is the only compile-time consumer of the `tray_manager`
/// package, and it must be reached exclusively through
/// `tray_manager_backend.dart` so non-native targets (Web) never compile it.
TrayManagerAdapter createBackendTrayManagerAdapter() => NativeTrayManagerAdapter();

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
    // Re-initialization must never leave a previously created native icon alive.
    await destroy();
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
          // The menu bar owns the tray colours: a template image is drawn as a
          // monochrome glyph that follows the bar's appearance, so the icon is
          // the background-free mark instead of the square app logo, and its
          // size stays at the platform default (18x18 points).
          trayIcon.isIconTemplate = true;
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
      _logger.info('System tray icon initialized');
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
