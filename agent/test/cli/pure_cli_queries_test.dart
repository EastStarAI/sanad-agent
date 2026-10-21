import 'dart:io';

import 'package:path/path.dart' as p;
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
}
