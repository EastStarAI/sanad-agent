import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_header_actions.dart';
import 'package:sanad_client/features/home/presentation/widgets/status_bar.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// The Scaffold chrome shared by the home surface and the mobile zero-device
/// surface.
///
/// It owns exactly three things: the side drawer (so a compact layout always
/// has one), the drawer menu affordance (so the menu is reachable even on a
/// surface that renders no app bar), and the desktop-only bottom status bar.
/// Conversation, device, and provider state stay in their owning cubits above
/// this widget.
///
/// The home surface renders its own menu button inside the conversation header,
/// so it leaves [showMenuButton] off; the zero-device surface has no header and
/// turns it on. Both get the same drawer, and therefore the same Settings,
/// Profile, and Sign out path.
class HomeShellScaffold extends StatelessWidget {
  final Widget body;

  /// The side drawer for a compact layout; null on a wide layout, which keeps
  /// its persistent sidebar column instead.
  final Widget? drawer;

  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Renders the menu button when the surface below provides no header of its
  /// own to host one.
  final bool showMenuButton;

  const HomeShellScaffold({
    super.key,
    required this.body,
    this.drawer,
    this.scaffoldKey,
    this.showMenuButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: scaffoldKey,
      backgroundColor: Colors.transparent,
      drawer: drawer,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: body),
                if (showMenuButton)
                  Positioned(
                    top: AppPlatform.isMacOS ? 12 : MediaQuery.paddingOf(context).top + 8,
                    left: 0,
                    child: Builder(
                      builder: (context) => ConversationHeaderActions(
                        onMenuPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const DesktopOnlyStatusBar(),
        ],
      ),
    );
  }
}
