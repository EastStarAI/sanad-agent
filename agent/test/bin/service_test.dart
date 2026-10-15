import 'dart:io';

import '../../bin/service.dart' as service_command;
import 'package:test/test.dart';

void main() {
  tearDown(() => exitCode = 0);

  test('service entry point returns failure for an unknown action', () async {
    expect(await service_command.main(const ['unknown']), 1);
    expect(exitCode, 1);
  });

  test('service entry point returns success for help', () async {
    expect(await service_command.main(const ['--help']), 0);
  });

  test('service install rejects unknown install options', () async {
    expect(await service_command.main(const ['install', '--unknown-opt']), 1);
    expect(exitCode, 1);
  });

  test('service install rejects missing value for expected version', () async {
    expect(
      await service_command.main(const ['install', '--expected-version']),
      1,
    );
    expect(exitCode, 1);
  });

  test('service non-install actions reject options', () async {
    expect(await service_command.main(const ['stop', '--user-scope']), 1);
    expect(exitCode, 1);
  });

  test(
    'service install parser accepts --user-scope before invalid health option',
    () async {
      expect(
        await service_command.main(const [
          'install',
          '--user-scope',
          '--health-timeout',
          'invalid',
        ]),
        1,
      );
      expect(exitCode, 1);
    },
  );
}
