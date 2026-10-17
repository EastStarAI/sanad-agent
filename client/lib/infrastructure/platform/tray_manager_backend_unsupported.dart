import 'package:sanad_client/infrastructure/platform/tray_manager_adapter.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';

/// Default backend for every target without `dart.library.io` (Web).
///
/// The system tray and the background lifecycle are native-desktop only, so
/// this adapter keeps the injectable adapter API total without importing the
/// native tray/FFI library that cannot be compiled for the Web.
TrayManagerAdapter createBackendTrayManagerAdapter() => const UnsupportedTrayManagerAdapter();

class UnsupportedTrayManagerAdapter implements TrayManagerAdapter {
  const UnsupportedTrayManagerAdapter();

  @override
  Future<void> initialize({
    required String iconAssetPath,
    required String tooltip,
    required void Function() onTrayIconClick,
  }) async {}

  @override
  Future<void> setContextMenu(List<TrayMenuItemDescriptor> items) async {}

  @override
  Future<void> destroy() async {}
}
