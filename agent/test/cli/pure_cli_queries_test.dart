import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/setup/service_metadata.dart';
import 'package:sanad_agent/core/setup/service_models.dart';
import 'package:sanad_agent/core/setup/service_unit_builder.dart';
import 'package:test/test.dart';

/// Task 107 — version and help queries are pure: they never create or write
/// anything in the Sanad Home or state Home. The Desktop Client probes an
/// installed agent with `--version` and `help service install`.
void main() {
  late Directory root;
  late String snapshot;

  setUpAll(() async {
    root = Directory(
      (await Directory.systemTemp.createTemp(
        'sanad-pure-cli-',
      )).resolveSymbolicLinksSync(),
    );
    snapshot = p.join(root.path, 'sanad_agent.dill');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/sanad_agent.dart',
      '-o',
      snapshot,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}${compile.stderr}');
  });

  tearDownAll(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  const queries = <List<String>>[
    ['--version'],
    ['-v'],
    ['version'],
    ['help'],
    ['help', 'service', 'install'],
    ['--help'],
    ['-h'],
    ['service', 'install', '--help'],
    ['chat', '--help'],
    ['update', '-h'],
    ['service', 'definition'],
  ];

  for (final query in queries) {
    test('`sanad ${query.join(' ')}` leaves an empty Home untouched', () async {
      final case_ = await Directory(root.path).createTemp('case-');
      final home = Directory(p.join(case_.path, 'home'))..createSync();
      final state = Directory(p.join(case_.path, 'state'))..createSync();

      final result = await Process.run(
        Platform.resolvedExecutable,
        [snapshot, ...query],
        environment: {
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'SANAD_STATE_HOME': state.path,
        },
      ).timeout(const Duration(seconds: 60));

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout.toString().trim(), isNotEmpty);
      expect(
        home.listSync(recursive: true),
        isEmpty,
        reason: 'SANAD_HOME was written',
      );
      expect(
        state.listSync(recursive: true),
        isEmpty,
        reason: 'SANAD_STATE_HOME was written',
      );
    });
  }

  test(
    '`sanad service definition` inspects the definition this Home installed',
    () async {
      final case_ = await Directory(root.path).createTemp('definition-');
      final home = Directory(p.join(case_.path, 'home'))..createSync();
      // A system-scope installation owns a unit outside the caller's own user
      // directory, so the report has to read the path the Home recorded.
      final definition = File(
        p.join(home.path, 'etc', 'systemd', 'system', 'sanad-agent.service'),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          ServiceUnitBuilder.systemdUnit(
            executable: Platform.resolvedExecutable,
            arguments: [snapshot, 'daemon'],
            sanadHome: home.path,
            systemScope: true,
            user: 'sanad-agent',
            group: 'sanad-agent',
            home: home.path,
          ),
        );
      await const ServiceMetadataStore().write(
        home: home.path,
        payload: {
          'version': 1,
          'scope': ServiceScope.systemdSystem.wireName,
          'config_path': definition.path,
          'sanad_home': home.path,
        },
      );

      final result = await Process.run(
        Platform.resolvedExecutable,
        [snapshot, 'service', 'definition'],
        environment: {
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'HOME': p.join(case_.path, 'caller-home'),
        },
      ).timeout(const Duration(seconds: 60));

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report =
          jsonDecode(result.stdout.toString().trim()) as Map<String, Object?>;
      expect(report['installed'], isTrue, reason: '${result.stdout}');
      expect(report['matches'], isTrue, reason: '${result.stdout}');
    },
  );
}
