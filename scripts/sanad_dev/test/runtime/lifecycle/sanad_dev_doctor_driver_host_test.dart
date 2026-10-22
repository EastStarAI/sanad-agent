import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import 'package:test/test.dart';

import '../../support/sanad_dev_test_fixtures.dart';

void main() {
  group('driver host grant classification', () {
    test('detects a missing Accessibility grant', () {
      expect(
        sanad_dev.classifyAccessibilityProbe(
          exitCode: 1,
          output: 'osascript: not allowed assistive access',
        ),
        sanad_dev.DriverHostGrantStatus.missing,
      );
      expect(
        sanad_dev.classifyAccessibilityProbe(
          exitCode: 1,
          output: 'System Events got an error: (-1743)',
        ),
        sanad_dev.DriverHostGrantStatus.missing,
      );
      expect(
        sanad_dev.classifyAccessibilityProbe(exitCode: 0, output: '42'),
        sanad_dev.DriverHostGrantStatus.granted,
      );
      expect(
        sanad_dev.classifyAccessibilityProbe(
          exitCode: 1,
          output: 'something unexpected',
        ),
        sanad_dev.DriverHostGrantStatus.unknown,
      );
    });

    test('detects a missing Screen Recording grant', () {
      expect(
        sanad_dev.classifyScreenRecordingProbe(
          exitCode: 1,
          output: 'could not create image from display',
        ),
        sanad_dev.DriverHostGrantStatus.missing,
      );
      expect(
        sanad_dev.classifyScreenRecordingProbe(exitCode: 0, output: ''),
        sanad_dev.DriverHostGrantStatus.granted,
      );
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
          detail: '42',
        ),
        screenRecordingProbe: () async => const sanad_dev.DriverHostGrantReport(
          name: 'Screen Recording',
          status: sanad_dev.DriverHostGrantStatus.missing,
          detail: 'could not create image from display',
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
