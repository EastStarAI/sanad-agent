import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Web auth popup enforces source, origin, type, and one-time delivery', () async {
    final node = await Process.run('node', [
      '--test',
      'test/web/auth_popup_security_test.mjs',
    ]);

    expect(
      node.exitCode,
      0,
      reason: '${node.stdout}\n${node.stderr}',
    );
  });
}
