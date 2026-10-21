import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application startup guards native platform access on Web', () {
    final source = File('lib/app.dart').readAsStringSync();

    // Platform branches go through the Web-safe AppPlatform facade; startup
    // never imports dart:io or reads the native Platform class directly.
    expect(source, contains('AppPlatform.'));
    expect(source, isNot(contains("import 'dart:io';")));
    expect(source, isNot(contains(RegExp(r'(?<![A-Za-z])Platform\.is'))));
  });

  test('Web authentication bridge is external and loads before Flutter', () {
    final index = File('web/index.html').readAsStringSync();
    final bridge = File('web/auth_popup.js').readAsStringSync();

    expect(index, isNot(contains('<script>')));
    expect(index, contains('<script src="auth_popup.js"></script>'));
    expect(index, contains('<script src="splash.js"></script>'));
    expect(File('web/splash.js').existsSync(), isTrue);
    expect(
      index.indexOf('auth_popup.js'),
      lessThan(index.indexOf('flutter_bootstrap.js')),
    );
    expect(bridge, contains('window.AuthPopup'));
  });
}
