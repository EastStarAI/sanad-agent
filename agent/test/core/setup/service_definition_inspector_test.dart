import 'package:sanad_agent/core/setup/linux_service_manager.dart';
import 'package:sanad_agent/core/setup/service_definition_inspector.dart';
import 'package:sanad_agent/core/setup/service_manager.dart';
import 'package:test/test.dart';

/// Task 107 Q4 — the installed service definition is compared with the one
/// this Agent would generate, so a Client re-registers only when they differ.
void main() {
  const expected = ServiceDefinition(
    executable: '/Users/qa/.sanad qa/bin/sanad',
    arguments: ['daemon'],
    sanadHome: '/Users/qa/.sanad qa',
    serviceInstance: 'qa107',
  );

  String plist(ServiceDefinition definition) =>
      ServiceManager.buildLaunchdPlist(
        executable: definition.executable,
        arguments: definition.arguments,
        sanadHome: definition.sanadHome,
        serviceInstance: definition.serviceInstance,
      );

  String unit(ServiceDefinition definition) =>
      LinuxServiceManager.buildSystemdUnit(
        executable: definition.executable,
        arguments: definition.arguments,
        sanadHome: definition.sanadHome,
        systemScope: false,
        user: 'qa',
        group: 'qa',
        home: '/home/qa',
      );

  group('launchd plist', () {
    test('round-trips the generated definition', () {
      expect(
        ServiceDefinitionInspector.parseLaunchdPlist(plist(expected)),
        expected,
      );
    });

    test('detects a different executable, arguments, Home or instance', () {
      for (final changed in [
        expected.copyWith(executable: '/Users/qa/old/sanad'),
        expected.copyWith(arguments: const ['daemon', '--legacy']),
        expected.copyWith(sanadHome: '/Users/qa/.sanad'),
        expected.copyWith(serviceInstance: ''),
      ]) {
        expect(
          ServiceDefinitionInspector.parseLaunchdPlist(plist(changed)),
          isNot(expected),
        );
      }
    });

    test('an unrecognized file is not a definition', () {
      expect(
        ServiceDefinitionInspector.parseLaunchdPlist('<plist></plist>'),
        isNull,
      );
    });
  });

  group('systemd unit', () {
    test('round-trips executable, arguments and Home with escaping', () {
      const tricky = ServiceDefinition(
        executable: '/home/qa/.sanad "x"/bin/sanad',
        arguments: ['daemon', '50%'],
        sanadHome: '/home/qa/.sanad "x"',
        serviceInstance: 'qa107',
      );
      expect(
        ServiceDefinitionInspector.parseSystemdUnit(
          unit(tricky),
          serviceInstance: 'qa107',
        ),
        tricky,
      );
    });

    test('detects a different executable or Home', () {
      expect(
        ServiceDefinitionInspector.parseSystemdUnit(
          unit(expected.copyWith(executable: '/opt/old/sanad')),
          serviceInstance: 'qa107',
        ),
        isNot(expected),
      );
      expect(
        ServiceDefinitionInspector.parseSystemdUnit(
          unit(expected.copyWith(sanadHome: '/home/qa/.sanad')),
          serviceInstance: 'qa107',
        ),
        isNot(expected),
      );
    });
  });

  test(
    'the report says matches only when an installed definition equals the expected one',
    () {
      expect(
        ServiceDefinitionInspector.compare(
          expected: expected,
          installed: expected,
        ),
        containsPair('matches', true),
      );
      final differs = ServiceDefinitionInspector.compare(
        expected: expected,
        installed: expected.copyWith(executable: '/old/sanad'),
      );
      expect(differs['installed'], isTrue);
      expect(differs['matches'], isFalse);
      final missing = ServiceDefinitionInspector.compare(
        expected: expected,
        installed: null,
      );
      expect(missing['installed'], isFalse);
      expect(missing['matches'], isFalse);
    },
  );
}
