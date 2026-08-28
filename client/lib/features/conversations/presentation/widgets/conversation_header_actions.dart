import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// Shared leading actions for narrow conversation surfaces.
///
/// Native macOS keeps its traffic lights in the same title-bar row, so the
/// application actions begin after that reserved platform-owned area.
class ConversationHeaderActions extends StatelessWidget {
  final VoidCallback? onMenuPressed;
  final VoidCallback? onMenuHoverEnter;
  final VoidCallback? onMenuHoverExit;

  const ConversationHeaderActions({
    super.key,
    this.onMenuPressed,
    this.onMenuHoverEnter,
    this.onMenuHoverExit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: AppPlatform.isMacOS ? SidebarBreakpoints.macOSTrafficLightsLeadingInset : 0,
      ),
      child: Transform.translate(
        key: const Key('conversation_header_actions_alignment'),
        offset: Offset(
          0,
          AppPlatform.isMacOS ? SidebarBreakpoints.macOSHeaderActionsVerticalOffset : 0,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          textDirection: TextDirection.ltr,
          children: [
            if (onMenuPressed != null)
              MouseRegion(
                key: const Key('conversation_menu_hover_region'),
                onEnter: (_) => onMenuHoverEnter?.call(),
                onExit: (_) => onMenuHoverExit?.call(),
                child: IconButton(
                  key: const Key('conversation_header_menu_btn'),
                  icon: Icon(
                    AppPlatform.isDesktop ? Symbols.dock_to_right : Icons.menu,
                    size: AppPlatform.isDesktop ? 16 : null,
                    color: AppPlatform.isDesktop
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.6)
                        : theme.colorScheme.onSurface,
                  ),
                  constraints: AppPlatform.isDesktop ? const BoxConstraints(minWidth: 24, minHeight: 24) : null,
                  padding: AppPlatform.isDesktop ? EdgeInsets.zero : null,
                  onPressed: onMenuPressed,
                  tooltip: 'Open navigation menu',
                ),
              ),
            if (onMenuPressed != null && AppPlatform.isDesktop) const SizedBox(width: 4),
            if (AppPlatform.isDesktop)
              ValueListenableBuilder<bool>(
                valueListenable: WindowManagerService.compactModeListenable,
                builder: (context, isCompact, _) => IconButton(
                  key: const Key('mobile_compact_window_btn'),
                  tooltip: isCompact ? 'Restore window size' : 'Use compact window',
                  onPressed: WindowManagerService.toggleCompactMode,
                  icon: Icon(
                    isCompact ? Symbols.open_in_full : Symbols.phone_iphone,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  padding: EdgeInsets.zero,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
