import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/macos_privacy_grants.dart'
    as privacy;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import 'package:test/test.dart';

import '../../support/sanad_dev_test_fixtures.dart';

void main() {
  group('passive macOS preflight classification', () {
    test('maps every preflight answer onto a report status', () {
      expect(
        sanad_dev.classifyMacOsPrivacyPreflight(
          privacy.MacOsPrivacyPreflight.granted,
        ),
        sanad_dev.DriverHostGrantStatus.granted,
      );
      expect(
        sanad_dev.classifyMacOsPrivacyPreflight(
          privacy.MacOsPrivacyPreflight.denied,
        ),
        sanad_dev.DriverHostGrantStatus.missing,
      );
      expect(
        sanad_dev.classifyMacOsPrivacyPreflight(
          privacy.MacOsPrivacyPreflight.unavailable,
        ),
        sanad_dev.DriverHostGrantStatus.unknown,
      );
    });

    test(
      'an unavailable preflight points at System Settings, never at a probe',
      () async {
        final report = await sanad_dev.probeAccessibilityGrant(
          preflight: () => privacy.MacOsPrivacyPreflight.unavailable,
        );

        expect(report.status, isNot(sanad_dev.DriverHostGrantStatus.granted));
        if (Platform.isMacOS) {
          expect(report.detail, contains('System Settings > Privacy & Security'));
        }
      },
    );

    test('reports a missing grant without a false success', () async {
      final accessibility = await sanad_dev.probeAccessibilityGrant(
        preflight: () => privacy.MacOsPrivacyPreflight.denied,
      );
      final screen = await sanad_dev.probeScreenRecordingGrant(
        preflight: () => privacy.MacOsPrivacyPreflight.denied,
      );

      if (Platform.isMacOS) {
        expect(accessibility.status, sanad_dev.DriverHostGrantStatus.missing);
        expect(screen.status, sanad_dev.DriverHostGrantStatus.missing);
        expect(accessibility.detail, contains('Accessibility'));
        expect(screen.detail, contains('Screen Recording'));
      }
    });
  });

  group('real preflight probes', () {
    test('the production probes answer without prompting or spawning', () async {
      // The real defaults run here: on macOS they call AXIsProcessTrusted and
      // CGPreflightScreenCaptureAccess through dart:ffi. A prompting
      // alternative would raise a consent dialog during this test run.
      final accessibility = await sanad_dev.probeAccessibilityGrant();
      final screen = await sanad_dev.probeScreenRecordingGrant();

      expect(accessibility.name, 'Accessibility');
      expect(screen.name, 'Screen Recording');
      if (!Platform.isMacOS) {
        expect(
          accessibility.status,
          sanad_dev.DriverHostGrantStatus.notApplicable,
        );
        return;
      }
      expect(
        accessibility.status,
        isNot(sanad_dev.DriverHostGrantStatus.notApplicable),
      );
      expect(
        accessibility.detail,
        anyOf(
          contains('AXIsProcessTrusted'),
          contains('System Settings > Privacy & Security'),
        ),
      );
      expect(
        screen.detail,
        anyOf(
          contains('CGPreflightScreenCaptureAccess'),
          contains('System Settings > Privacy & Security'),
        ),
      );
    });

    test('the grant path never asks the OS for permission', () async {
      final doctorSource = await File(
        p.join('lib', 'src', 'runtime', 'lifecycle', 'runtime_doctor.dart'),
      ).readAsString();
      final preflightSource = await File(
        p.join('lib', 'src', 'infrastructure', 'macos_privacy_grants.dart'),
      ).readAsString();

      for (final forbidden in const [
        // Quoted process names only: the passive API names such as
        // `CGPreflightScreenCaptureAccess` legitimately contain "screen capture".
        "'osascript'",
        "'screencapture'",
        'Process.run',
        'Process.start',
        'CGRequestScreenCaptureAccess',
        'AXIsProcessTrustedWithOptions',
      ]) {
        expect(
          doctorSource.toLowerCase(),
          isNot(contains(forbidden.toLowerCase())),
          reason:
              'runtime_doctor.dart must only read grants passively; '
              '"$forbidden" can raise a consent dialog',
        );
      }
      expect(preflightSource, isNot(contains('Process.')));
      expect(preflightSource, contains('AXIsProcessTrusted'));
      expect(preflightSource, contains('CGPreflightScreenCaptureAccess'));
    });
  });

  group('doctor driver-host report', () {
    test('prints the entry point, driver clients, ports and grants', () async {
      final lines = <String>[];
      final runtime = createTestRuntime(platformNeutral: true);
      final ownership = sanad_dev.RuntimeOwnershipAssessment(
        classification: runtime_ownership.RuntimeOwnershipClass.stopped,
        state: const sanad_dev.RuntimeProcessState(
          agent: null,
          ownedClients: [],
          crossOwnedClients: [],
          ambiguousClients: [],
        ),
      );

      await sanad_dev.reportSanadDevDoctorDriverHost(
        runtime: runtime,
        ownership: ownership,
        fileExists: (path) =>
            path.endsWith(p.join('client', 'lib', 'driver_main.dart')),
        accessibilityProbe: () async => const sanad_dev.DriverHostGrantReport(
          name: 'Accessibility',
          status: sanad_dev.DriverHostGrantStatus.granted,
          detail: 'AXIsProcessTrusted reported a grant',
        ),
        screenRecordingProbe: () async => const sanad_dev.DriverHostGrantReport(
          name: 'Screen Recording',
          status: sanad_dev.DriverHostGrantStatus.missing,
          detail: 'CGPreflightScreenCaptureAccess reported no grant',
        ),
        printMessage: lines.add,
      );

      expect(
        lines.any(
          (line) =>
              line.contains('Driver entry point: present') &&
              line.endsWith(p.join('client', 'lib', 'driver_main.dart') + ')'),
        ),
        isTrue,
      );
      expect(
        lines.any((line) => line.contains('Driver-enabled clients: 0')),
        isTrue,
      );
      expect(
        lines.any((line) => line.contains('Port ownership: agent 58092')),
        isTrue,
      );
      expect(
        lines.any((line) => line.contains('Home ownership: /isolated/home')),
        isTrue,
      );
      if (Platform.isMacOS) {
        expect(
          lines.any((line) => line.contains('Accessibility: granted')),
          isTrue,
        );
        expect(
          lines.any((line) => line.contains('Screen Recording: missing')),
          isTrue,
        );
      } else {
        expect(lines.any((line) => line.contains('not applicable')), isTrue);
      }
    });

    test(
      'reports a missing driver entry point without mutating anything',
      () async {
        final lines = <String>[];

        await sanad_dev.reportSanadDevDoctorDriverHost(
          runtime: createTestRuntime(platformNeutral: true),
          ownership: sanad_dev.RuntimeOwnershipAssessment(
            classification: runtime_ownership.RuntimeOwnershipClass.stopped,
            state: const sanad_dev.RuntimeProcessState(
              agent: null,
              ownedClients: [],
              crossOwnedClients: [],
              ambiguousClients: [],
            ),
          ),
          fileExists: (path) => false,
          printMessage: lines.add,
        );

        expect(
          lines.any((line) => line.contains('Driver entry point: missing')),
          isTrue,
        );
      },
    );
  });
}
