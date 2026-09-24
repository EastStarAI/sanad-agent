import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/session_sidebar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';
import 'package:sanad_client/features/home/data/sidebar_preferences.dart';
import 'package:sanad_client/features/home/presentation/widgets/workspace_shortcut_handler.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConversationWorkspaceLayout extends StatefulWidget {
  final Widget child;
  final bool showChrome;
  final SidebarPreferences? sidebarPreferences;

  const ConversationWorkspaceLayout({
    super.key,
    required this.child,
    this.showChrome = true,
    this.sidebarPreferences,
  });

  @override
  State<ConversationWorkspaceLayout> createState() => ConversationWorkspaceLayoutState();

  static ConversationWorkspaceLayoutState? of(BuildContext context) {
    return context.findAncestorStateOfType<ConversationWorkspaceLayoutState>();
  }
}

class ConversationWorkspaceLayoutState extends State<ConversationWorkspaceLayout> {
  static const double _resizeHandleWidth = 10;

  SidebarPreferences? _sidebarPreferences;
  double _sidebarWidth = SidebarBreakpoints.desktopWidth;
  bool _isPinned = true;
  bool _isHovered = false;
  bool _isResizing = false;

  bool get isPinned => _isPinned;

  @override
  void initState() {
    super.initState();
    _sidebarPreferences =
        widget.sidebarPreferences ??
        (getIt.isRegistered<SharedPreferences>() ? SidebarPreferences(getIt<SharedPreferences>()) : null);
    final savedWidth = _sidebarPreferences?.sidebarWidth;
    if (savedWidth != null && savedWidth.isFinite) {
      _sidebarWidth = savedWidth
          .clamp(
            SidebarBreakpoints.minWidth,
            SidebarBreakpoints.maxWidth,
          )
          .toDouble();
    }
  }

  void togglePin() {
    setState(() {
      _isPinned = !_isPinned;
      if (_isPinned) {
        _isHovered = false;
      } else {
        _isHovered = true;
      }
    });
  }

  void setHovered(bool hovered) {
    if (!_isPinned && _isHovered != hovered) {
      setState(() {
        _isHovered = hovered;
      });
    }
  }

  void _onDragStart(DragStartDetails details) {
    setState(() {
      _isResizing = true;
    });
  }

  void _resizeSidebar(DragUpdateDetails details) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final delta = isRtl ? -details.delta.dx : details.delta.dx;
    setState(() {
      _sidebarWidth = (_sidebarWidth + delta).clamp(
        SidebarBreakpoints.minWidth,
        SidebarBreakpoints.maxWidth,
      );
    });
  }

  void _onDragEnd(DragEndDetails details) {
    setState(() {
      _isResizing = false;
    });
    final sidebarPreferences = _sidebarPreferences;
    if (sidebarPreferences != null) {
      unawaited(sidebarPreferences.setSidebarWidth(_sidebarWidth));
    }
  }

  void _onDragCancel() {
    setState(() {
      _isResizing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dividerColor = theme.colorScheme.outline.withValues(alpha: 0.24);
    final duration = _isResizing ? Duration.zero : const Duration(milliseconds: 250);
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    final permanentSidebar = AnimatedContainer(
      duration: duration,
      curve: Curves.easeInOut,
      width: _isPinned ? _sidebarWidth : 0,
      child: const SizedBox(),
    );

    final resizeHandle = AnimatedContainer(
      duration: duration,
      curve: Curves.easeInOut,
      width: _isPinned ? _resizeHandleWidth : 0,
      child: ClipRect(
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _resizeSidebar,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
            child: SizedBox(
              width: _resizeHandleWidth,
              child: Center(
                child: Container(
                  width: 0,
                  color: dividerColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final isMacOS = AppPlatform.isMacOS;

    final historyController = getIt.isRegistered<ConversationHistoryController>()
        ? getIt<ConversationHistoryController>()
        : null;

    void navigate(ConversationDestination? destination) {
      if (destination != null) context.go(destination.routePath);
    }

    Widget buildButtonRow() {
      if (historyController == null) return const SizedBox.shrink();
      return AnimatedBuilder(
        animation: historyController,
        builder: (context, _) {
          final hasBack = historyController.snapshot.canGoBack;
          final hasForward = historyController.snapshot.canGoForward;
          return Container(
            // height: buttonRowHeight,
            padding: EdgeInsets.only(
              left: isRtl ? 0 : (isMacOS ? 88 : 8),
              right: isRtl ? 16 : 0,
              top: isMacOS ? 12 : 8,
              bottom: 4,
            ),
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  minimumSize: const Size(24, 24),
                  maximumSize: const Size(24, 24),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  IconButton(
                    key: const Key('sidebar_toggle_btn'),
                    onPressed: togglePin,
                    icon: Icon(
                      _isPinned
                          ? (isRtl ? Symbols.dock_to_right : Symbols.dock_to_left)
                          : (isRtl ? Symbols.dock_to_left : Symbols.dock_to_right),
                      size: 16,
                      color: _isPinned ? theme.colorScheme.onSurface.withValues(alpha: 0.6) : theme.colorScheme.primary,
                    ),
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24, maxWidth: 24, maxHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                  if (AppPlatform.isDesktop) ...[
                    const SizedBox(width: 4),
                    ValueListenableBuilder<bool>(
                      valueListenable: WindowManagerService.compactModeListenable,
                      builder: (context, isCompact, _) => IconButton(
                        key: const Key('desktop_compact_window_btn'),
                        tooltip: isCompact ? 'Restore window size' : 'Use phone-size window',
                        onPressed: WindowManagerService.toggleCompactMode,
                        icon: Icon(
                          isCompact ? Symbols.open_in_full : Symbols.phone_iphone,
                          size: 16,
                          color: isCompact
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                          maxWidth: 24,
                          maxHeight: 24,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('sidebar_back_btn'),
                    onPressed: hasBack ? () => navigate(historyController.goBack()) : null,
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      size: 16,
                    ),
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24, maxWidth: 24, maxHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('sidebar_forward_btn'),
                    onPressed: hasForward ? () => navigate(historyController.goForward()) : null,
                    icon: const Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                    ),
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24, maxWidth: 24, maxHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 95,
                    height: 16,
                    child: SvgPicture.asset(
                      key: const Key('sidebar_wordmark_logo'),
                      Theme.of(context).brightness == Brightness.dark
                          ? 'assets/brand/sanad-wordmark-horizontal-dark.svg'
                          : 'assets/brand/sanad-wordmark-horizontal.svg',
                      fit: BoxFit.contain,
                      alignment: isRtl ? Alignment.centerLeft : Alignment.centerRight,
                      colorFilter: ColorFilter.mode(
                        theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    return WorkspaceShortcutHandler(
      historyController: historyController,
      onToggleSidebar: togglePin,
      onNavigate: navigate,
      child: Stack(
        children: [
          Row(
            // A Row inside an RTL Directionality lays out its children from
            // the right edge automatically, so the same child order works
            // for both directions and keeps the conversation space reserved.
            children: [
              permanentSidebar,
              Transform.translate(
                offset: Offset(
                  isRtl ? (isMacOS ? 8 : (_resizeHandleWidth / 2)) : (isMacOS ? -8 : -(_resizeHandleWidth / 2)),
                  0,
                ),
                child: resizeHandle,
              ),
              Expanded(child: widget.child),
            ],
          ),
          // Animated unified sidebar (always present in the Stack, slides/blurs based on state)
          AnimatedPositioned(
            duration: duration,
            curve: Curves.easeInOut,
            left: isRtl ? null : (_isPinned ? 0 : (_isHovered ? 0 : -_sidebarWidth - 10)),
            right: isRtl ? (_isPinned ? 0 : (_isHovered ? 0 : -_sidebarWidth - 10)) : null,
            top: 0,
            bottom: 0,
            width: _sidebarWidth,
            child: MouseRegion(
              onExit: (_) => setHovered(false),
              child: Container(
                margin: isMacOS ? const EdgeInsets.all(8) : EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.25)),
                      ),
                      child: SessionSidebar(
                        width: _sidebarWidth - (isMacOS ? 16 : 0),
                        showChrome: widget.showChrome,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: isRtl ? null : 0,
            right: isRtl ? 0 : null,
            top: 0,
            width: isMacOS ? 300 : 240,
            child: Directionality(
              textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: buildButtonRow(),
            ),
          ),
        ],
      ),
    );
  }
}
