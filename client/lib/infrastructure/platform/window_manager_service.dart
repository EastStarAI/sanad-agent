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

  static const _widthKey = 'window_width';
  static const _heightKey = 'window_height';
  static const _compactHeightKey = 'window_compact_height';
  static const _legacyXKey = 'window_x';
  static const _legacyYKey = 'window_y';
  static const _expandedXKey = 'window_expanded_x';
  static const _expandedYKey = 'window_expanded_y';
  static const _compactXKey = 'window_compact_x';
  static const _compactYKey = 'window_compact_y';

  static bool _isInitialized = false;
  static Timer? _saveTimer;
  static Rect? _restoreBounds;
  static bool _isApplyingBounds = false;

  static ValueListenable<bool> get compactModeListenable => _isCompactMode;
  static ValueListenable<bool> get maximizedOrFullScreenListenable => _isMaximizedOrFullScreen;

  static Future<void> Function()? _onCloseRequested;

  static void setCloseRequestHandler(Future<void> Function()? handler) {
    _onCloseRequested = handler;
  }

  static Future<void> hide() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;
    await windowManager.hide();
  }

  static Future<void> show() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
  }

  static Future<void> focus() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;
    await windowManager.focus();
  }

  static Future<void> showAndFocus() async {
    await show();
    await focus();
  }

  static Future<void> closeOrDestroy() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

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
  static Size clampToDisplay(
    Size targetSize, {
    Size? displayLogicalSize,
    double marginHeight = 64.0,
    double marginWidth = 32.0,
  }) {
    final available = displayLogicalSize ?? getPrimaryDisplayLogicalSize();
    if (available == null) {
      return targetSize;
    }
    final maxWidth = (available.width - marginWidth).clamp(minimumWindowSize.width, double.infinity);
    final maxHeight = (available.height - marginHeight).clamp(minimumWindowSize.height, double.infinity);

    final width = targetSize.width.clamp(minimumWindowSize.width, maxWidth);
    final height = targetSize.height.clamp(minimumWindowSize.height, maxHeight);
    return Size(width, height);
  }

  @visibleForTesting
  static Size? getPrimaryDisplayLogicalSize() {
    try {
      final displays = WidgetsBinding.instance.platformDispatcher.displays;
      if (displays.isNotEmpty) {
        final primary = displays.first;
        final dpr = primary.devicePixelRatio > 0 ? primary.devicePixelRatio : 1.0;
        return Size(primary.size.width / dpr, primary.size.height / dpr);
      }
    } catch (_) {}
    return null;
  }

  @visibleForTesting
  static Rect compactBoundsFor(
    Rect currentBounds, {
    Offset? savedPosition,
    double? preferredHeight,
    Size? displayLogicalSize,
  }) {
    final targetHeight = preferredHeight ?? compactWindowSize.height;
    final effectiveHeight = clampToDisplay(
      Size(compactWindowSize.width, targetHeight),
      displayLogicalSize: displayLogicalSize,
    ).height;

    return Rect.fromLTWH(
      savedPosition?.dx ?? currentBounds.left,
      savedPosition?.dy ?? currentBounds.top,
      compactWindowSize.width,
      effectiveHeight,
    );
  }

  @visibleForTesting
  static Rect restoreBoundsFor(
    Rect? previousBounds, {
    Rect? currentBounds,
    Offset? savedPosition,
    Size? displayLogicalSize,
  }) {
    final origin = previousBounds?.topLeft ?? savedPosition ?? currentBounds?.topLeft ?? Offset.zero;
    final effectiveDefault = clampToDisplay(
      defaultWindowSize,
      displayLogicalSize: displayLogicalSize,
    );
    if (previousBounds == null ||
        previousBounds.width < effectiveDefault.width ||
        previousBounds.height < effectiveDefault.height) {
      return Rect.fromLTWH(
        origin.dx,
        origin.dy,
        effectiveDefault.width,
        effectiveDefault.height,
      );
    }
    return previousBounds;
  }

  static Offset? _readPosition(
    SharedPreferences prefs,
    String xKey,
    String yKey, {
    double? fallbackX,
    double? fallbackY,
  }) {
    final x = prefs.getDouble(xKey) ?? fallbackX;
    final y = prefs.getDouble(yKey) ?? fallbackY;
    return x == null || y == null ? null : Offset(x, y);
  }

  static Future<void> initialize() async {
    if (!AppPlatform.isDesktop) return;

    await windowManager.ensureInitialized();
    windowManager.addListener(_instance);

    final prefs = await SharedPreferences.getInstance();

    final savedWidth = prefs.getDouble(_widthKey);
    final savedHeight = prefs.getDouble(_heightKey);
    final savedCompactHeight = prefs.getDouble(_compactHeightKey);
    final legacyX = prefs.getDouble(_legacyXKey);
    final legacyY = prefs.getDouble(_legacyYKey);
    final expandedPosition = _readPosition(
      prefs,
      _expandedXKey,
      _expandedYKey,
      fallbackX: legacyX,
      fallbackY: legacyY,
    );
    final compactPosition = _readPosition(
      prefs,
      _compactXKey,
      _compactYKey,
      fallbackX: expandedPosition?.dx,
      fallbackY: expandedPosition?.dy,
    );
    final isMaximized = prefs.getBool('window_is_maximized') ?? false;
    final startCompact = !isMaximized && savedWidth != null && isCompactWidth(savedWidth);

    final savedExpandedSize = (savedWidth != null && savedHeight != null && !isCompactWidth(savedWidth))
        ? Size(savedWidth, savedHeight)
        : defaultWindowSize;
    final expandedSize = clampToDisplay(
      Size(
        savedExpandedSize.width < minimumWindowSize.width ? minimumWindowSize.width : savedExpandedSize.width,
        savedExpandedSize.height < minimumWindowSize.height ? minimumWindowSize.height : savedExpandedSize.height,
      ),
    );
    final compactSize = clampToDisplay(
      Size(compactWindowSize.width, savedCompactHeight ?? compactWindowSize.height),
    );
    final windowSize = startCompact ? compactSize : expandedSize;
    var savedPosition = startCompact ? compactPosition : expandedPosition;

    final primaryDisplaySize = getPrimaryDisplayLogicalSize();
    if (savedPosition != null && primaryDisplaySize != null) {
      if (savedPosition.dx > primaryDisplaySize.width - 100 ||
          savedPosition.dy > primaryDisplaySize.height - 100) {
        savedPosition = null;
      }
    }

    final hasCentered = prefs.getBool('has_centered_window') ?? false;
    final shouldCenter = !hasCentered && savedPosition == null;

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
      if (savedPosition != null && !isMaximized) {
        await windowManager.setPosition(savedPosition);
      }

      await windowManager.show();
      await windowManager.focus();

      if (!AppPlatform.isLinux) {
        await windowManager.setPreventClose(true);
      }

      if (isMaximized) {
        await windowManager.maximize();
      }

      // Mark as initialized so subsequent events are tracked.
      _isInitialized = true;
      if (!isMaximized) {
        _isCompactMode.value = startCompact;
      }
      await _instance._refreshMaximizedOrFullScreenState();

      if (shouldCenter) {
        await prefs.setBool('has_centered_window', true);
      }
    });
  }

  static Future<void> toggleCompactMode() async {
    if (!AppPlatform.isDesktop || !_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    if (_isCompactMode.value) {
      await _saveCurrentBoundsForMode(prefs, isCompact: true);
      final currentBounds = await windowManager.getBounds();
      final expandedPosition = _readPosition(
        prefs,
        _expandedXKey,
        _expandedYKey,
        fallbackX: prefs.getDouble(_legacyXKey),
        fallbackY: prefs.getDouble(_legacyYKey),
      );
      final targetBounds = restoreBoundsFor(
        _restoreBounds,
        currentBounds: currentBounds,
        savedPosition: expandedPosition,
      );
      await _setBounds(targetBounds);
      _restoreBounds = null;
      _isCompactMode.value = false;
      await _saveCurrentBoundsForMode(prefs, isCompact: false);
      return;
    }

    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }

    final currentBounds = await windowManager.getBounds();
    await _saveBoundsForMode(prefs, currentBounds, isCompact: false);
    _restoreBounds = currentBounds;
    final compactPosition = _readPosition(
      prefs,
      _compactXKey,
      _compactYKey,
    );
    final savedCompactHeight = prefs.getDouble(_compactHeightKey);
    final compactBounds = compactBoundsFor(
      currentBounds,
      savedPosition: compactPosition,
      preferredHeight: savedCompactHeight,
    );
    await _setBounds(compactBounds);
    _isCompactMode.value = true;
    await _saveCurrentBoundsForMode(prefs, isCompact: true);
  }

  static Future<void> _setBounds(Rect bounds) async {
    _isApplyingBounds = true;
    try {
      await windowManager.setBounds(bounds, animate: true);
    } finally {
      _isApplyingBounds = false;
    }
  }

  static Future<void> _saveCurrentBoundsForMode(
    SharedPreferences prefs, {
    required bool isCompact,
  }) async {
    final bounds = await windowManager.getBounds();
    await _saveBoundsForMode(prefs, bounds, isCompact: isCompact);
  }

  static Future<void> _saveBoundsForMode(
    SharedPreferences prefs,
    Rect bounds, {
    required bool isCompact,
  }) async {
    final xKey = isCompact ? _compactXKey : _expandedXKey;
    final yKey = isCompact ? _compactYKey : _expandedYKey;
    await prefs.setDouble(xKey, bounds.left);
    await prefs.setDouble(yKey, bounds.top);

    if (isCompact) {
      await prefs.setDouble(_compactHeightKey, bounds.height);
    } else {
      await prefs.setDouble(_widthKey, bounds.width);
      await prefs.setDouble(_heightKey, bounds.height);
      // Keep the legacy position synchronized for seamless downgrade/migration.
      await prefs.setDouble(_legacyXKey, bounds.left);
      await prefs.setDouble(_legacyYKey, bounds.top);
    }
  }

  // Helper method to save state with a 500ms debounce.
  void _saveWindowState() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      if (!_isInitialized || await windowManager.isMaximized()) return;

      final prefs = await SharedPreferences.getInstance();
      await _saveCurrentBoundsForMode(
        prefs,
        isCompact: _isCompactMode.value,
      );
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

  @override
  void onWindowClose() async {
    if (!AppPlatform.isDesktop) return;
    if (_onCloseRequested != null) {
      await _onCloseRequested!();
      return;
    }
    if (AppPlatform.isLinux) {
      await windowManager.destroy();
      return;
    }
    await hide();
  }
}
