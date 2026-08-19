import 'package:flutter/material.dart';

import '../../../../devices/domain/models/device_config.dart';
import '../../../domain/models/conversation_resource_state.dart';
import '../../../domain/models/sidebar_conversation_group.dart';
import 'sidebar_conversation_row.dart';

/// One workspace and its conversation rows in the sidebar (Plan 32c Gate C0).
///
/// Ownership: this tile rebuilds only when its own group snapshot or expansion
/// flag changes. Each [SidebarConversationRow] inside it is a separate rebuild
/// unit. The tile receives expansion state and group data from the parent and
/// emits intents ([onToggleExpansion], [onNewConversation], [onLoadMore],
/// [onSessionSelected]) — it never mutates cache directly.
class SidebarWorkspaceGroupTile extends StatelessWidget {
  final DeviceConfig device;
  final SidebarConversationGroup group;
  final bool isExpanded;
  final bool isDrawerMode;

  final VoidCallback onToggleExpansion;
  final VoidCallback onNewConversation;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;
  final void Function(SessionRef session) onSessionSelected;
  final bool isWorkspaceAvailable;
  final VoidCallback onOpenWorkspaceSettings;

  const SidebarWorkspaceGroupTile({
    super.key,
    required this.device,
    required this.group,
    required this.isExpanded,
    required this.onToggleExpansion,
    required this.onNewConversation,
    required this.onLoadMore,
    required this.onRetry,
    required this.onSessionSelected,
    required this.isWorkspaceAvailable,
    required this.onOpenWorkspaceSettings,
    this.isDrawerMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WorkspaceHoverRegion(
          builder: (context, hovered) => Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggleExpansion,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                child: Row(
                  children: [
                    Icon(
                      isExpanded ? Icons.expand_more : Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: isWorkspaceAvailable ? 'Workspace available' : 'Workspace folder is missing',
                      child: Icon(
                        isWorkspaceAvailable ? Icons.folder_outlined : Icons.folder_off_outlined,
                        size: 14,
                        color: isWorkspaceAvailable ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        group.workspaceName ?? 'Workspace',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    IgnorePointer(
                      ignoring: !hovered,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 120),
                        opacity: hovered ? 1 : 0,
                        child: IconButton(
                          key: const Key('workspace_settings_btn'),
                          tooltip: 'Workspace settings',
                          onPressed: onOpenWorkspaceSettings,
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('sidebar_new_conversation_btn'),
                      tooltip: isWorkspaceAvailable ? 'New conversation' : 'Reconnect the workspace folder first',
                      icon: const Icon(Icons.add, size: 14),
                      onPressed: isWorkspaceAvailable ? onNewConversation : null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (isExpanded) ..._buildBody(context),
      ],
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final widgets = <Widget>[
      _WorkspaceSectionStatusInline(
        state: group.state,
        isDrawerMode: isDrawerMode,
        onRetry: onRetry,
      ),
    ];

    if (group.state == ConversationResourceState.loading && group.sessions.isEmpty) {
      widgets.add(_SectionSpinner(isDrawerMode: isDrawerMode));
      return widgets;
    }

    final theme = Theme.of(context);
    if (group.sessions.isNotEmpty) {
      widgets.add(
        AnimatedListDiffColumn(
          itemIds: group.sessions.map((session) => session.id).toList(growable: false),
          children: [
            for (final session in group.sessions)
              SidebarConversationRow(
                key: ValueKey('ws:${group.workspaceId}:${session.id}'),
                device: device,
                session: session,
                isDrawerMode: isDrawerMode,
                onSelected: () => onSessionSelected(SessionRef(id: session.id)),
              ),
          ],
        ),
      );
    }

    if (group.sessions.isEmpty && group.state != ConversationResourceState.notLoaded) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            'No conversations',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
              fontSize: 11,
            ),
          ),
        ),
      );
    }

    if (group.hasMore) {
      widgets.add(
        _LoadMoreTile(
          key: ValueKey('workspace-load-more:${group.workspaceId}'),
          isLoading: group.isLoadingMore,
          onPressed: onLoadMore,
          isDrawerMode: isDrawerMode,
        ),
      );
    }

    return widgets;
  }
}

class _WorkspaceHoverRegion extends StatefulWidget {
  const _WorkspaceHoverRegion({required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_WorkspaceHoverRegion> createState() => _WorkspaceHoverRegionState();
}

class _WorkspaceHoverRegionState extends State<_WorkspaceHoverRegion> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(context, _hovered),
  );
}

/// Lightweight reference to a session for selection intents, keeping the row
/// slice decoupled from the full [Session] model lifecycle.
class SessionRef {
  final String id;
  const SessionRef({required this.id});
}

class _SectionSpinner extends StatelessWidget {
  final bool isDrawerMode;
  const _SectionSpinner({required this.isDrawerMode});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _LoadMoreTile extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;
  final bool isDrawerMode;

  const _LoadMoreTile({
    super.key,
    required this.isLoading,
    required this.onPressed,
    required this.isDrawerMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: TextButton.icon(
        onPressed: onPressed,
        iconAlignment: IconAlignment.end,
        icon: Icon(Icons.expand_more, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
        label: Text(
          'Load more',
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
        style: TextButton.styleFrom(
          minimumSize: const Size(double.infinity, 36),
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.only(
            left: 25,
            right: 8,
            top: 6,
            bottom: 6,
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
    );
  }
}

class _WorkspaceSectionStatusInline extends StatelessWidget {
  final ConversationResourceState state;
  final bool isDrawerMode;
  final VoidCallback onRetry;

  const _WorkspaceSectionStatusInline({
    required this.state,
    required this.isDrawerMode,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (state != ConversationResourceState.staleError) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        24,
        0,
        8,
        4,
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Showing cached conversations',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
