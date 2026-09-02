/// Composition contract for the device workspace sidebar (Plan 32c Gate C0).
///
/// Gate C0 fixes the responsive composition and ownership boundaries before
/// detailed styling. The sidebar is split into independently-rebuilding slices
/// so a single conversation row update never rebuilds the entire workspace
/// tree. Each slice reads only the state it needs from its bloc/cubit.
///
/// Composition tree:
/// ```
/// DeviceWorkspaceSidebar (shell, responsive layout, chrome)
///  ├─ SidebarDeviceHeaderBar          (device selector, settings)
///  ├─ SidebarWorkspacesSection        (Workspaces heading + create-workspace intent)
///  │   └─ SidebarWorkspaceGroupTile   (one per workspace, expansion + lazy fetch)
///  │       └─ SidebarConversationRow  (one per session in that workspace)
///  ├─ SidebarUnscopedConversationsSection (Conversations heading)
///  │   └─ SidebarConversationRow      (one per unscoped session)
///  └─ UserProfileTile                 (account)
/// ```
///
/// All slices are stateless/presentational. State comes exclusively from
/// [SessionSidebarCubit] + `ConversationCacheRepository`. No slice owns a
/// cache map, cursor, or draft.
library;

import 'package:flutter/material.dart';
import '../../../../../utils/app_platform.dart';

/// Responsive breakpoints shared by sidebar composition (Plan 32c §الاستجابة).
class SidebarBreakpoints {
  SidebarBreakpoints._();

  /// Below this width the sidebar becomes a drawer that closes after
  /// selecting a session. At/above it the sidebar is a fixed column.
  static const double tablet = 900;

  /// Default fixed sidebar width on desktop.
  static const double desktopWidth = 300;

  /// Drawer width on compact layouts, expressed as a fraction of viewport width.
  static const double drawerWidthFactor = 0.8;

  /// Resizable sidebar bounds (kept consistent with ConversationWorkspaceLayout).
  static const double minWidth = 220;
  static const double maxWidth = 420;

  /// Reserved top space on macOS for native traffic-light buttons.
  static const double macOSTrafficLightsHeight = 28;

  /// Extra separation below the traffic lights for a compact drawer.
  static const double macOSDrawerTopGap = 4;

  /// Leading title-bar space reserved for the native macOS traffic lights.
  static const double macOSTrafficLightsLeadingInset = 88;

  /// Optical vertical alignment with the native macOS traffic lights.
  static const double macOSHeaderActionsVerticalOffset = 2;

  /// The maximum width of the conversation body (chat list, input composer, and app bar).
  static const double maxConversationWidth = 780;

  /// Returns true if the screen is narrow enough or the platform is mobile
  /// so that the UI should switch to a compact layout.
  static bool isCompact(BuildContext context) {
    return AppPlatform.isMobile || MediaQuery.sizeOf(context).width < 600;
  }
}
