import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

class WorkspaceCreateRequest {
  const WorkspaceCreateRequest({this.path, this.name, this.description});

  final String? path;
  final String? name;
  final String? description;
}

class WorkspacePickerHelper {
  static const remoteDisabledMessage =
      'To change a workspace path, you must use a local connection.';

  @visibleForTesting
  static ValueChanged<String>? debugOnRemoteDisabled;

  @visibleForTesting
  static Future<String?> Function()? debugRemoteWorkspaceName;

  /// Opens the native picker locally. Remote Change Path stays host-local only.
  static Future<String?> pickWorkspacePath({
    required BuildContext context,
    required DeviceConfig? device,
    String confirmButtonText = 'Select Workspace',
    Future<String?> Function()? debugOverride,
  }) async {
    final isLocal = AppPlatform.isDesktop && device?.isLocalReachable == true;
    if (isLocal) {
      if (debugOverride != null) {
        return debugOverride();
      }
      return getDirectoryPath(confirmButtonText: confirmButtonText);
    }

    debugOnRemoteDisabled?.call(remoteDisabledMessage);
    ToastUtils.showError(context, remoteDisabledMessage);
    return null;
  }

  /// Local devices pick a host folder. Remote devices create by name under the
  /// daemon-managed workspaces root.
  static Future<WorkspaceCreateRequest?> promptCreateWorkspace({
    required BuildContext context,
    required DeviceConfig? device,
    Future<String?> Function()? debugLocalPath,
  }) async {
    final isLocal = AppPlatform.isDesktop && device?.isLocalReachable == true;
    if (isLocal) {
      final path = await pickWorkspacePath(
        context: context,
        device: device,
        debugOverride: debugLocalPath,
      );
      if (path == null || path.trim().isEmpty) return null;
      return WorkspaceCreateRequest(path: path.trim());
    }

    final name = debugRemoteWorkspaceName != null
        ? await debugRemoteWorkspaceName!()
        : await _promptRemoteWorkspaceName(context);
    if (name == null || name.trim().isEmpty) return null;
    return WorkspaceCreateRequest(name: name.trim());
  }

  static Future<void> openRemoteFolderBrowser({
    required BuildContext context,
    required WorkspaceTreeLoader loader,
    WorkspaceFolderCreator? onCreateFolder,
    WorkspaceFolderRenamer? onRenameFolder,
    WorkspaceFolderDeleter? onDeleteFolder,
  }) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => WorkspaceBrowserDialog(
        loader: loader,
        onCreateFolder: onCreateFolder,
        onRenameFolder: onRenameFolder,
        onDeleteFolder: onDeleteFolder,
      ),
    );
  }

  static Future<String?> _promptRemoteWorkspaceName(BuildContext context) {
    var value = '';
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Workspace'),
        content: TextFormField(
          key: const Key('remote_workspace_name_input'),
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Workspace name',
            helperText: 'Created on the device under its managed workspaces folder.',
          ),
          onChanged: (nextValue) => value = nextValue,
          onFieldSubmitted: (nextValue) {
            if (nextValue.trim().isNotEmpty) {
              Navigator.pop(dialogContext, nextValue.trim());
            }
          },
        ),
        actions: [
          TextButton(
            key: const Key('remote_workspace_cancel_button'),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('remote_workspace_create_button'),
            onPressed: () => Navigator.pop(dialogContext, value.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
