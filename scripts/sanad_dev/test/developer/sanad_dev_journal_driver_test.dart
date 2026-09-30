import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import '../support/sanad_dev_test_fixtures.dart';

void main() {
  test(
    'managed Client logs derive the Agent journal port from launch identity',
    () {
      final client = sanad_dev.ClientInstance(
        51330,
        'token',
        testClientDirectory,
        'macos',
        launchProfile: testOwnedProfile(gatewayPort: 58092),
      );

      expect(
        sanad_dev.resolveManagedClientJournalAgentPort(
          fallbackAgentPort: 58123,
          client: client,
        ),
        58092,
      );
      expect(
        sanad_dev.resolveManagedClientJournalAgentPort(
          fallbackAgentPort: 58123,
          explicitAgentPort: 58085,
          client: client,
        ),
        58085,
      );
    },
  );

  test('UI driver selection preserves every managed driver client', () {
    final driver = sanad_dev.ClientInstance(
      51084,
      'driver-token',
      testClientDirectory,
      'macos',
      pid: 101,
      launchProfile: const launch_profile.ClientLaunchProfile(
        compileArguments: [],
        defines: {},
        target: 'lib/driver_main.dart',
        deviceId: 'macos',
      ),
    );
    final secondDriver = sanad_dev.ClientInstance(
      51086,
      'second-driver-token',
      testClientDirectory,
      'chrome',
      pid: 103,
      launchProfile: const launch_profile.ClientLaunchProfile(
        compileArguments: [],
        defines: {},
        target: 'lib/driver_main.dart',
        deviceId: 'chrome',
      ),
    );
    final regular = sanad_dev.ClientInstance(
      51085,
      'regular-token',
      testClientDirectory,
      'macos',
      pid: 102,
      launchProfile: const launch_profile.ClientLaunchProfile(
        compileArguments: [],
        defines: {},
        target: 'lib/main.dart',
        deviceId: 'macos',
      ),
    );
    final assessment = sanad_dev.RuntimeOwnershipAssessment(
      classification: runtime_ownership.RuntimeOwnershipClass.managed,
      state: sanad_dev.RuntimeProcessState(
        agent: null,
        ownedClients: [regular, driver, secondDriver],
        crossOwnedClients: const [],
        ambiguousClients: const [],
      ),
    );

    expect(sanad_dev.selectManagedUiDriverClients(assessment), [
      driver,
      secondDriver,
    ]);
  });
}
