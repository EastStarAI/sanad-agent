import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/setup/service_definition_inspector.dart';
import 'package:sanad_agent/core/setup/service_manager.dart';
import 'package:sanad_agent/core/setup/service_metadata.dart';
import 'package:sanad_agent/core/setup/service_unit_builder.dart';
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
      ServiceUnitBuilder.systemdUnit(
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

  group('report', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('sanad-definition-');
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    /// The systemd unit `service install` writes for [definition].
    String systemdUnit(
      ServiceDefinition definition, {
      required bool systemScope,
    }) => ServiceUnitBuilder.systemdUnit(
      executable: definition.executable,
      arguments: definition.arguments,
      sanadHome: definition.sanadHome,
      systemScope: systemScope,
      user: 'sanad-agent',
      group: 'sanad-agent',
      home: definition.sanadHome,
    );

    /// The definition `service install` writes for [definition] on this host.
    String hostDefinition(ServiceDefinition definition) => Platform.isMacOS
        ? ServiceManager.buildLaunchdPlist(
            executable: definition.executable,
            arguments: definition.arguments,
            sanadHome: definition.sanadHome,
            serviceInstance: definition.serviceInstance,
          )
        : systemdUnit(definition, systemScope: false);

    test('inspects the system-scope unit this Home recorded', () async {
      final expected = ServiceDefinitionInspector.expected(home: home.path);
      final definition = File(
        p.join(home.path, 'etc', 'systemd', 'system', 'sanad-agent.service'),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(systemdUnit(expected, systemScope: true));
      await const ServiceMetadataStore().write(
        home: home.path,
        payload: {
          'version': 1,
          'scope': ServiceScope.systemdSystem.wireName,
          'config_path': definition.path,
          'sanad_home': home.path,
        },
      );

      final report = await ServiceDefinitionInspector.report(
        home: home.path,
        // A system installation owns no user unit, so a report that only reads
        // this path answers "not installed" for a live service.
        configPath: p.join(home.path, 'user', 'sanad-agent.service'),
      );

      expect(report['installed'], isTrue);
      expect(report['matches'], isTrue);
      expect(report['installed_definition'], expected.toJson());
    });

    test(
      'inspects the caller user unit when this Home recorded none',
      () async {
        final expected = ServiceDefinitionInspector.expected(home: home.path);
        final userUnit = File(p.join(home.path, 'user', 'sanad-agent.service'))
          ..createSync(recursive: true)
          ..writeAsStringSync(hostDefinition(expected));

        final report = await ServiceDefinitionInspector.report(
          home: home.path,
          configPath: userUnit.path,
        );

        expect(report['installed'], isTrue);
        expect(report['matches'], isTrue);
      },
    );

    test(
      'metadata this process may not read does not name a definition',
      () async {
        final report = await ServiceDefinitionInspector.report(
          home: home.path,
          configPath: p.join(home.path, 'user', 'sanad-agent.service'),
          metadata: ServiceMetadataStore(
            reader: (file) async => throw PathAccessException(
              file.path,
              const OSError('Operation not permitted', 1),
            ),
          ),
        );

        expect(report['installed'], isFalse);
        expect(report['installed_definition'], isNull);
      },
    );
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
