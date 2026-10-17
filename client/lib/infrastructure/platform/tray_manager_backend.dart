import 'tray_manager_adapter.dart';
import 'tray_manager_backend_unsupported.dart'
    if (dart.library.io) 'tray_manager_backend_native.dart';

export 'tray_manager_adapter.dart';

/// Compile-time platform boundary for the system tray backend.
///
/// `tray_manager` transitively imports the `nativeapi`/`cnativeapi` FFI
/// library, which `dart2js` cannot compile. Importing the native backend only
/// on `dart.library.io` targets keeps that library out of the Web compile
/// graph, while every desktop platform keeps the real tray implementation.
TrayManagerAdapter createPlatformTrayManagerAdapter() => createBackendTrayManagerAdapter();
