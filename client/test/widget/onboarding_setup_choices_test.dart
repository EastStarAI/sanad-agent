import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/presentation/widgets/onboarding_setup_choices.dart';

void main() {
  Widget buildSubject({
    required bool isDesktop,
    required bool isAuthenticated,
    bool hasRegisteredDevices = false,
    VoidCallback? onRunLocally,
    VoidCallback? onRemoteAction,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 650,
            child: OnboardingSetupChoices(
              isDesktop: isDesktop,
              isAuthenticated: isAuthenticated,
              hasRegisteredDevices: hasRegisteredDevices,
              onRunLocally: onRunLocally ?? () {},
              onRemoteAction: onRemoteAction ?? () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('desktop makes local setup primary and remote setup secondary', (
    tester,
  ) async {
    var localTaps = 0;
    var remoteTaps = 0;

    await tester.pumpWidget(
      buildSubject(
        isDesktop: true,
        isAuthenticated: false,
        onRunLocally: () => localTaps++,
        onRemoteAction: () => remoteTaps++,
      ),
    );

    expect(find.text('Run Sanad Locally'), findsOneWidget);
    expect(find.byKey(const Key('onboarding_run_locally')), findsOneWidget);
    expect(
      find.text('Sign in to connect a remote device'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextButton>(
        find.byKey(const Key('onboarding_remote_action')),
      ),
      isA<TextButton>(),
    );

    await tester.tap(find.byKey(const Key('onboarding_run_locally')));
    await tester.tap(find.byKey(const Key('onboarding_remote_action')));

    expect(localTaps, 1);
    expect(remoteTaps, 1);
  });

  testWidgets('non-desktop authenticated empty state only offers remote setup', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(isDesktop: false, isAuthenticated: true),
    );

    expect(find.text('No devices connected'), findsOneWidget);
    expect(find.text('Add a Remote Device'), findsOneWidget);
    expect(find.text('Run Sanad Locally'), findsNothing);
    expect(find.byKey(const Key('onboarding_run_locally')), findsNothing);
    expect(
      tester.widget<FilledButton>(
        find.byKey(const Key('onboarding_remote_action')),
      ),
      isA<FilledButton>(),
    );
  });
}
