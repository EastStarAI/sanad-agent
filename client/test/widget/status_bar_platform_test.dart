import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/home/presentation/widgets/status_bar.dart';
import 'package:sanad_client/utils/app_platform.dart';

void main() {
  tearDown(() {
    AppPlatform.overrideIsDesktop = null;
  });

  testWidgets('renders the home status bar child on native desktop', (
    tester,
  ) async {
    AppPlatform.overrideIsDesktop = true;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DesktopOnlyStatusBar(
            child: SizedBox(key: Key('status-bar-content')),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('status-bar-content')), findsOneWidget);
  });

  testWidgets('hides the home status bar child off desktop', (tester) async {
    AppPlatform.overrideIsDesktop = false;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DesktopOnlyStatusBar(
            child: SizedBox(key: Key('status-bar-content')),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('status-bar-content')), findsNothing);
  });
}
