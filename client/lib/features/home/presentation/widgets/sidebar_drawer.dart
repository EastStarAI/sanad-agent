import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/session_sidebar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';

/// The compact-layout navigation drawer hosting [SessionSidebar].
///
/// Extracted from `home_screen.dart` so the orchestration screen stays inside
/// the Client size ratchet while it hosts device surfaces (Task 139 C1). It is
/// the same widget with the same chrome, blur, and rounded edge; only its home
/// changed.
class SidebarDrawer extends StatelessWidget {
  const SidebarDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final Widget content = SessionSidebar(
      isDrawerMode: true,
      onClose: () => Navigator.pop(context),
    );
    final theme = Theme.of(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      width: (MediaQuery.of(context).size.width * SidebarBreakpoints.drawerWidthFactor).clamp(
        SidebarBreakpoints.minWidth,
        MediaQuery.of(context).size.width,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.horizontal(
          right: isRtl ? Radius.zero : const Radius.circular(16),
          left: isRtl ? const Radius.circular(16) : Radius.zero,
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.25),
              border: Border(
                right: isRtl
                    ? BorderSide.none
                    : BorderSide(
                        color: theme.colorScheme.outline.withValues(alpha: 0.25),
                      ),
                left: isRtl
                    ? BorderSide(
                        color: theme.colorScheme.outline.withValues(alpha: 0.25),
                      )
                    : BorderSide.none,
              ),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
