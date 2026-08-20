import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
// import 'package:macos_window_utils/macos/ns_window_button_type.dart';
// import 'package:macos_window_utils/window_manipulator.dart';
import 'package:sanad_client/utils/app_platform.dart';

class WindowManagerService with WindowListener {
  static const Size minimumWindowSize = Size(450, 600);
  static const Size compactWindowSize = Size(450, 900);
  static const Size defaultWindowSize = Size(1400, 900);

  static final WindowManagerService _instance = WindowManagerService._();
  static final ValueNotifier<bool> _isCompactMode = ValueNotifier(false);
  static final ValueNotifier<bool> _isMaximizedOrFullScreen = ValueNotifier(
    false,
  );
  WindowManagerService._();

  static bool _isInitialized = false;
  static Timer? _saveTimer;
  static Rect? _restoreBounds;
  static bool _isApplyingBounds = false;

  static ValueListenable<bool> get compactModeListenable => _isCompactMode;
  static ValueListenable<bool> get maximizedOrFullScreenListenable => _isMaximizedOrFullScreen;

  static Future<void> toggleMaximized() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;

    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    } else if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _instance._refreshMaximizedOrFullScreenState();
  }

  @visibleForTesting
  static bool isCompactWidth(double width) => width <= compactWindowSize.width + 1.0;

  @visibleForTesting
  static Rect compactBoundsFor(Rect currentBounds) => Rect.fromLTWH(
    currentBounds.left,
    currentBounds.top,
    compactWindowSize.width,
    compactWindowSize.height,
  );

  @visibleForTesting
  static Rect restoreBoundsFor(Rect? previousBounds, {Rect? currentBounds}) {
    final origin = previousBounds ?? currentBounds ?? Rect.zero;
    if (previousBounds == null ||
        previousBounds.width < defaultWindowSize.width ||
        previousBounds.height < defaultWindowSize.height) {
      return Rect.fromLTWH(
        origin.left,
        origin.top,
        defaultWindowSize.width,
        defaultWindowSize.height,
      );
    }
    return previousBounds;
  }

  static Future<void> initialize() async {
    if (!AppPlatform.isDesktop) return;

    await windowManager.ensureInitialized();
    windowManager.addListener(_instance);

    final prefs = await SharedPreferences.getInstance();

    // Retrieve saved dimensions/position
    final double? savedWidth = prefs.getDouble('window_width');
    final double? savedHeight = prefs.getDouble('window_height');
    final double? savedX = prefs.getDouble('window_x');
    final double? savedY = prefs.getDouble('window_y');
    final bool isMaximized = prefs.getBool('window_is_maximized') ?? false;

    // Use default values if nothing is saved
    final Size savedWindowSize = (savedWidth != null && savedHeight != null)
        ? Size(savedWidth, savedHeight)
        : defaultWindowSize;
    final Size windowSize = Size(
      savedWindowSize.width < minimumWindowSize.width ? minimumWindowSize.width : savedWindowSize.width,
      savedWindowSize.height < minimumWindowSize.height ? minimumWindowSize.height : savedWindowSize.height,
    );

    // Determine if we should center the window
    final bool hasCentered = prefs.getBool('has_centered_window') ?? false;
    final bool shouldCenter = !hasCentered && (savedX == null || savedY == null);

    final WindowOptions windowOptions = WindowOptions(
      size: windowSize,
      minimumSize: minimumWindowSize,
      center: shouldCenter,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'Sanad',
      titleBarStyle: TitleBarStyle.hidden,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setMinimumSize(minimumWindowSize);
      if (savedX != null && savedY != null && !isMaximized) {
        await windowManager.setPosition(Offset(savedX, savedY));
      }

      await windowManager.show();
      await windowManager.focus();

      if (isMaximized) {
        await windowManager.maximize();
      }

      // Mark as initialized so subsequent events are tracked.
      _isInitialized = true;
      if (!isMaximized) {
        _isCompactMode.value = isCompactWidth(windowSize.width);
      }
      await _instance._refreshMaximizedOrFullScreenState();

      if (shouldCenter) {
        await prefs.setBool('has_centered_window', true);
      }
    });
  }

  static Future<void> toggleCompactMode() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;

    if (_isCompactMode.value) {
      final currentBounds = await windowManager.getBounds();
      final targetBounds = restoreBoundsFor(_restoreBounds, currentBounds: currentBounds);
      await _setBounds(targetBounds);
      _restoreBounds = null;
      _isCompactMode.value = false;
      _instance._saveWindowState();
      return;
    }

    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }

    final currentBounds = await windowManager.getBounds();
    _restoreBounds = currentBounds;
    final compactBounds = compactBoundsFor(currentBounds);
    await _setBounds(compactBounds);
    _isCompactMode.value = true;
  }

  static Future<void> _setBounds(Rect bounds) async {
    _isApplyingBounds = true;
    try {
      await windowManager.setBounds(bounds, animate: true);
    } finally {
      _isApplyingBounds = false;
    }
  }

  // Helper method to save state with a 500ms debounce
  void _saveWindowState() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      if (!_isInitialized || _isCompactMode.value) return;

      final isMaximized = await windowManager.isMaximized();
      final prefs = await SharedPreferences.getInstance();

      if (!isMaximized) {
        final size = await windowManager.getSize();
        final pos = await windowManager.getPosition();
        await prefs.setDouble('window_width', size.width);
        await prefs.setDouble('window_height', size.height);
        await prefs.setDouble('window_x', pos.dx);
        await prefs.setDouble('window_y', pos.dy);
      }
    });
  }

  Future<void> _refreshMaximizedOrFullScreenState() async {
    if (!_isInitialized) return;
    _isMaximizedOrFullScreen.value = await windowManager.isMaximized() || await windowManager.isFullScreen();
  }

  // WindowListener implementation overrides

  @override
  void onWindowResized() {
    if (!_isInitialized || _isApplyingBounds) return;
    unawaited(_reconcileCompactModeAfterManualResize());
  }

  Future<void> _reconcileCompactModeAfterManualResize() async {
    final size = await windowManager.getSize();
    final isCompact = isCompactWidth(size.width);
    if (_isCompactMode.value && !isCompact) {
      _restoreBounds = null;
      _isCompactMode.value = false;
    } else if (!_isCompactMode.value && isCompact) {
      _isCompactMode.value = true;
    }
    _saveWindowState();
  }

  @override
  void onWindowMoved() {
    if (!_isInitialized) return;
    _saveWindowState();
  }

  @override
  void onWindowMaximize() async {
    if (!_isInitialized) return;
    _isMaximizedOrFullScreen.value = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('window_is_maximized', true);
  }

  @override
  void onWindowUnmaximize() async {
    if (!_isInitialized) return;
    await _refreshMaximizedOrFullScreenState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('window_is_maximized', false);
    _saveWindowState();
  }

  @override
  void onWindowRestore() {
    unawaited(_refreshMaximizedOrFullScreenState());
  }

  @override
  void onWindowEnterFullScreen() {
    _isMaximizedOrFullScreen.value = true;
  }

  @override
  void onWindowLeaveFullScreen() {
    unawaited(_refreshMaximizedOrFullScreenState());
  }
}
