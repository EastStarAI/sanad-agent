import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';

/// Workspace selector chip: the active workspace label, its loading or locked
/// state, and the workspace menu.
///
/// The chip is deliberately state-agnostic: it reads no cubit and owns no
/// selection. A caller supplies the workspace list it already holds plus the
/// current selection, and receives the user's intent through the callbacks
/// below. That lets the conversation composer and the schedule form share one
/// selector over their own state instead of forking a copy.
class ComposerWorkspaceChip extends StatelessWidget {
  /// Menu value that creates a new workspace folder.
  static const String addNewWorkspaceMenuValue = '__add_new_workspace__';

  /// Menu value that clears the current workspace selection.
  static const String clearWorkspaceMenuValue = '__clear_workspace__';

  final List<DeviceWorkspace> availableWorkspaces;
  final DeviceWorkspace? selectedWorkspace;
  final bool isLoadingWorkspaces;

  /// Whether the caller's flow cannot continue without a workspace, which
  /// marks the empty selection as an error.
  final bool requiresWorkspace;

  /// Whether an active device can accept a workspace selection at all.
  final bool hasActiveAgent;

  /// Whether the current selection is owned by something other than this chip
  /// (a bound conversation session), which makes the chip read-only.
  final bool isLocked;

  final Color chipBgColor;
  final Color borderColor;
  final Color dimTextColor;

  /// Loads the workspace list. Called from the menu's open hook only when the
  /// caller holds no workspace and is not already loading.
  final VoidCallback onRefreshWorkspaces;

  final ValueChanged<DeviceWorkspace> onWorkspaceSelected;
  final VoidCallback onWorkspaceCleared;

  /// Opens the caller's create-workspace flow for its active device.
  final VoidCallback onAddNewWorkspace;

  const ComposerWorkspaceChip({
    super.key,
    required this.availableWorkspaces,
    required this.selectedWorkspace,
    required this.isLoadingWorkspaces,
    required this.requiresWorkspace,
    required this.hasActiveAgent,
    required this.isLocked,
    required this.chipBgColor,
    required this.borderColor,
    required this.dimTextColor,
    required this.onRefreshWorkspaces,
    required this.onWorkspaceSelected,
    required this.onWorkspaceCleared,
    required this.onAddNewWorkspace,
  });

  @override
  Widget build(BuildContext context) {
    final label = selectedWorkspace?.name ?? (requiresWorkspace ? 'Choose Workspace' : 'Workspace');
    final color = selectedWorkspace == null && requiresWorkspace
        ? Theme.of(context).colorScheme.error.withValues(alpha: 0.8)
        : dimTextColor;

    return PopupMenuButton<String>(
      key: const Key('workspace_selector_btn'),
      tooltip: isLocked ? 'Workspace is locked for this session' : 'Select Workspace',
      enabled: !isLocked && hasActiveAgent,
      offset: const Offset(0, 32),
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      onOpened: () {
        if (availableWorkspaces.isEmpty && !isLoadingWorkspaces) {
          onRefreshWorkspaces();
        }
      },
      onSelected: (value) {
        if (value == addNewWorkspaceMenuValue) {
          onAddNewWorkspace();
          return;
        }

        if (value == clearWorkspaceMenuValue) {
          onWorkspaceCleared();
          return;
        }

        for (final workspace in availableWorkspaces) {
          if (workspace.id == value) {
            onWorkspaceSelected(workspace);
            return;
          }
        }
      },
      child: _buildChip(
        context,
        Icons.folder_outlined,
        label,
        color: color,
        trailing: isLoadingWorkspaces
            ? Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(left: 6),
                child: const AppProgressIndicator(strokeWidth: 1.5),
              )
            : isLocked
            ? Container(
                margin: const EdgeInsets.only(left: 6),
                child: Icon(Icons.lock_outline, size: 12, color: dimTextColor),
              )
            : Container(
                margin: const EdgeInsets.only(left: 6),
                child: Icon(Icons.keyboard_arrow_down, size: 12, color: dimTextColor),
              ),
      ),
      itemBuilder: (context) => [
        ...availableWorkspaces.map((workspace) {
          final isSelected = workspace.id == selectedWorkspace?.id;
          return PopupMenuItem<String>(
            key: Key('workspace_item_${workspace.id}'),
            value: workspace.id,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        workspace.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      Text(
                        workspace.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected) Icon(Icons.check, size: 12, color: Theme.of(context).colorScheme.primary),
              ],
            ),
          );
        }),
        if (!requiresWorkspace && selectedWorkspace != null) ...[
          PopupMenuItem<String>(
            value: clearWorkspaceMenuValue,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.close, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'No workspace',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
          PopupMenuDivider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
        ],
        PopupMenuItem<String>(
          value: addNewWorkspaceMenuValue,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.create_new_folder_outlined, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                'Add New Workspace',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChip(
    BuildContext context,
    IconData icon,
    String label, {
    Color? color,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: chipBgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color ?? dimTextColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              color: color ?? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}
