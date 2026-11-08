import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/compiled_agent_cli.dart';

/// These guards prove real CLI startup behavior, so they must spawn the real
/// entrypoint. Compilation is the expensive part of that: it happens once for
/// the whole file, and every case runs the same kernel artifact instead of
/// paying `dart run` compilation again on slow runners. The compilation is
/// awaited inside the first case because `setUpAll` inherits the default test
/// timeout and cannot declare a generous one.
void main() {
  late Directory home;
  late Directory artifactDirectory;
  late CompiledAgentCli cli;

  setUpAll(() async {
    artifactDirectory = await Directory.systemTemp.createTemp(
      'sanad-cli-help-artifact-',
    );
  });

  tearDownAll(() async {
    try {
      await artifactDirectory.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-cli-help-');
    cli = CompiledAgentCli(artifactDirectory);
  });

  tearDown(() async {
    try {
      await home.delete(recursive: true);
    } catch (_) {}
  });

  test('daemon help exits before bootstrap or supervisor startup', () async {
    final result = await cli.run(['daemon', '--help'], home: home);

    expect(result.exitCode, 0);
    expect(result.stdout.toString(), contains('Usage: sanad daemon'));
    expect(result.stdout.toString(), isNot(contains('Daemon is running')));
    expect(File(p.join(home.path, '.env')).existsSync(), isFalse);
  }, timeout: cliTestTimeout);

  test(
    'unknown daemon arguments are rejected before supervisor startup',
    () async {
      final result = await cli.run(['daemon', '--unknown'], home: home);

      expect(result.exitCode, 64);
      expect(result.stderr.toString(), contains('Unknown daemon argument'));
      expect(result.stdout.toString(), isNot(contains('Daemon is running')));
      expect(File(p.join(home.path, '.env')).existsSync(), isFalse);
    },
    timeout: cliTestTimeout,
  );

  test('service help prints usage without starting a daemon', () async {
    final result = await cli.run(['service', '--help'], home: home);

    expect(result.exitCode, 0);
    expect(result.stdout.toString(), contains('Usage: sanad service'));
    expect(result.stdout.toString(), isNot(contains('Daemon is running')));
  }, timeout: cliTestTimeout);
}
