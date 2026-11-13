import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Executes the owned service worker, because no browser runs on this host.
///
/// The harness runs the worker as source (`client/web/sw.js`) with a stubbed
/// worker global, pushes every payload shape the product sends with no visible
/// client, and asserts one notification and the exact click-through URL. The
/// shape matrix lives in `test/web/sw_closed_tab_notification_test.mjs`.
void main() {
  test('the closed-tab worker raises one notification per payload shape', () async {
    final ProcessResult node;
    try {
      node = await Process.run('node', [
        '--test',
        'test/web/sw_closed_tab_notification_test.mjs',
      ]);
    } on ProcessException catch (e) {
      markTestSkipped('Node.js not available on host: ${e.message}');
      return;
    }

    expect(
      node.exitCode,
      0,
      reason: '${node.stdout}\n${node.stderr}',
    );
  });
}
