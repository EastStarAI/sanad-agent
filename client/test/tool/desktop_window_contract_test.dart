import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';

void main() {
  test('desktop window minimum supports short desktop work areas', () {
    expect(WindowManagerService.minimumWindowSize, const Size(500, 600));
  });

  test('compact window retains its preferred phone-height viewport', () {
    expect(WindowManagerService.compactWindowSize, const Size(500, 874));
  });

  test('compact bounds preserve the window top-left origin', () {
    final bounds = WindowManagerService.compactBoundsFor(
      const Rect.fromLTWH(120, 80, 1400, 900),
    );

    expect(bounds.left, 120);
    expect(bounds.top, 80);
    expect(bounds.size, const Size(500, 874));
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

    expect(macOS, contains('let minimumWidth: CGFloat = 500'));
    expect(macOS, contains('let minimumHeight: CGFloat = 600'));
    expect(macOS, contains(': 800, minimumHeight)'));
    expect(macOS, contains('self.contentMinSize = NSSize'));

    expect(windows, contains('constexpr int kMinimumWindowWidth = 500'));
    expect(windows, contains('constexpr int kMinimumWindowHeight = 600'));
    expect(windows, contains('case WM_GETMINMAXINFO'));

    expect(linux, contains('constexpr int kMinimumWindowWidth = 500'));
    expect(linux, contains('constexpr int kMinimumWindowHeight = 600'));
    expect(linux, contains('gtk_window_set_default_size(window, 1470, 800)'));
    expect(linux, contains('gtk_widget_set_size_request'));
  });
}
