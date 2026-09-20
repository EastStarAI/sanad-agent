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
}
