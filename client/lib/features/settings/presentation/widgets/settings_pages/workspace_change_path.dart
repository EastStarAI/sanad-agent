import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_command_failure.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';

/// Whether Settings offers Change Path for [device], and the action to run.
///
/// Change Path follows Remove Workspace: any online device may change a
/// workspace's folder. A confirmed same-desktop local device keeps the native
/// host panel; every other online device picks inside the confined browser
/// bound to itself, so a device reached over the cloud can repair a workspace's
/// folder without a host connection.
VoidCallback? workspaceChangePathAction({
  required DeviceConfig device,
  required VoidCallback action,
}) => device.isOnline ? action : null;

/// Picks a target folder for [workspace] on [device], names the resolved target
/// in one confirmation line, then sends `workspace.relocate`.
///
/// [browser] must be built from the device being inspected
/// ([WorkspaceBrowserCallbacks.forDevice]) so every browse and every rejection
/// belongs to that device rather than to the active conversation's device. The
/// daemon's confirmation ticket stays invisible: the user confirms the resolved
/// folder, and the transport performs the preview/confirm handshake itself.
Future<void> showWorkspaceChangePathFlow({
  required BuildContext context,
  required ConversationCacheRepository cache,
  required DeviceConfig device,
  required DeviceWorkspace workspace,
  required WorkspaceBrowserCallbacks browser,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final picked = await WorkspacePickerHelper.pickWorkspacePath(
    context: context,
    device: device,
    confirmButtonText: l10n.workspaceChangePathConfirmAction,
    remoteBrowser: browser,
    remoteStartPath: workspace.path,
  );
  final newPath = picked?.trim();
  if (newPath == null || newPath.isEmpty) return;
  if (!context.mounted) return;

  final confirmed = await _confirmTarget(context, newPath);
  if (confirmed != true || !context.mounted) return;

  try {
    await cache.relocateWorkspace(
      device,
      workspaceId: workspace.id,
      newPath: newPath,
    );
  } catch (error) {
    if (!context.mounted) return;
    ToastUtils.showError(context, workspaceChangePathErrorText(l10n, error));
  }
}

/// The one confirmation line that names the resolved target before anything is
/// sent.
Future<bool?> _confirmTarget(BuildContext context, String target) {
  final l10n = AppLocalizations.of(context)!;
  final colorScheme = Theme.of(context).colorScheme;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('workspace_change_path_confirm_dialog'),
      title: Text(l10n.workspaceChangePathTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceChangePathConfirmQuestion),
          const SizedBox(height: 8),
          // A host path reads left to right in every locale.
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              target,
              key: const Key('workspace_change_path_target'),
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('workspace_change_path_cancel_button'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('workspace_change_path_confirm_button'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.workspaceChangePathConfirmAction),
        ),
      ],
    ),
  );
}

/// The localized explanation of a rejected Change Path.
///
/// A target outside the device's workspaces root is a limitation of the remote
/// route, not an error the user can read from the daemon's English reason, so it
/// gets its own copy. Every other rejection keeps the daemon-provided reason
/// because it is the actionable detail; only an empty one falls back.
String workspaceChangePathErrorText(AppLocalizations l10n, Object error) {
  final code = error is WorkspaceCommandFailure ? error.code : null;
  if (code == WorkspaceCommandFailure.pathNotAllowed) {
    return l10n.workspaceChangePathOutsideRoot;
  }
  final detail = switch (error) {
    StateError() => error.message.toString().trim(),
    FormatException() => error.message.trim(),
    _ => '',
  };
  return detail.isEmpty ? l10n.workspaceChangePathFailed : detail;
}
