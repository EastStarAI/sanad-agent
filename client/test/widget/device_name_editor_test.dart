import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages.dart';

void main() {
  Widget buildEditor({
    required DeviceConfig device,
    required Future<void> Function(String name) onRename,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: DeviceNameEditor(device: device, onRename: onRename),
      ),
    );
  }

  testWidgets('opens with the current name and submits a trimmed replacement', (
    tester,
  ) async {
    String? submittedName;
    final device = DeviceConfig(id: 'cloud-device', name: 'Office Mac');
    await tester.pumpWidget(
      buildEditor(
        device: device,
        onRename: (name) async => submittedName = name,
      ),
    );

    await tester.tap(find.byKey(const Key('device_name_edit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Rename device'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Office Mac'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('device_name_field')),
      '  Studio Mac  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('device_name_rename_button')));
    await tester.pumpAndSettle();

    expect(submittedName, 'Studio Mac');
    expect(find.text('Rename device'), findsNothing);
  });

  testWidgets('keeps the dialog open and shows a mutation error', (
    tester,
  ) async {
    final device = DeviceConfig(id: 'cloud-device', name: 'Office Mac');
    await tester.pumpWidget(
      buildEditor(
        device: device,
        onRename: (_) async => throw Exception('Rename failed'),
      ),
    );

    await tester.tap(find.byKey(const Key('device_name_edit_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('device_name_field')),
      'Studio Mac',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('device_name_rename_button')));
    await tester.pumpAndSettle();

    expect(find.text('Rename device'), findsOneWidget);
    expect(find.text('Exception: Rename failed'), findsOneWidget);
  });

  testWidgets('does not offer rename for a local-only device', (tester) async {
    final device = DeviceConfig(
      id: 'hardware-1',
      name: 'This device',
      hardwareId: 'hardware-1',
    );
    await tester.pumpWidget(
      buildEditor(device: device, onRename: (_) async {}),
    );

    expect(find.byKey(const Key('device_name_edit_button')), findsNothing);
  });
}
