import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application startup guards native platform access on Web', () {
    final source = File('lib/app.dart').readAsStringSync();

    expect(source, contains('AppPlatform.isMacOS'));
    expect(source, isNot(contains("import 'dart:io';")));
    expect(source, isNot(contains('if (Platform.isMacOS)')));
  });

  test('Web authentication bridge is external and loads before Flutter', () {
    final index = File('web/index.html').readAsStringSync();
    final bridge = File('web/auth_popup.js').readAsStringSync();

    expect(index, isNot(contains('<script>')));
    expect(index, contains('<script src="auth_popup.js"></script>'));
    expect(
      index.indexOf('auth_popup.js'),
      lessThan(index.indexOf('flutter_bootstrap.js')),
    );
    expect(bridge, contains('window.AuthPopup'));
  });
}
