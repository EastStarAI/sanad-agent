import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';

void main() {
  test('desktop window minimum supports short desktop work areas', () {
    expect(WindowManagerService.minimumWindowSize, const Size(450, 600));
  });

  test('compact window retains its preferred phone-height viewport', () {
    expect(WindowManagerService.compactWindowSize, const Size(450, 900));
  });

  test('isCompactWidth determines compact mode strictly by width', () {
    expect(WindowManagerService.isCompactWidth(450), isTrue);
    expect(WindowManagerService.isCompactWidth(451), isTrue);
    expect(WindowManagerService.isCompactWidth(400), isTrue);
    expect(WindowManagerService.isCompactWidth(452), isFalse);
    expect(WindowManagerService.isCompactWidth(1400), isFalse);
  });

  test('default window size prefers 1400 x 900 layout', () {
    expect(WindowManagerService.defaultWindowSize, const Size(1400, 900));
  });

  test('compact bounds preserve the window top-left origin', () {
    final bounds = WindowManagerService.compactBoundsFor(
      const Rect.fromLTWH(120, 80, 1400, 900),
    );

    expect(bounds.left, 120);
    expect(bounds.top, 80);
    expect(bounds.size, const Size(450, 900));
  });

  test('restore bounds preserves previous bounds when at least default window size', () {
    const previous = Rect.fromLTWH(100, 50, 1600, 900);
    final restored = WindowManagerService.restoreBoundsFor(previous);

    expect(restored, previous);
  });

  test('restore bounds falls back to default window size when previous bounds are smaller than default size', () {
    const smallBounds = Rect.fromLTWH(100, 50, 450, 900);
    final restored = WindowManagerService.restoreBoundsFor(smallBounds);

    expect(restored.left, 100);
    expect(restored.top, 50);
    expect(restored.size, WindowManagerService.defaultWindowSize);

    const smallerBounds = Rect.fromLTWH(200, 150, 1200, 750);
    final restoredSmaller = WindowManagerService.restoreBoundsFor(smallerBounds);

    expect(restoredSmaller.left, 200);
    expect(restoredSmaller.top, 150);
    expect(restoredSmaller.size, WindowManagerService.defaultWindowSize);
  });

  test('restore bounds falls back to default window size and current origin when previous bounds are null', () {
    const current = Rect.fromLTWH(80, 40, 450, 900);
    final restored = WindowManagerService.restoreBoundsFor(null, currentBounds: current);

    expect(restored.left, 80);
    expect(restored.top, 40);
    expect(restored.size, WindowManagerService.defaultWindowSize);
  });

  test('custom caption tracks maximize and full-screen lifecycle events', () {
    final service = File(
      'lib/infrastructure/platform/window_manager_service.dart',
    ).readAsStringSync();
    final titleBar = File(
      'lib/shared/widgets/app_window_title_bar.dart',
    ).readAsStringSync();

    expect(service, contains('maximizedOrFullScreenListenable'));
    expect(service, contains('void onWindowMaximize()'));
    expect(service, contains('void onWindowUnmaximize()'));
    expect(service, contains('void onWindowEnterFullScreen()'));
    expect(service, contains('void onWindowLeaveFullScreen()'));
    expect(titleBar, contains('ValueListenableBuilder<bool>'));
    expect(titleBar, contains('WindowCaptionButton.unmaximize'));
    expect(titleBar, contains('WindowManagerService.toggleMaximized'));
  });

  test('supported native runners enforce the same minimum dimensions', () {
    final macOS = File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
    final windows = File('windows/runner/win32_window.cpp').readAsStringSync();
    final linux = File('linux/runner/my_application.cc').readAsStringSync();

    expect(macOS, contains('let minimumWidth: CGFloat = 450'));
    expect(macOS, contains('let minimumHeight: CGFloat = 600'));
    expect(macOS, contains(': 900, minimumHeight)'));
    expect(macOS, contains('self.contentMinSize = NSSize'));

    expect(windows, contains('constexpr int kMinimumWindowWidth = 450'));
    expect(windows, contains('constexpr int kMinimumWindowHeight = 600'));
    expect(windows, contains('case WM_GETMINMAXINFO'));

    expect(linux, contains('constexpr int kMinimumWindowWidth = 450'));
    expect(linux, contains('constexpr int kMinimumWindowHeight = 600'));
    expect(linux, contains('gtk_window_set_default_size(window, 1400, 900)'));
    expect(linux, contains('gtk_widget_set_size_request'));
  });
}
