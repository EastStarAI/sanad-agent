import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

class WorkspacePickerHelper {
  static const remoteDisabledMessage = 'To create or modify a workspace, you must use a local connection.';

  @visibleForTesting
  static ValueChanged<String>? debugOnRemoteDisabled;

  /// Opens the native picker locally or explains why remote selection is off.
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

    // TODO(security): Restore remote selection only after its filesystem
    // authorization model has been reviewed and approved.
    debugOnRemoteDisabled?.call(remoteDisabledMessage);
    ToastUtils.showError(context, remoteDisabledMessage);
    return null;
  }
}
