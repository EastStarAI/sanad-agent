import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_workspace_coordinator.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';

/// Permission-mode selector chip with its approval-gated menu.
class ComposerPermissionModeChip extends StatelessWidget {
  final WorkspacePermissionMode permissionMode;
  final bool isLoadingPermissionMode;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;
  final Future<bool> Function() onConfirmFullAccess;
  final String? workspacePath;

  const ComposerPermissionModeChip({
    required this.permissionMode,
    required this.isLoadingPermissionMode,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
    required this.onConfirmFullAccess,
    this.workspacePath,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = isLoadingPermissionMode
        ? (l10n?.loading ?? 'Loading…')
        : (l10n != null ? _modeLabel(permissionMode, l10n) : permissionMode.value);
    final path = workspacePath?.trim();
    final tooltipText = path != null && path.isNotEmpty
        ? (l10n != null
              ? l10n.workspacePermissionModeTooltipWithRoot(
                  _modeLabel(permissionMode, l10n),
                  path,
                )
              : 'Permission: ${permissionMode.value}\nExecution Root: $path')
        : (l10n?.workspacePermissionModeTooltip ?? 'Select Permission Mode');

    return PopupMenuButton<WorkspacePermissionMode>(
      key: const Key('permission_mode_selector_button'),
      tooltip: tooltipText,
      enabled: !isLoadingPermissionMode,
      child: _buildChip(context, label),
      itemBuilder: (context) => WorkspacePermissionMode.values
          .map(
            (mode) => PopupMenuItem<WorkspacePermissionMode>(
              key: Key('composer_permission_mode_${mode.value}'),
              value: mode,
              height: 40,
              child: Row(
                children: [
                  Icon(
                    permissionMode == mode ? Icons.check : Icons.shield_outlined,
                    size: 16,
                    color: permissionMode == mode ? Theme.of(context).colorScheme.primary : dimTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n != null ? _modeLabel(mode, l10n) : mode.value,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      onSelected: (mode) async {
        if (mode == permissionMode) return;
        if (mode == WorkspacePermissionMode.fullAccess) {
          final confirmed = await onConfirmFullAccess();
          if (!context.mounted || !confirmed) return;
        }
        if (!context.mounted) return;
        final failure = await context.read<ConversationInputCubit>().setWorkspacePermissionMode(mode);
        if (failure != null && context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          ToastUtils.showError(
            context,
            failure == WorkspacePolicyChangeFailure.staleRevision
                ? l10n.workspacePolicyChangedRetry
                : l10n.workspacePermissionModeChangeFailed,
          );
        }
      },
    );
  }

  String _modeLabel(
    WorkspacePermissionMode mode,
    AppLocalizations l10n,
  ) {
    switch (mode) {
      case WorkspacePermissionMode.defaultMode:
        return l10n.workspacePermissionModeDefault;
      case WorkspacePermissionMode.fullAccess:
        return l10n.workspacePermissionModeFullAccess;
    }
  }

  Widget _buildChip(BuildContext context, String text) {
    final theme = Theme.of(context);
    final isFullAccess = !isLoadingPermissionMode && permissionMode == WorkspacePermissionMode.fullAccess;
    final color = isFullAccess ? theme.colorScheme.tertiary : dimTextColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: chipBgColor.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.shield_outlined,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: GoogleFonts.inter(color: color, fontSize: 11),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.keyboard_arrow_down,
            size: 12,
            color: color,
          ),
        ],
      ),
    );
  }
}

