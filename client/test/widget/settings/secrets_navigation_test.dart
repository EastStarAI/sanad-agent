import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_navigation.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('Privacy & Security holds the Secrets destination for a device', (tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final selected = <SettingsDestination>[];
    final device = DeviceConfig(id: 'device-1', name: 'Laptop', isOnline: true);

    await pumpTestApp(
      tester,
      locale: const Locale('en'),
      child: SettingsNavigation(
        devices: const <DeviceConfig>[],
        activeDeviceId: device.id,
        selectedDevice: device,
        selectedDestination: SettingsDestination.privacySecurity,
        workspaces: const [],
        selectedWorkspaceId: null,
        showAllWorkspaces: false,
        onSelectPersonal: (_) {},
        onSelectDevice: (_) {},
        onSelectDeviceSection: selected.add,
        onSelectWorkspace: (_) {},
        onToggleWorkspaces: () {},
      ),
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.privacyAndSecurity), findsOneWidget);
    expect(find.text(l10n.secrets), findsOneWidget);

    final tile = tester.widget<ListTile>(find.byKey(const Key('nav_tile_privacy_security')));
    expect(tile.selected, isTrue);

    await tester.tap(find.byKey(const Key('nav_tile_privacy_security')));
    expect(selected, [SettingsDestination.privacySecurity]);
  });

  test('the destination name is the route section token', () {
    // SettingsScreen maps an unknown `section` to a destination by name, so the
    // entry point stays at /settings?section=privacySecurity with no new route.
    expect(SettingsDestination.privacySecurity.name, 'privacySecurity');
  });
}
