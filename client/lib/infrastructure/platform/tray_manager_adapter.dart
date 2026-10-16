import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';

/// Platform-neutral contract for the native system tray projection.
///
/// Implementations must never be imported directly by feature or application
/// code. Resolve one through `createPlatformTrayManagerAdapter()` in
/// `tray_manager_backend.dart`, which selects the native implementation at
/// compile time so non-native targets never link the tray FFI library.
abstract class TrayManagerAdapter {
  Future<void> initialize({
    required String iconAssetPath,
    required String tooltip,
    required void Function() onTrayIconClick,
  });
  Future<void> setContextMenu(List<TrayMenuItemDescriptor> items);
  Future<void> destroy();
}
