import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

class WorkspaceCreateRequest {
  const WorkspaceCreateRequest({this.path, this.name, this.description});

  final String? path;
  final String? name;
  final String? description;
}

class WorkspacePickerHelper {
  @visibleForTesting
  static ValueChanged<String>? debugOnRemoteDisabled;

  /// Replaces the remote folder browser in tests. It receives the exact
  /// device-bound callbacks the real dialog would use and returns the pick.
  @visibleForTesting
  static Future<String?> Function(WorkspaceBrowserCallbacks callbacks)?
  debugRemoteBrowserPick;

  /// The single workspace-path picker.
  ///
  /// A confirmed same-desktop local device opens the native host panel. Any
  /// other online device opens the confined in-app browser through
  /// [remoteBrowser], which must be bound to [device]; its pick starts at
  /// [remoteStartPath] when that folder is inside the device's workspaces root.
  /// One dialog, one returned path.
  static Future<String?> pickWorkspacePath({
    required BuildContext context,
    required DeviceConfig? device,
    String confirmButtonText = 'Select Workspace',
    WorkspaceBrowserCallbacks? remoteBrowser,
    String? remoteStartPath,
    Future<String?> Function()? debugOverride,
  }) async {
    final isLocal = AppPlatform.isDesktop && device?.isLocalReachable == true;
    if (isLocal) {
      if (debugOverride != null) {
        return debugOverride();
      }
      return getDirectoryPath(confirmButtonText: confirmButtonText);
    }

    final browser = remoteBrowser;
    if (browser != null && device != null) {
      return openRemoteFolderBrowser(
        context: context,
        callbacks: browser,
        mode: WorkspaceBrowserMode.changePath,
        initialPath: remoteStartPath,
      );
    }

    // A caller reached here without device-bound callbacks, so there is nothing
    // to browse and no path to return.
    final message = AppLocalizations.of(context)!.workspacePickerDeviceUnavailable;
    debugOnRemoteDisabled?.call(message);
    ToastUtils.showError(context, message);
    return null;
  }

  /// Local devices pick a host folder with the native picker. Remote devices
  /// pick a folder inside the device's managed workspaces root through the
  /// in-app browser; every browse and folder command goes through
  /// [remoteBrowser], which must be bound to [device].
  static Future<WorkspaceCreateRequest?> promptCreateWorkspace({
    required BuildContext context,
    required DeviceConfig? device,
    WorkspaceBrowserCallbacks? remoteBrowser,
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

    if (device == null || remoteBrowser == null) return null;
    final picked = await openRemoteFolderBrowser(
      context: context,
      callbacks: remoteBrowser,
    );
    if (picked == null || picked.trim().isEmpty) return null;
    return WorkspaceCreateRequest(path: picked.trim());
  }

  /// Opens the confined in-app folder browser and returns the picked folder,
  /// a path the device itself reported, or `null` when cancelled.
  static Future<String?> openRemoteFolderBrowser({
    required BuildContext context,
    required WorkspaceBrowserCallbacks callbacks,
    WorkspaceBrowserMode mode = WorkspaceBrowserMode.createWorkspace,
    String? initialPath,
  }) {
    final debugPick = debugRemoteBrowserPick;
    if (debugPick != null) return debugPick(callbacks);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => WorkspaceBrowserDialog(
        loader: callbacks.loader,
        onCreateFolder: callbacks.onCreateFolder,
        onRenameFolder: callbacks.onRenameFolder,
        onDeleteFolder: callbacks.onDeleteFolder,
        mode: mode,
        initialPath: initialPath,
      ),
    );
  }
}
