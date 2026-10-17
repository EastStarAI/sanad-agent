import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/platform/tray_manager_backend.dart';
import 'package:sanad_client/infrastructure/platform/tray_manager_backend_unsupported.dart'
    as unsupported;
import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';

/// Regression coverage for the compile-time tray backend boundary.
///
/// `tray_manager` transitively imports the `nativeapi`/`cnativeapi` FFI
/// library, which cannot be compiled for the Web. These tests pin both halves
/// of the boundary: the unsupported (non-io) adapter is a total no-op, and a
/// native target resolves the native implementation instead of that no-op.
void main() {
  group('tray manager backend boundary', () {
    test('unsupported adapter accepts initialize/menu/destroy without any effect', () async {
      const adapter = unsupported.UnsupportedTrayManagerAdapter();
      var clickEvents = 0;

      await adapter.initialize(
        iconAssetPath: 'assets/app-logo.png',
        tooltip: 'Sanad',
        onTrayIconClick: () => clickEvents++,
      );
      await adapter.setContextMenu([
        const TrayMenuItemDescriptor(key: 'show', label: 'Show'),
        const TrayMenuItemDescriptor.separator(),
      ]);
      await adapter.destroy();
      await adapter.destroy();

      expect(clickEvents, equals(0));
    });

    test('unsupported adapter satisfies the injectable tray adapter contract', () {
      expect(const unsupported.UnsupportedTrayManagerAdapter(), isA<TrayManagerAdapter>());
    });

    test('native targets resolve the native backend, not the unsupported no-op', () {
      final adapter = createPlatformTrayManagerAdapter();

      expect(adapter, isA<TrayManagerAdapter>());
      expect(adapter, isNot(isA<unsupported.UnsupportedTrayManagerAdapter>()));
    });
  });
}
