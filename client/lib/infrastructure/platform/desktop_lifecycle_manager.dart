import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';
import 'package:window_manager/window_manager.dart';

abstract class DesktopWindowManagerAdapter {
  Future<void> hide();
  Future<void> show();
  Future<void> focus();
  Future<void> setPreventClose(bool prevent);
  Future<void> destroy();
}

class DefaultDesktopWindowManagerAdapter implements DesktopWindowManagerAdapter {
  const DefaultDesktopWindowManagerAdapter();

  @override
  Future<void> hide() => WindowManagerService.hide();

  @override
  Future<void> show() => WindowManagerService.show();

  @override
  Future<void> focus() => WindowManagerService.focus();

  @override
  Future<void> setPreventClose(bool prevent) => windowManager.setPreventClose(prevent);

  @override
  Future<void> destroy() => WindowManagerService.closeOrDestroy();
}

/// Coordinates desktop application lifecycle (hide to background, restore, and explicit quit).
class DesktopLifecycleManager with WidgetsBindingObserver {
  static final _logger = Logger('DesktopLifecycleManager');

  final DesktopWindowManagerAdapter _windowAdapter;
  final Future<void> Function()? _onDisposeTray;
  final Future<void> Function()? _onStopCliHost;
  final Future<void> Function()? _onFlushCache;
  final void Function()? _onDisposeAppState;
  final void Function()? _onExitProcess;

  bool _isQuitting = false;
  bool _isWindowHidden = false;

  DesktopLifecycleManager({
    DesktopWindowManagerAdapter windowAdapter = const DefaultDesktopWindowManagerAdapter(),
    Future<void> Function()? onDisposeTray,
    Future<void> Function()? onStopCliHost,
    Future<void> Function()? onFlushCache,
    void Function()? onDisposeAppState,
    void Function()? onExitProcess,
  })  : _windowAdapter = windowAdapter,
        _onDisposeTray = onDisposeTray,
        _onStopCliHost = onStopCliHost,
        _onFlushCache = onFlushCache,
        _onDisposeAppState = onDisposeAppState,
        _onExitProcess = onExitProcess;

  bool get isQuitting => _isQuitting;
  bool get isWindowHidden => _isWindowHidden;

  Future<void> hideWindow() async {
    _isWindowHidden = true;
    _logger.info('Hiding desktop window to background');
    await _windowAdapter.hide();
  }

  Future<void> showWindow() async {
    _isWindowHidden = false;
    _logger.info('Restoring desktop window from background');
    await _windowAdapter.show();
    await _windowAdapter.focus();
  }

  Future<void> handleWindowClose({bool isLinux = false}) async {
    if (isLinux) {
      _logger.info('Linux window close requested: performing explicit quit');
      await quit();
      return;
    }
    _logger.info('Desktop window close intercepted: hiding window without disposing state or sockets');
    await hideWindow();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    _logger.info('Platform exit requested: performing explicit quit');
    await quit();
    return AppExitResponse.exit;
  }

  Future<void> quit() async {
    if (_isQuitting) return;
    _isQuitting = true;
    _logger.info('Explicit quit initiated: executing deterministic shutdown');

    try {
      if (_onDisposeTray != null) {
        await _onDisposeTray();
      }
    } catch (e, st) {
      _logger.warning('Failed to dispose tray during quit', e, st);
    }

    try {
      if (_onStopCliHost != null) {
        await _onStopCliHost();
      }
    } catch (e, st) {
      _logger.warning('Failed to stop ClientCliHost during quit', e, st);
    }

    try {
      if (_onFlushCache != null) {
        await _onFlushCache();
      }
    } catch (e, st) {
      _logger.warning('Failed to flush conversation cache during quit', e, st);
    }

    try {
      _onDisposeAppState?.call();
    } catch (e, st) {
      _logger.warning('Failed to dispose AppState during quit', e, st);
    }

    try {
      await _windowAdapter.setPreventClose(false);
      await _windowAdapter.destroy();
    } catch (e, st) {
      _logger.warning('Failed to destroy window during quit', e, st);
    }

    _onExitProcess?.call();
  }
}
