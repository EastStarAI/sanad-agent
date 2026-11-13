import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/application/notification_presence_store.dart';
import 'package:sanad_client/infrastructure/platform/desktop_lifecycle_manager.dart';

/// Reports whether the desktop window is on screen.
///
/// Window visibility has one deterministic owner: [DesktopLifecycleManager]
/// records every hide and show the Client performs itself — close-to-tray, the
/// tray Show item, a notification click, and an explicit quit — and publishes
/// each change. This widget projects that record into presence, so a platform
/// that emits no lifecycle transition for a tray hide can no longer leave
/// presence claiming the window is visible while the user cannot see it.
///
/// The OS lifecycle is only a corroborating signal. Desktop platforms do not all
/// report a tray hide, and none reports a restore that proves the window is back,
/// so `resumed` never overrides the manager's hidden flag: visibility is the
/// manager's value *and* the absence of a lifecycle-hidden state. On a target
/// without a manager the lifecycle state is all there is, which is the contract
/// mobile and web will rely on.
///
/// Like the surface reporter, this is observation only: a mount without the
/// presence provider stays inert instead of failing.
class NotificationWindowPresenceReporter extends StatefulWidget {
  const NotificationWindowPresenceReporter({
    super.key,
    required this.child,
    this.lifecycleManager,
  });

  final Widget child;

  /// The deterministic window owner; `null` on a target without one.
  final DesktopLifecycleManager? lifecycleManager;

  @override
  State<NotificationWindowPresenceReporter> createState() =>
      _NotificationWindowPresenceReporterState();
}

class _NotificationWindowPresenceReporterState
    extends State<NotificationWindowPresenceReporter> with WidgetsBindingObserver {
  late final NotificationPresenceStore _presence;
  StreamSubscription<bool>? _visibilitySubscription;

  /// The manager's last record, or `true` when there is no manager.
  bool _windowVisible = true;

  /// Whether the OS says this process is in the foreground.
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _presence = context.read<NotificationPresenceStore?>() ?? NotificationPresenceStore();
    WidgetsBinding.instance.addObserver(this);
    final manager = widget.lifecycleManager;
    _windowVisible = manager?.isWindowVisible ?? true;
    _visibilitySubscription = manager?.windowVisibilityChanges.listen((visible) {
      if (!mounted) return;
      _windowVisible = visible;
      _apply();
    });
    _apply();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
      case AppLifecycleState.inactive:
        // Losing focus is not losing the window: an inactive app is still on
        // screen and still showing the session the user is reading.
        return;
    }
    _apply();
  }

  void _apply() => _presence.setWindowVisible(_windowVisible && _foreground);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_visibilitySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
