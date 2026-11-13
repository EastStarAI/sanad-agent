// Plan 174g (L7) — the device chrome around a settings page must be Arabic too.
//
// The Arabic notifications page still showed an English `This device` and an
// English `local` badge, because the Client synthesized that row's name in the
// data layer and the badge was a literal in the widget. Both are interface copy,
// so both belong to the localization system.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_device_header_bar.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/utils/device_ui_mapper.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_navigation.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The row the Client synthesizes for the machine it runs on.
DeviceConfig _localDevice() => DeviceConfig(
      id: 'hw-1',
      name: DeviceConfig.localPlaceholderName,
      hardwareId: 'hw-1',
      isOnline: true,
      metadata: const <String, dynamic>{'is_local_reachable': true},
    );

DeviceConfig _agentDevice() => DeviceConfig(
      id: 'hw-2',
      name: 'Studio Mac',
      hardwareId: 'hw-2',
      isOnline: true,
    );

void _ignore() {}

void _ignoreDevice(DeviceConfig device) {}

Widget _wrap(Locale locale, Widget child) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('the device header states this device and its badge in Arabic', (tester) async {
    final arabic = lookupAppLocalizations(const Locale('ar'));
    final device = _localDevice();

    await tester.pumpWidget(
      _wrap(
        const Locale('ar'),
        SidebarDeviceHeaderBar(
          devices: <DeviceConfig>[device],
          activeDevice: device,
          onDeviceSelected: (_) {},
          onSettingsTapped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(arabic.devicesThisDevice), findsOneWidget);
    expect(find.text(arabic.devicesLocalBadge), findsOneWidget);
    expect(find.text('This device'), findsNothing, reason: 'no English name in an Arabic interface');
    expect(find.text('local'), findsNothing, reason: 'no English badge in an Arabic interface');
  });

  testWidgets('an Agent-reported device name is shown exactly as stored', (tester) async {
    final arabic = lookupAppLocalizations(const Locale('ar'));
    final device = _agentDevice();

    await tester.pumpWidget(
      _wrap(
        const Locale('ar'),
        SidebarDeviceHeaderBar(
          devices: <DeviceConfig>[device],
          activeDevice: device,
          onDeviceSelected: (_) {},
          onSettingsTapped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Studio Mac'), findsOneWidget,
        reason: 'a name the user or the Agent wrote is never translated');
    expect(find.text(arabic.devicesThisDevice), findsNothing);
  });

  testWidgets('the loading and empty states are localized too', (tester) async {
    // Plan 174g (W4): the same widget mixed localized and hard-coded copy.
    final arabic = lookupAppLocalizations(const Locale('ar'));

    await tester.pumpWidget(
      _wrap(
        const Locale('ar'),
        const SidebarDeviceHeaderBar(
          devices: <DeviceConfig>[],
          activeDevice: null,
          onDeviceSelected: _ignoreDevice,
          onSettingsTapped: _ignore,
          isLoadingFromBackend: true,
        ),
      ),
    );
    // The spinner never settles, so this asserts on frames rather than on a
    // settled tree.
    await tester.pump();
    expect(find.text(arabic.devicesLoading), findsOneWidget);
    expect(find.text('Loading devices…'), findsNothing);

    await tester.pumpWidget(
      _wrap(
        const Locale('ar'),
        const SidebarDeviceHeaderBar(
          devices: <DeviceConfig>[],
          activeDevice: null,
          onDeviceSelected: _ignoreDevice,
          onSettingsTapped: _ignore,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(arabic.devicesNone), findsOneWidget);
    expect(find.text('No devices'), findsNothing);
  });

  testWidgets('the device menu copy is localized', (tester) async {
    final arabic = lookupAppLocalizations(const Locale('ar'));
    final device = _localDevice();

    await tester.pumpWidget(
      _wrap(
        const Locale('ar'),
        SidebarDeviceHeaderBar(
          devices: <DeviceConfig>[device],
          activeDevice: device,
          onDeviceSelected: (_) {},
          onSettingsTapped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar_device_switcher_btn')));
    await tester.pumpAndSettle();

    expect(find.text(arabic.devicesSettingsMenuItem), findsOneWidget);
    expect(find.text('Device Settings'), findsNothing);
  });

  testWidgets('the device section title localizes the synthesized name', (tester) async {
    final arabic = lookupAppLocalizations(const Locale('ar'));
    final device = _localDevice();

    await tester.pumpWidget(
      _wrap(
        const Locale('ar'),
        SettingsNavigation(
          devices: <DeviceConfig>[device],
          activeDeviceId: device.id,
          selectedDevice: device,
          selectedDestination: SettingsDestination.overview,
          workspaces: const [],
          selectedWorkspaceId: null,
          showAllWorkspaces: false,
          onSelectPersonal: (_) {},
          onSelectDevice: (_) {},
          onSelectDeviceSection: (_) {},
          onSelectWorkspace: (_) {},
          onToggleWorkspaces: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(arabic.deviceSettings(arabic.devicesThisDevice)), findsOneWidget);
    expect(find.text(arabic.deviceSettings('This device')), findsNothing);
  });

  test('the synthesized name resolves through the localization system', () {
    final arabic = lookupAppLocalizations(const Locale('ar'));
    final english = lookupAppLocalizations(const Locale('en'));

    expect(_localDevice().displayName(arabic), arabic.devicesThisDevice);
    expect(_localDevice().displayName(english), english.devicesThisDevice);
    expect(_agentDevice().displayName(arabic), 'Studio Mac');
  });
}
