import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/session_sidebar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';
import 'package:sanad_client/features/home/data/sidebar_preferences.dart';
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

  late final SidebarPreferences _sidebarPreferences;
  double _sidebarWidth = SidebarBreakpoints.desktopWidth;
  bool _isPinned = true;
  bool _isHovered = false;
  bool _isResizing = false;

  bool get isPinned => _isPinned;

  @override
  void initState() {
    super.initState();
    _sidebarPreferences = widget.sidebarPreferences ?? SidebarPreferences(getIt<SharedPreferences>());
    final savedWidth = _sidebarPreferences.sidebarWidth;
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
    setState(() {
      _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(
        SidebarBreakpoints.minWidth,
        SidebarBreakpoints.maxWidth,
      );
    });
  }

  void _onDragEnd(DragEndDetails details) {
    setState(() {
      _isResizing = false;
    });
    unawaited(_sidebarPreferences.setSidebarWidth(_sidebarWidth));
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
              left: isMacOS ? 88 : 8,
              top: isMacOS ? 12 : 8,
              bottom: 4,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                IconButton(
                  key: const Key('sidebar_toggle_btn'),
                  onPressed: togglePin,
                  icon: Icon(
                    _isPinned ? Symbols.dock_to_left : Symbols.dock_to_right,
                    size: 16,
                    color: _isPinned ? theme.colorScheme.onSurface.withValues(alpha: 0.6) : theme.colorScheme.primary,
                  ),
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('sidebar_back_btn'),
                  onPressed: hasBack ? () => navigate(historyController.goBack()) : null,
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('sidebar_forward_btn'),
                  onPressed: hasForward ? () => navigate(historyController.goForward()) : null,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          );
        },
      );
    }

    return Stack(
      children: [
        Row(
          children: [
            permanentSidebar,
            Expanded(child: widget.child),
          ],
        ),
        if (!_isPinned)
          // Hover trigger area on the left edge (16 pixels)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 16,
            child: MouseRegion(
              onEnter: (_) => setHovered(true),
            ),
          ),
        // Animated unified sidebar (always present in the Stack, slides/blurs based on state)
        AnimatedPositioned(
          duration: duration,
          curve: Curves.easeInOut,
          left: _isPinned ? 0 : (_isHovered ? 0 : -_sidebarWidth - 10),
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
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
                      // boxShadow: [
                      //   BoxShadow(
                      //     color: Colors.black.withValues(alpha: 0.15),
                      //     blurRadius: 10,
                      //     offset: const Offset(2, 0),
                      //   ),
                      // ],
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
        if (_isPinned)
          Positioned(
            left: _sidebarWidth - (isMacOS ? 8 : 0) - (_resizeHandleWidth / 2),
            top: 0,
            bottom: 0,
            child: resizeHandle,
          ),
        Positioned(
          left: 0,
          top: 0,
          width: isMacOS ? 240 : 160,
          child: MouseRegion(
            onEnter: (_) => setHovered(true),
            child: buildButtonRow(),
          ),
        ),
      ],
    );
  }
}
