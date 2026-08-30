import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/presentation/widgets/device_install_guide.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';

void main() {
  testWidgets(
    'shows compact platform commands vertically in the expected order',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 900,
                child: DeviceInstallGuide(token: 'pairing-token'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(CopyButton), findsNWidgets(2));
      expect(find.text('macOS & Linux'), findsOneWidget);
      expect(find.text('Windows'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('PowerShell'), findsOneWidget);

      final posixCard = find.byKey(
        const ValueKey('posix-install-command'),
      );
      final windowsCard = find.byKey(
        const ValueKey('windows-install-command'),
      );
      expect(
        tester.getTopLeft(posixCard).dy,
        lessThan(tester.getTopLeft(windowsCard).dy),
      );
      expect(tester.getSize(posixCard).width, lessThanOrEqualTo(680));
      expect(tester.getSize(windowsCard).width, lessThanOrEqualTo(680));

      expect(
        find.textContaining(
          'curl -fsSL https://sanad.eaststarai.com/install.sh | '
          "bash -s -- --pairing-token 'pairing-token'",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('mktemp'), findsNothing);
      expect(find.textContaining('--pairing-token-stdin'), findsNothing);
      expect(
        find.textContaining(
          "-PairingToken 'pairing-token'",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('\nsanad login'), findsNothing);
      expect(find.text('1\n2'), findsNothing);
    },
  );

  testWidgets('shell-quotes pairing tokens without changing the installer URL', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DeviceInstallGuide(token: "pairing' token"),
        ),
      ),
    );

    expect(
      find.textContaining('https://sanad.eaststarai.com/install.sh'),
      findsOneWidget,
    );
    expect(find.textContaining(r"'pairing'\'' token'"), findsOneWidget);
  });

  testWidgets('keeps both command cards usable on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: DeviceInstallGuide(token: 'long-pairing-token'),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('posix-install-command')), findsOneWidget);
    expect(find.byKey(const ValueKey('windows-install-command')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
