import 'package:flutter/material.dart';

import '../../../../devices/domain/models/device_config.dart';
import '../../../domain/models/conversation_resource_state.dart';
import '../../../domain/models/device_workspace.dart';
import '../../../domain/models/sidebar_conversation_group.dart';
import 'sidebar_conversation_row.dart';
import 'sidebar_workspace_group_tile.dart';

/// The "Workspaces" heading and its list of workspace group tiles (Plan 32c).
///
/// This is a layout/heading container. It owns no state beyond the section
/// heading and the create-workspace plus button. Each workspace tile is an
/// independent rebuild unit.
class SidebarWorkspacesSection extends StatelessWidget {
  final List<DeviceWorkspace> workspaces;
  final List<Widget> workspaceTiles;
  final ConversationResourceState workspacesState;
  final bool isDrawerMode;

  final VoidCallback onCreateWorkspace;
  final VoidCallback onRetryWorkspaces;

  @visibleForTesting
  static VoidCallback? debugOnBuild;

  const SidebarWorkspacesSection({
    super.key,
    required this.workspaces,
    required this.workspaceTiles,
    required this.workspacesState,
    required this.onCreateWorkspace,
    required this.onRetryWorkspaces,
    this.isDrawerMode = false,
  });

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugOnBuild?.call();
      return true;
    }());
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            8,
            4,
            8,
            4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Workspaces',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              IconButton(
                key: const Key('sidebar_create_workspace_btn'),
                icon: Icon(
                  Icons.add,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: onCreateWorkspace,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ],
          ),
        ),
        _SectionStatusInline(
          state: workspacesState,
          isDrawerMode: isDrawerMode,
          staleLabel: 'Could not refresh workspaces',
          onRetry: onRetryWorkspaces,
        ),
        if (workspaces.isEmpty && workspacesState == ConversationResourceState.loading)
          Padding(
            padding: const EdgeInsets.all(16),
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (workspaces.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No workspaces',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
                fontSize: 11,
              ),
            ),
          )
        else
          ...workspaceTiles,
      ],
    );
  }
}

/// The "Conversations" section for unscoped sessions (no workspace) (Plan 32c).
///
/// Mirrors [SidebarWorkspacesSection] but has no expansion toggle (always
/// visible). Its heading plus button starts a New Conversation with no
/// workspace binding.
class SidebarUnscopedConversationsSection extends StatelessWidget {
  final DeviceConfig device;
  final SidebarConversationGroup? group;
  final bool isDrawerMode;

  final VoidCallback onLoadMore;
  final VoidCallback onRetry;
  final VoidCallback onNewConversation;
  final void Function(SessionRef session) onSessionSelected;

  @visibleForTesting
  static VoidCallback? debugOnBuild;

  const SidebarUnscopedConversationsSection({
    super.key,
    required this.device,
    required this.group,
    required this.onLoadMore,
    required this.onRetry,
    required this.onNewConversation,
    required this.onSessionSelected,
    this.isDrawerMode = false,
  });

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugOnBuild?.call();
      return true;
    }());
    final theme = Theme.of(context);
    final sessions = group?.sessions ?? const [];
    final state = group?.state ?? ConversationResourceState.notLoaded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            8,
            12,
            8,
            4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Conversations',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              IconButton(
                key: const Key('sidebar_new_unscoped_conversation_btn'),
                tooltip: 'New conversation without a workspace',
                icon: Icon(
                  Icons.add,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: onNewConversation,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ],
          ),
        ),
        _SectionStatusInline(
          state: state,
          isDrawerMode: isDrawerMode,
          staleLabel: 'Could not refresh conversations',
          onRetry: onRetry,
        ),
        if (state == ConversationResourceState.loading && sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (sessions.isEmpty && state != ConversationResourceState.notLoaded)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No conversations',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
                fontSize: 11,
              ),
            ),
          )
        else
          AnimatedListDiffColumn(
            itemIds: sessions.map((session) => session.id).toList(growable: false),
            children: [
              for (final session in sessions)
                SidebarConversationRow(
                  key: ValueKey('unscoped:${session.id}'),
                  device: device,
                  session: session,
                  isDrawerMode: isDrawerMode,
                  onSelected: () => onSessionSelected(SessionRef(id: session.id)),
                ),
            ],
          ),
        if (group?.hasMore ?? false)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: TextButton.icon(
              key: const ValueKey('unscoped-load-more'),
              onPressed: onLoadMore,
              iconAlignment: IconAlignment.end,
              icon: Icon(Icons.expand_more, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              label: Text(
                group!.isLoadingMore ? 'Loading…' : 'Load more',
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
          ),
      ],
    );
  }
}

class _SectionStatusInline extends StatelessWidget {
  final ConversationResourceState state;
  final bool isDrawerMode;
  final String staleLabel;
  final VoidCallback onRetry;

  const _SectionStatusInline({
    required this.state,
    required this.isDrawerMode,
    required this.staleLabel,
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
        8,
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
              staleLabel,
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
