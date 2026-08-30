import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-cli-help-');
  });

  tearDown(() async {
    await home.delete(recursive: true);
  });

  test('daemon help exits before bootstrap or supervisor startup', () async {
    final result = await _run(['daemon', '--help'], home);

    expect(result.exitCode, 0);
    expect(result.stdout.toString(), contains('Usage: sanad daemon'));
    expect(result.stdout.toString(), isNot(contains('Daemon is running')));
    expect(File(p.join(home.path, '.env')).existsSync(), isFalse);
  });

  test(
    'unknown daemon arguments are rejected before supervisor startup',
    () async {
      final result = await _run(['daemon', '--unknown'], home);

      expect(result.exitCode, 64);
      expect(result.stderr.toString(), contains('Unknown daemon argument'));
      expect(result.stdout.toString(), isNot(contains('Daemon is running')));
      expect(File(p.join(home.path, '.env')).existsSync(), isFalse);
    },
  );

  test('service help prints usage without starting a daemon', () async {
    final result = await _run(['service', '--help'], home);

    expect(result.exitCode, 0);
    expect(result.stdout.toString(), contains('Usage: sanad service'));
    expect(result.stdout.toString(), isNot(contains('Daemon is running')));
  });
}

Future<ProcessResult> _run(List<String> arguments, Directory home) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/sanad_agent.dart', ...arguments],
      environment: {
        ...Platform.environment,
        'SANAD_HOME': home.path,
        'SANAD_STATE_HOME': home.path,
      },
    ).timeout(const Duration(seconds: 30));
