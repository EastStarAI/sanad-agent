import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/presentation/widgets/onboarding_setup_choices.dart';

void main() {
  Widget buildSubject({
    required bool isDesktop,
    required bool isAuthenticated,
    bool hasRegisteredDevices = false,
    bool isLoadingDevices = false,
    VoidCallback? onRunLocally,
    VoidCallback? onRemoteAction,
    VoidCallback? onRetry,
    String? error,
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
              isLoadingDevices: isLoadingDevices,
              onRunLocally: onRunLocally ?? () {},
              onRemoteAction: onRemoteAction ?? () {},
              onRetry: onRetry,
              error: error,
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

  testWidgets('authenticated loading never flashes a false empty on phone layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(isDesktop: false, isAuthenticated: true, isLoadingDevices: true),
    );

    expect(find.text('Checking for your devices…'), findsOneWidget);
    expect(find.byKey(const Key('inventory_loading_dot')), findsOneWidget);
    // The false absent state must not be shown while the fetch is in flight.
    expect(find.text('No devices connected'), findsNothing);
    expect(find.text('Add a Remote Device'), findsNothing);
  });

  testWidgets('loading resolves to an authoritative empty without staying on loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(isDesktop: false, isAuthenticated: true, isLoadingDevices: true),
    );
    expect(find.text('Checking for your devices…'), findsOneWidget);

    await tester.pumpWidget(
      buildSubject(isDesktop: false, isAuthenticated: true, isLoadingDevices: false),
    );
    expect(find.text('No devices connected'), findsOneWidget);
    expect(find.text('Checking for your devices…'), findsNothing);
  });

  testWidgets('fetch error shows a typed error with retry, not a false empty', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      buildSubject(
        isDesktop: false,
        isAuthenticated: true,
        error: 'Could not load your devices. Check your connection and try again.',
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Couldn\u2019t load your devices'), findsOneWidget);
    expect(find.byKey(const Key('inventory_retry')), findsOneWidget);
    expect(find.text('No devices connected'), findsNothing);

    await tester.tap(find.byKey(const Key('inventory_retry')));
    expect(retries, 1);
  });

  testWidgets('desktop keeps local setup as primary while inventory loads', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(isDesktop: true, isAuthenticated: true, isLoadingDevices: true),
    );
    expect(find.text('Run Sanad Locally'), findsOneWidget);
  });
}
