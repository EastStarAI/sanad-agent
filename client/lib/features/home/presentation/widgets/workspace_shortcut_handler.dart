import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';

/// Intent definitions for desktop workspace navigation and actions.
/// Designed for extensible foundation as more workspace keyboard shortcuts are added.
class NavigateBackIntent extends Intent {
  const NavigateBackIntent();
}

class NavigateForwardIntent extends Intent {
  const NavigateForwardIntent();
}

class ToggleSidebarIntent extends Intent {
  const ToggleSidebarIntent();
}

/// Extensible handler for desktop shortcuts and hardware mouse navigation events.
class WorkspaceShortcutHandler extends StatelessWidget {
  final Widget child;
  final ConversationHistoryController? historyController;
  final VoidCallback? onToggleSidebar;
  final ValueChanged<ConversationDestination?>? onNavigate;

  const WorkspaceShortcutHandler({
    super.key,
    required this.child,
    this.historyController,
    this.onToggleSidebar,
    this.onNavigate,
  });

  void _handleBack() {
    if (historyController != null && historyController!.snapshot.canGoBack) {
      final dest = historyController!.goBack();
      onNavigate?.call(dest);
    }
  }

  void _handleForward() {
    if (historyController != null && historyController!.snapshot.canGoForward) {
      final dest = historyController!.goForward();
      onNavigate?.call(dest);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // Navigation: Cmd+[ (macOS) / Alt+Left (Windows/Linux) for Back
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): const NavigateBackIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): const NavigateBackIntent(),

        // Navigation: Cmd+] (macOS) / Alt+Right (Windows/Linux) for Forward
        const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true): const NavigateForwardIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): const NavigateForwardIntent(),

        // Sidebar toggle: Cmd+B (macOS) / Ctrl+B (Windows/Linux)
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): const ToggleSidebarIntent(),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): const ToggleSidebarIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NavigateBackIntent: CallbackAction<NavigateBackIntent>(
            onInvoke: (_) => _handleBack(),
          ),
          NavigateForwardIntent: CallbackAction<NavigateForwardIntent>(
            onInvoke: (_) => _handleForward(),
          ),
          ToggleSidebarIntent: CallbackAction<ToggleSidebarIntent>(
            onInvoke: (_) => onToggleSidebar?.call(),
          ),
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            // Hardware mouse buttons 4 & 5 (Back and Forward)
            if ((event.buttons & kBackMouseButton) != 0) {
              _handleBack();
            } else if ((event.buttons & kForwardMouseButton) != 0) {
              _handleForward();
            }
          },
          child: Focus(
            autofocus: false,
            canRequestFocus: false,
            child: child,
          ),
        ),
      ),
    );
  }
}
